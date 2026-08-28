import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var items = [MenuBarItem]()
    @Published private(set) var isScanning = false
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var guardianEvents = [GuardianEvent]()
    @Published private(set) var lastScanDate: Date?
    @Published private(set) var launchAtLogin = false
    @Published private(set) var aiRecommendation: AIRecommendation?
    @Published private(set) var isRequestingAIRecommendation = false
    @Published private(set) var aiRecommendationMessage: String?
    @Published private(set) var aiRequestPhase: AIRequestPhase?
    @Published var selectedAIPlanID: String?
    @Published var selectedPane: SettingsPane? = .menuItems {
        didSet { refreshMenuItemSections() }
    }
    @Published var searchText = ""
    @Published private(set) var externalDisplayConnected = false
    @Published private(set) var externalDisplayIsPrimary = false
    private var sectionDispositions = [String: ItemDisposition]()

    let settings = SettingsStore.shared

    private var statusBar: StatusBarController?
    private var timer: Timer?
    private var observers = [NSObjectProtocol]()
    private var isStopping = false
    private var isMoving = false
    private var pendingRefresh: (reason: String, reconcile: Bool)?
    private var itemsByWindowID = [CGWindowID: MenuBarItem]()
    // Computed once per discovery pass; never query CoreGraphics from a SwiftUI row.
    private var actualDispositions = [String: ItemDisposition]()
    private var identityRebindInProgress = false
    private var identityRebindShouldRecollapse = false
    private var lastIdentityRebind: Date?
    private var lastMoveByItem = [String: Date]()
    private var failedMoveUntil = [String: Date]()
    private var layoutReconciler = LayoutReconciler()
    private var openSettingsAction: (() -> Void)?
    private var aiRecommendationItems = [MenuBarItem]()
    private var aiRecommendationBeforeDispositions = [String: ItemDisposition]()
    private var aiUndoPolicies: [String: ItemDisposition]?
    private var aiApplyQueue = [(MenuBarItem, ItemDisposition)]()
    private var aiApplyChangedCount = 0
    private var aiApplyCompletionMessage = ""
    private let menuBarAgentVisibility = MenuBarAgentVisibilityController()

    private init() {}

    var isExpanded: Bool { settings.isExpanded }
    var canManageMenuBar: Bool { MenuBarAgentBridge.isAvailable || hasAccessibilityPermission }
    var oneDriveItem: MenuBarItem? { items.first(where: \.isOneDrive) }
    var externalDisplayStatusText: String {
        guard externalDisplayConnected else { return L("No external display detected") }
        return externalDisplayIsPrimary
            ? L("External display is currently primary")
            : L("Built-in display is currently primary")
    }

    private var shouldShowAllOnExternalDisplay: Bool {
        externalDisplayConnected
            && externalDisplayIsPrimary
            && settings.externalDisplayMode == .showAll
    }

    private var effectiveExpanded: Bool {
        settings.isExpanded || shouldShowAllOnExternalDisplay
    }

    private var aiRecommendationCountToday: Int {
        settings.aiRecommendationDates.filter { Calendar.current.isDateInToday($0) }.count
    }

    var aiRemainingRecommendationCount: Int {
        max(0, 3 - aiRecommendationCountToday)
    }

    var aiNextAvailableDate: Date? {
        guard aiRemainingRecommendationCount == 0 else { return nil }
        return Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))
    }

    var canRequestAIRecommendation: Bool {
        !isRequestingAIRecommendation && !isScanning && aiRemainingRecommendationCount > 0
    }

    var aiAvailabilityMessage: String {
        guard aiRemainingRecommendationCount == 0, let next = aiNextAvailableDate else {
            return LF("%d generations remaining today", aiRemainingRecommendationCount)
        }
        let seconds = max(0, Int(ceil(next.timeIntervalSinceNow)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600 + 59) / 60
        if hours > 0 {
            return LF("Available again in %d hours %d minutes", hours, minutes)
        }
        return LF("Available again in %d minutes", max(1, minutes))
    }

    var visibleItems: [MenuBarItem] {
        items.filter { disposition(for: $0) == .visible }
    }

    var hiddenItems: [MenuBarItem] {
        items.filter { disposition(for: $0) == .hidden }
    }

    var filteredItems: [MenuBarItem] {
        items.filter { item in
            guard !item.isProtected else { return false }
            return searchText.isEmpty
                || item.displayName.localizedCaseInsensitiveContains(searchText)
                || item.detail.localizedCaseInsensitiveContains(searchText)
        }
    }

    var filteredVisibleItems: [MenuBarItem] {
        filteredItems.filter {
            sectionDisposition(for: $0) == .visible
                && ($0.frame.width > 1 || $0.isOpenNotchControl)
        }
    }

    var filteredHiddenItems: [MenuBarItem] {
        filteredItems.filter { sectionDisposition(for: $0) == .hidden }
    }

    var filteredInactiveItems: [MenuBarItem] {
        filteredItems.filter {
            sectionDisposition(for: $0) == .visible
                && $0.frame.width <= 1
                && !$0.semanticIdentifier.hasPrefix("module:")
        }
    }

    private func sectionDisposition(for item: MenuBarItem) -> ItemDisposition {
        sectionDispositions[item.id] ?? disposition(for: item)
    }

    /// Refresh the visible/hidden grouping at a deliberate UI boundary. A
    /// toggle changes policy immediately, but the row stays in place until
    /// the user changes panes, rescans, or reopens settings.
    func refreshMenuItemSections() {
        sectionDispositions = Dictionary(uniqueKeysWithValues: items.map { ($0.id, disposition(for: $0)) })
        objectWillChange.send()
    }

    func start(openSettings: @escaping () -> Void) {
        isStopping = false
        openSettingsAction = openSettings
        hasAccessibilityPermission = AccessibilityResolver.isTrusted()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        Diagnostics.shared.append("App started; macOS=\(ProcessInfo.processInfo.operatingSystemVersionString); accessibility=\(hasAccessibilityPermission); enumeration=\(enumerationName)")
        // Expansion is a temporary preview, not a preference. Always start with
        // hidden items actually offscreen so the UI matches the menu bar.
        settings.isExpanded = false
        updateDisplayState(reason: L("Display configuration changed"), apply: false)

        let statusBar = StatusBarController()
        statusBar.onToggle = { [weak self] in self?.toggleExpanded() }
        statusBar.onOpenSettings = { [weak self] in self?.openSettingsAction?() }
        statusBar.onRefresh = { [weak self] in self?.refresh(reason: L("Manual scan"), reconcile: true) }
        statusBar.onToggleGuardian = { [weak self] in self?.toggleGuardian() }
        statusBar.onRestart = { [weak self] in self?.restartApplication() }
        statusBar.onExportDebug = { [weak self] in self?.exportDebugReport() }
        self.statusBar = statusBar
        restorePersistedWindowBindings()
        refreshMenuItemSections()
        updateStatusBar()

        configureObservers()
        configureTimer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            if
                self.hasAccessibilityPermission,
                !self.settings.isExpanded,
                self.itemsByWindowID.isEmpty,
                self.settings.windowBindings.isEmpty,
                self.settings.policies.values.contains(.hidden)
            {
                self.beginIdentityRebind(reason: L("First upgrade: identifying menu bar items"))
            } else {
                self.refresh(reason: L("Startup scan"), reconcile: true)
            }
        }
    }

    func stop() {
        isStopping = true
        timer?.invalidate()
        timer = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        pendingRefresh = nil
        menuBarAgentVisibility.invalidate()
        Diagnostics.shared.append("App stopping; MenuBarAgent restriction released")
    }

    func requestAccessibilityPermission() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        schedulePermissionChecks()
    }

    func recheckAccessibilityPermission() {
        let wasTrusted = hasAccessibilityPermission
        hasAccessibilityPermission = AccessibilityResolver.isTrusted()
        updateStatusBar()
        if hasAccessibilityPermission {
            if
                !wasTrusted,
                !settings.isExpanded,
                itemsByWindowID.isEmpty,
                settings.windowBindings.isEmpty
            {
                beginIdentityRebind(reason: L("Permission active: identifying menu bar items"))
            } else {
                refresh(reason: L("Accessibility authorized"), reconcile: true)
            }
        }
    }

    func restartApplication() {
        // Release the native visibility assertion before the replacement
        // process starts. Keeping both alive even briefly can leave the old
        // process in control of hidden items.
        stop()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundlePath]
        do {
            try task.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                NSApp.terminate(nil)
            }
        } catch {
            Diagnostics.shared.append("Restart failed; error=\(error.localizedDescription)")
            addEvent(LF("Restart failed: %@", error.localizedDescription))
            isStopping = false
            configureObservers()
            configureTimer()
            refresh(reason: L("Restart failed"), reconcile: true)
        }
    }

    func reorderMenuBarItem(sourceID: String, targetID: String) {
        let physicalItems = items.filter {
            disposition(for: $0) == .visible
                && ($0.frame.width > 1 || $0.isOpenNotchControl)
        }.sorted { $0.frame.minX < $1.frame.minX }
        guard MenuBarAgentBridge.isAvailable,
              let sourceIndex = physicalItems.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = physicalItems.firstIndex(where: { $0.id == targetID }),
              sourceIndex != targetIndex
        else { return }

        let source = physicalItems[sourceIndex]
        let target = physicalItems[targetIndex]
        guard !source.isProtected, !target.isProtected else { return }
        let placeAfterTarget = sourceIndex < targetIndex

        // Our AppKit status item does not appear in MenuBarAgent's persisted
        // position dictionary. Command-drag it directly; AppKit persists the
        // resulting position through its autosave name.
        if source.isOpenNotchControl || target.isOpenNotchControl {
            let moved: Bool
            if source.isOpenNotchControl {
                moved = statusBar?.moveToggle(adjacentTo: target, placeAfter: placeAfterTarget) ?? false
            } else {
                moved = statusBar?.moveToggle(adjacentTo: source, placeAfter: !placeAfterTarget) ?? false
            }
            let liveResult = MenuBarMoveEngine.reorder(
                source,
                adjacentTo: target,
                placeAfterTarget: placeAfterTarget
            )
            Diagnostics.shared.append("Open Notch menu item reorder saved=\(moved); live=\(String(describing: liveResult))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.refresh(reason: L("Manual reorder"), reconcile: false)
            }
            return
        }
        guard MenuBarAgentBridge.moveItem(
            source.semanticIdentifier,
            adjacentTo: target.semanticIdentifier,
            placeAfterTarget: placeAfterTarget,
            liveOrder: physicalItems.map(\.semanticIdentifier)
        ) else {
            Diagnostics.shared.append("MenuBarAgent reorder failed; source=\(source.id); target=\(target.id)")
            addEvent(L("Could not reorder menu bar item"))
            return
        }

        statusBar?.requestMenuBarPositionRefresh()
        Diagnostics.shared.append("Menu bar order saved and layout refresh requested without restarting MenuBarAgent")

        // Some macOS 27 betas persist the preferred-position swap but never
        // apply it to live AX geometry. Verify the actual coordinates, then use
        // the system Command-drag interaction only as a cursor-shielded fallback.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            guard let self else { return }
            let live = MenuBarAgentBridge.items()
            guard let liveSource = live.first(where: { $0.id == source.id }),
                  let liveTarget = live.first(where: { $0.id == target.id })
            else { return }
            let applied = placeAfterTarget
                ? liveSource.frame.minX > liveTarget.frame.minX
                : liveSource.frame.minX < liveTarget.frame.minX
            guard !applied else {
                self.items = live
                Diagnostics.shared.append("Menu bar reorder verified from live AX geometry")
                return
            }
            let result = MenuBarMoveEngine.reorder(
                liveSource,
                adjacentTo: liveTarget,
                placeAfterTarget: placeAfterTarget
            )
            Diagnostics.shared.append("Menu bar Command-drag fallback result=\(String(describing: result))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.refresh(reason: L("Manual reorder"), reconcile: false)
            }
        }
    }

    func moveMenuBarItem(_ id: String, offset: Int) {
        guard offset != 0 else { return }
        let sortable = items.filter {
            !$0.isProtected
                && disposition(for: $0) == .visible
                && ($0.frame.width > 1 || $0.isOpenNotchControl)
        }.sorted { $0.frame.minX < $1.frame.minX }
        guard let index = sortable.firstIndex(where: { $0.id == id }) else { return }
        let targetIndex = index + offset
        guard sortable.indices.contains(targetIndex) else { return }
        reorderMenuBarItem(sourceID: id, targetID: sortable[targetIndex].id)
    }

    func exportDebugReport() {
        guard let url = Diagnostics.shared.exportReport(summary: diagnosticSummary()) else {
            addEvent(L("Debug log export failed"))
            return
        }
        addEvent(L("Debug log exported to Desktop"))
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func diagnosticSummary() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
#if arch(arm64)
        let architecture = "arm64"
#elseif arch(x86_64)
        let architecture = "x86_64"
#else
        let architecture = "unknown"
#endif
        let boundaryID = statusBar?.boundaryWindowID.map(String.init) ?? "nil"
        let toggleID = statusBar?.toggleWindowID.map(String.init) ?? "nil"
        let scanDate = lastScanDate.map { ISO8601DateFormatter().string(from: $0) } ?? "never"
        let itemLines = items.map {
            "- \($0.displayName) | id=\($0.id) | window=\($0.windowID) | pid=\($0.hostPID) | " +
            "owner=\($0.hostBundleIdentifier) | semantic=\($0.semanticBundleIdentifier) | " +
            "actual=\(disposition(for: $0).rawValue) | wanted=\(settings.disposition(for: $0).rawValue) | " +
            "frame=\(NSStringFromRect($0.frame))"
        }.joined(separator: "\n")
        return """
        App: Open Notch \(version) (\(build))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Architecture: \(architecture)
        Enumeration: \(enumerationName)
        Accessibility: \(hasAccessibilityPermission)
        Expanded: \(settings.isExpanded)
        Continuous monitor: \(settings.continuousMonitorEnabled)
        OneDrive guardian: \(settings.oneDriveGuardianEnabled)
        OneDrive running: \(isOneDriveRunning)
        Item count: \(items.count)
        Visible count: \(visibleItems.count)
        Hidden count: \(hiddenItems.count)
        Boundary window ID: \(boundaryID)
        Toggle window ID: \(toggleID)
        Last scan: \(scanDate)
        Guardian events: \(guardianEvents.map(\.message).joined(separator: " | "))

        Items
        -----
        \(itemLines.isEmpty ? "(none)" : itemLines)
        """
    }

    func refresh(reason: String = L("Scan"), reconcile: Bool = false) {
        guard !isStopping else { return }
        guard !isRequestingAIRecommendation else {
            if pendingRefresh == nil || reconcile {
                pendingRefresh = (reason, reconcile)
            }
            Diagnostics.shared.append("Scan deferred while AI recommendation is running; reason=\(reason)")
            return
        }
        guard !isScanning else {
            // Coalesce bursts from timers, workspace notifications, and user actions.
            if pendingRefresh == nil || reconcile {
                pendingRefresh = (reason, reconcile)
            }
            Diagnostics.shared.append("Scan coalesced; reason=\(reason); reconcile=\(reconcile)")
            return
        }
        Diagnostics.shared.append("Scan started; reason=\(reason); reconcile=\(reconcile)")
        isScanning = true
        let isTrusted = AccessibilityResolver.isTrusted()
        if hasAccessibilityPermission != isTrusted {
            hasAccessibilityPermission = isTrusted
            updateStatusBar()
        }
        let excluded = statusBar?.excludedWindowIDs ?? []
        let previousItems = Array(itemsByWindowID.values)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scanned = MenuBarDiscovery.scan(excluding: excluded, previousItems: previousItems)
            DispatchQueue.main.async {
                guard let self else { return }
                guard !self.isStopping else {
                    self.isScanning = false
                    return
                }
                var resolvedItems = scanned
                if let toggle = self.statusBar?.toggleMenuBarItem {
                    resolvedItems.removeAll(where: { $0.isOpenNotchControl })
                    resolvedItems.append(toggle)
                }
                resolvedItems.sort { $0.frame.minX < $1.frame.minX }
                let scanChanged = !self.isEquivalentScan(resolvedItems)
                self.itemsByWindowID = Dictionary(
                    resolvedItems.map { ($0.windowID, $0) },
                    uniquingKeysWith: { current, _ in current }
                )
                if scanChanged || resolvedItems.contains(where: { $0.isOpenNotchControl }) {
                    self.items = resolvedItems.sorted { lhs, rhs in
                        // MenuBarAgent positions are the user's physical order.
                        // Preserve them on macOS 27 so drag sorting remains
                        // stable; the legacy path keeps OneDrive prominent.
                        if !MenuBarAgentBridge.isAvailable, lhs.isOneDrive != rhs.isOneDrive {
                            return lhs.isOneDrive
                        }
                        return lhs.frame.minX < rhs.frame.minX
                    }
                }
                self.refreshMenuItemSections()
                self.updateActualDispositions()
                if let own = resolvedItems.first(where: { $0.isOpenNotchControl }) {
                    Diagnostics.shared.append("Open Notch inventory item; frame=\(NSStringFromRect(own.frame)); protected=\(own.isProtected); disposition=\(self.disposition(for: own).rawValue)")
                } else {
                    Diagnostics.shared.append("Open Notch inventory item missing after status-item merge")
                }
                self.settings.remember(resolvedItems)
                self.applyMenuBarAgentVisibility(reason: reason)
                self.lastScanDate = .now
                self.isScanning = false
                Diagnostics.shared.append("Scan finished; source=\(self.enumerationName); items=\(resolvedItems.count); visible=\(self.visibleItems.count); hidden=\(self.hiddenItems.count); accessibility=\(self.hasAccessibilityPermission)")
                self.objectWillChange.send()

                if self.identityRebindInProgress {
                    self.finishIdentityRebind()
                    return
                }
                if reconcile { self.reconcile(reason: reason) }
                self.runPendingRefreshIfNeeded()
            }
        }
    }

    private func isEquivalentScan(_ scanned: [MenuBarItem]) -> Bool {
        guard scanned.count == items.count else { return false }
        let currentByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return scanned.allSatisfy { item in
            guard let current = currentByID[item.id] else { return false }
            return current.displayName == item.displayName
                && current.symbolName == item.symbolName
                && current.semanticBundleIdentifier == item.semanticBundleIdentifier
                && abs(current.frame.minX - item.frame.minX) < 0.5
                && abs(current.frame.maxX - item.frame.maxX) < 0.5
        }
    }

    private func runPendingRefreshIfNeeded() {
        guard let pendingRefresh else { return }
        self.pendingRefresh = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.refresh(reason: pendingRefresh.reason, reconcile: pendingRefresh.reconcile)
        }
    }

    func setDisposition(_ disposition: ItemDisposition, for item: MenuBarItem) {
        guard !item.isOpenNotchControl || disposition == .visible else { return }
        Diagnostics.shared.append("User disposition; item=\(item.displayName); id=\(item.id); window=\(item.windowID); hostPID=\(item.hostPID); target=\(disposition.rawValue)")
        prepareNativePosition(for: item, movingTo: disposition)
        settings.setDisposition(disposition, for: item.id)
        layoutReconciler.reset(item.id)
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
        if MenuBarAgentBridge.isAvailable {
            applyMenuBarAgentVisibility(reason: L("User change"))
            return
        }
        move(
            item,
            to: disposition,
            reason: L("User change"),
            force: true,
            collapseAfterSuccess: disposition == .hidden
        )
    }

    func requestAIRecommendation() {
        guard canRequestAIRecommendation else {
            aiRecommendationMessage = aiAvailabilityMessage
            return
        }
        let manageable = items.filter { !$0.isProtected }
        guard !manageable.isEmpty else {
            aiRecommendationMessage = L("No menu bar items are available for AI analysis")
            return
        }

        updateActualDispositions()
        isRequestingAIRecommendation = true
        aiRequestPhase = .preparing
        aiRecommendationMessage = nil
        let snapshotItems = manageable
        let snapshotDispositions = Dictionary(uniqueKeysWithValues: snapshotItems.map { ($0.id, disposition(for: $0)) })
        aiRecommendationItems = snapshotItems
        aiRecommendationBeforeDispositions = snapshotDispositions
        aiRecommendation = nil
        selectedAIPlanID = nil
        let language = settings.language
        let installationID = settings.aiInstallationID
        aiRequestPhase = .analyzing

        Task { [weak self] in
            do {
                let recommendation = try await AIRecommendationService.shared.request(
                    items: snapshotItems,
                    dispositions: snapshotDispositions,
                    language: language,
                    installationID: installationID
                )
                guard let self else { return }
                self.aiRequestPhase = .finalizing
                ApplicationIconResolver.shared.preload(snapshotItems)
                self.aiRecommendation = recommendation
                self.selectedAIPlanID = recommendation.recommendedPlan?.id
                let descriptions: [String: String] = Dictionary(uniqueKeysWithValues: recommendation.descriptions.compactMap { description -> (String, String)? in
                    guard
                        let index = Int(description.id.replacingOccurrences(of: "item-", with: "")),
                        snapshotItems.indices.contains(index)
                    else { return nil }
                    return (snapshotItems[index].id, description.description)
                })
                self.settings.setAIDescriptions(descriptions, language: language)
                self.settings.recordAIRecommendation()
                self.aiRecommendationMessage = L("Two AI layouts are ready. Review them before applying.")
                self.isRequestingAIRecommendation = false
                self.aiRequestPhase = nil
                self.runPendingRefreshIfNeeded()
            } catch {
                guard let self else { return }
                self.aiRecommendationMessage = error.localizedDescription
                self.isRequestingAIRecommendation = false
                self.aiRequestPhase = nil
                self.runPendingRefreshIfNeeded()
            }
        }
    }

    func aiBeforeDisposition(for item: MenuBarItem) -> ItemDisposition {
        aiRecommendationBeforeDispositions[item.id] ?? settings.disposition(for: item)
    }

    var canApplyAIRecommendation: Bool {
        guard let recommendation = aiRecommendation, !isRequestingAIRecommendation, !isApplyingAIRecommendation, !aiRecommendationItems.isEmpty else { return false }
        let snapshotIDs = Set(aiRecommendationItems.map(\.id))
        return recommendation.plans.contains { plan in
            Set(plan.items.map { item in
                guard let index = Int(item.id.replacingOccurrences(of: "item-", with: "")) else { return "" }
                return aiRecommendationItems.indices.contains(index) ? aiRecommendationItems[index].id : ""
            }).isSubset(of: snapshotIDs)
        }
    }

    var isApplyingAIRecommendation: Bool {
        !aiApplyQueue.isEmpty || aiApplyChangedCount > 0
    }

    func applyAIRecommendation(_ plan: AIRecommendationPlan) {
        guard canApplyAIRecommendation else {
            aiRecommendationMessage = L("The scan changed. Generate a new plan before applying it.")
            return
        }
        var previous = [String: ItemDisposition]()
        var queue = [(MenuBarItem, ItemDisposition)]()
        for decision in plan.items {
            guard
                let index = Int(decision.id.replacingOccurrences(of: "item-", with: "")),
                aiRecommendationItems.indices.contains(index)
            else { continue }
            let item = aiRecommendationItems[index]
            guard !item.isProtected, !(item.isOneDrive && settings.oneDriveGuardianEnabled) else { continue }
            previous[item.id] = aiBeforeDisposition(for: item)
            if aiBeforeDisposition(for: item) != decision.disposition {
                queue.append((item, decision.disposition))
            }
            prepareNativePosition(for: item, movingTo: decision.disposition)
            settings.setDisposition(decision.disposition, for: item.id)
            layoutReconciler.reset(item.id)
        }
        aiUndoPolicies = previous
        aiApplyQueue = queue
        aiApplyChangedCount = queue.count
        aiApplyCompletionMessage = LF("AI layout applied to %d items", queue.count)
        aiRecommendationMessage = LF("Applying AI layout to %d items…", queue.count)
        objectWillChange.send()
        if MenuBarAgentBridge.isAvailable {
            aiApplyQueue.removeAll()
            aiApplyChangedCount = 0
            aiApplyCompletionMessage = ""
            applyMenuBarAgentVisibility(reason: L("AI layout application"))
            aiRecommendationMessage = LF("AI layout applied to %d items", queue.count)
            refresh(reason: L("AI layout application"), reconcile: false)
            return
        }
        processNextAIApply()
    }

    func item(forAIRecommendationID recommendationID: String) -> MenuBarItem? {
        guard
            let index = Int(recommendationID.replacingOccurrences(of: "item-", with: "")),
            aiRecommendationItems.indices.contains(index)
        else { return nil }
        return aiRecommendationItems[index]
    }

    func undoAIRecommendation() {
        guard let aiUndoPolicies else { return }
        var queue = [(MenuBarItem, ItemDisposition)]()
        for (id, disposition) in aiUndoPolicies {
            if let item = aiRecommendationItems.first(where: { $0.id == id }) {
                prepareNativePosition(for: item, movingTo: disposition)
            }
            settings.setDisposition(disposition, for: id)
            layoutReconciler.reset(id)
            if let item = aiRecommendationItems.first(where: { $0.id == id }),
               aiBeforeDisposition(for: item) != disposition
            {
                queue.append((item, disposition))
            }
        }
        self.aiUndoPolicies = nil
        aiApplyQueue = queue
        aiApplyChangedCount = queue.count
        aiApplyCompletionMessage = L("Previous menu bar layout restored")
        aiRecommendationMessage = L("Restoring the previous menu bar layout…")
        objectWillChange.send()
        if MenuBarAgentBridge.isAvailable {
            aiApplyQueue.removeAll()
            aiApplyChangedCount = 0
            aiApplyCompletionMessage = ""
            applyMenuBarAgentVisibility(reason: L("AI layout application"))
            aiRecommendationMessage = L("Previous menu bar layout restored")
            refresh(reason: L("AI layout application"), reconcile: false)
            return
        }
        processNextAIApply()
    }

    var canUndoAIRecommendation: Bool { aiUndoPolicies != nil }

    private func processNextAIApply() {
        guard !isMoving else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.processNextAIApply()
            }
            return
        }
        guard !aiApplyQueue.isEmpty else {
            aiRecommendationMessage = aiApplyCompletionMessage
            aiApplyChangedCount = 0
            aiApplyCompletionMessage = ""
            refresh(reason: L("AI layout application"), reconcile: false)
            return
        }
        let next = aiApplyQueue.removeFirst()
        move(next.0, to: next.1, reason: L("AI layout application"), force: true)
    }

    private func scheduleAIReconciliationPasses() {
        for delay in stride(from: 0.0, through: 30.0, by: 2.5) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refresh(reason: L("AI layout application"), reconcile: true)
            }
        }
    }

    func disposition(for item: MenuBarItem) -> ItemDisposition {
        if item.isOpenNotchControl {
            return .visible
        }
        return actualDispositions[item.id] ?? settings.disposition(for: item)
    }

    private func updateActualDispositions() {
        guard let boundaryWindowID = statusBar?.boundaryWindowID,
              let boundary = MenuBarDiscovery.statusWindow(id: boundaryWindowID)
        else {
            actualDispositions = [:]
            return
        }
        actualDispositions = Dictionary(uniqueKeysWithValues: items.map { item in
            let disposition: ItemDisposition = LayoutReconciler.isInSection(
                item.frame,
                disposition: .hidden,
                boundary: boundary.frame
            ) ? .hidden : .visible
            return (item.id, disposition)
        })
    }

    func setDockVisibility(_ visible: Bool) {
        settings.showInDock = visible
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
        if visible { NSApp.activate(ignoringOtherApps: true) }
        objectWillChange.send()
    }

    func toggleExpanded() {
        settings.isExpanded.toggle()
        statusBar?.setExpanded(settings.isExpanded)
        updateStatusBar()
        if settings.isExpanded {
            if MenuBarAgentBridge.isAvailable { menuBarAgentVisibility.invalidate() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.refresh(reason: L("Expand hidden section"), reconcile: false)
            }
        } else if MenuBarAgentBridge.isAvailable {
            applyMenuBarAgentVisibility(reason: L("Collapse hidden section"))
        }
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
    }

    func toggleGuardian() {
        settings.oneDriveGuardianEnabled.toggle()
        updateStatusBar()
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
        if settings.oneDriveGuardianEnabled {
            repairOneDriveNow()
        }
    }

    func repairOneDriveNow() {
        if let oneDriveItem {
            move(oneDriveItem, to: .visible, reason: L("Reset OneDrive manually"), force: true)
        } else {
            refresh(reason: L("Find OneDrive"), reconcile: true)
        }
    }

    func setContinuousMonitor(_ enabled: Bool) {
        settings.continuousMonitorEnabled = enabled
        configureTimer()
        objectWillChange.send()
    }

    func setExternalDisplayMode(_ mode: ExternalDisplayMode) {
        guard settings.externalDisplayMode != mode else { return }
        settings.externalDisplayMode = mode
        updateDisplayState(reason: L("Display mode changed"), apply: true)
    }

    func setLanguage(_ language: AppLanguage) {
        guard settings.language != language else { return }
        settings.language = language
        guardianEvents.removeAll()
        searchText = ""
        updateStatusBar()
        refresh(reason: L("Language changed"), reconcile: false)
        objectWillChange.send()
    }

    func setAppearance(_ mode: AppearanceMode) {
        guard settings.appearanceMode != mode else { return }
        settings.appearanceMode = mode
        settings.applyAppearance()
        updateStatusBar()
        objectWillChange.send()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            guardianEvents.insert(GuardianEvent(date: .now, message: LF("Open at Login setting failed: %@", error.localizedDescription)), at: 0)
        }
    }

    private func reconcile(reason: String) {
        guard settings.continuousMonitorEnabled, !isMoving else { return }
        // Never run automatic menu bar moves while the settings UI is active.
        // The user may be clicking or moving the pointer inside Open Notch;
        // explicit row changes call move(... force: true) directly and remain
        // responsive, while background reconciliation resumes after focus leaves.
        guard !NSApp.isActive else {
            Diagnostics.shared.append("Automatic reconcile paused while settings are active; reason=\(reason)")
            return
        }
        guard let boundaryWindowID = statusBar?.boundaryWindowID,
              let boundary = MenuBarDiscovery.statusWindow(id: boundaryWindowID)
        else { return }

        if
            settings.oneDriveGuardianEnabled,
            oneDriveItem == nil,
            isOneDriveRunning,
            !effectiveExpanded,
            hasAccessibilityPermission,
            !identityRebindInProgress,
            canRebindIdentity
        {
            beginIdentityRebind(reason: L("OneDrive window changed: rebinding"))
            return
        }

        var desiredPositions = [String: ItemDisposition]()
        for item in items where !item.isProtected {
            if shouldShowAllOnExternalDisplay {
                desiredPositions[item.id] = .visible
            } else if settings.policies[item.id] != nil {
                desiredPositions[item.id] = settings.disposition(for: item)
            }
            if item.isOneDrive, settings.oneDriveGuardianEnabled {
                desiredPositions[item.id] = .visible
            }
        }

        guard let intent = layoutReconciler.observe(
            items: items,
            boundary: boundary.frame,
            desiredPositions: desiredPositions
        ) else { return }
        guard canMove(intent.item.id) else { return }

        layoutReconciler.reset(intent.item.id)
        move(intent.item, to: intent.disposition, reason: reason)
    }

    private func move(
        _ item: MenuBarItem,
        to disposition: ItemDisposition,
        reason: String,
        force: Bool = false,
        collapseAfterSuccess: Bool = false
    ) {
        if MenuBarAgentBridge.isAvailable {
            applyMenuBarAgentVisibility(reason: reason)
            if collapseAfterSuccess { collapseHiddenSection() }
            return
        }
        guard !isMoving, hasAccessibilityPermission else {
            Diagnostics.shared.append("Move skipped; item=\(item.displayName); alreadyMoving=\(isMoving); accessibility=\(hasAccessibilityPermission)")
            return
        }
        guard force || canMove(item.id) else {
            Diagnostics.shared.append("Move throttled; item=\(item.displayName)")
            return
        }
        guard let boundaryWindowID = statusBar?.boundaryWindowID,
              let boundary = MenuBarDiscovery.statusWindow(id: boundaryWindowID)
        else {
            Diagnostics.shared.append("Move failed before start; item=\(item.displayName); boundary unavailable")
            if !aiApplyQueue.isEmpty {
                aiApplyQueue.removeAll()
                aiRecommendationMessage = L("The menu bar could not be reached. Check Accessibility permission and try again.")
            }
            return
        }

        if LayoutReconciler.isInSection(item.frame, disposition: disposition, boundary: boundary.frame) {
            if collapseAfterSuccess { collapseHiddenSection() }
            if item.isOneDrive, force {
                addEvent(L("OneDrive is already pinned"))
            }
            Diagnostics.shared.append("Move unnecessary; item=\(item.displayName); already=\(disposition.rawValue)")
            if !aiApplyQueue.isEmpty {
                processNextAIApply()
            }
            return
        }

        isMoving = true
        let moveStartedAt = Date.now
        Diagnostics.shared.append("Move started; item=\(item.displayName); window=\(item.windowID); pid=\(item.hostPID); target=\(disposition.rawValue); reason=\(reason)")
        lastMoveByItem[item.id] = .now
        let excludedWindowIDs = statusBar?.excludedWindowIDs ?? []
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = MenuBarMoveEngine.move(
                item,
                to: disposition,
                boundary: boundary,
                excluding: excludedWindowIDs
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.isMoving = false
                let resultName: String
                switch result {
                case .moved: resultName = "moved"
                case .deferredForUserInput: resultName = "deferredForUserInput"
                case .failed: resultName = "failed"
                }
                Diagnostics.shared.append("Move finished; item=\(item.displayName); result=\(resultName); elapsed=\(String(format: "%.3f", Date.now.timeIntervalSince(moveStartedAt)))s")
                if result.succeeded, item.isOneDrive {
                    self.settings.repairCount += 1
                    self.addEvent(LF("OneDrive automatically restored · %@", reason))
                }
                if result.succeeded {
                    self.failedMoveUntil[item.id] = nil
                }
                if result.succeeded, collapseAfterSuccess {
                    self.collapseHiddenSection()
                }
                if case .deferredForUserInput = result {
                    self.lastMoveByItem[item.id] = nil
                    self.layoutReconciler.reset(item.id)
                } else if case .failed = result {
                    // Do not let the five-second monitor repeatedly trigger a
                    // synthetic drag for an item that the current OS refuses
                    // to move. An explicit user click still bypasses this.
                    self.failedMoveUntil[item.id] = .now.addingTimeInterval(30)
                    self.addEvent(LF("Could not move %@. Check Accessibility permission.", item.displayName))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    guard let self else { return }
                    self.refresh(reason: L("Post-move verification"), reconcile: false)
                    if !self.aiApplyQueue.isEmpty {
                        self.processNextAIApply()
                    } else if self.aiApplyChangedCount > 0 {
                        self.processNextAIApply()
                    }
                }
            }
        }
    }

    private func canMove(_ id: String) -> Bool {
        if let retryDate = failedMoveUntil[id], retryDate > .now { return false }
        guard let lastMove = lastMoveByItem[id] else { return true }
        return Date.now.timeIntervalSince(lastMove) > 4
    }

    private func prepareNativePosition(for item: MenuBarItem, movingTo disposition: ItemDisposition) {
        guard MenuBarAgentBridge.isAvailable else { return }
        let currentDisposition = settings.disposition(for: item)
        switch disposition {
        case .hidden where currentDisposition != .hidden:
            settings.rememberPosition(item.frame.minX, for: item.id)
        case .visible where currentDisposition == .hidden:
            let frontPosition = items
                .filter { $0.id != item.id && settings.disposition(for: $0) == .visible }
                .map(\.frame.minX)
                .min()
                .map { $0 - 16 }
            if let frontPosition {
                _ = MenuBarAgentBridge.restorePosition(frontPosition, for: item.semanticIdentifier)
            } else if let position = settings.rememberedPosition(for: item.id) {
                _ = MenuBarAgentBridge.restorePosition(position, for: item.semanticIdentifier)
            }
        default:
            break
        }
    }

    private var enumerationName: String {
        MenuBarAgentBridge.isAvailable ? MenuBarAgentBridge.enumerationName : WindowServerBridge.enumerationName
    }

    private func applyMenuBarAgentVisibility(reason: String) {
        guard MenuBarAgentBridge.isAvailable, !isStopping else { return }
        // MBAssessmentModeConfiguration expects numeric system-item IDs, not
        // MenuBarAgent's module names. Begin with the complete system set so a
        // previously hidden item can be restored even before it is enumerated.
        var allowedSystemItems = Set(0...8)
        let systemItemIDs: [String: Int] = [
            "Battery": 0, "Bluetooth": 1, "Clock": 2, "Display": 3,
            "Keyboard": 4, "Sound": 5, "WiFi": 6,
            "ScreenMirroring": 7, "BentoBox-0": 8,
        ]
        for item in items where item.semanticIdentifier.hasPrefix("module:") {
            let module = String(item.semanticIdentifier.dropFirst("module:".count))
            if !effectiveExpanded,
               settings.disposition(for: item) == .hidden,
               let id = systemItemIDs[module]
            {
                allowedSystemItems.remove(id)
            }
        }
        var allowed = Set(items.compactMap { item -> String? in
            guard !item.semanticIdentifier.hasPrefix("module:") else { return nil }
            return effectiveExpanded || settings.disposition(for: item) == .visible
                ? item.semanticBundleIdentifier
                : nil
        })
        if settings.oneDriveGuardianEnabled { allowed.insert("com.microsoft.OneDrive") }
        if let ownBundleID = Bundle.main.bundleIdentifier { allowed.insert(ownBundleID) }
        menuBarAgentVisibility.apply(
            allowedSystemItems: allowedSystemItems,
            allowedBundleIdentifiers: allowed
        ) { result in
            DispatchQueue.main.async {
                switch result {
                case .applied:
                    Diagnostics.shared.append("MenuBarAgent restriction applied; allowedBundles=\(allowed.count); reason=\(reason)")
                case .unavailable:
                    Diagnostics.shared.append("MenuBarAgent restriction unavailable; reason=\(reason)")
                case .failed(let message):
                    Diagnostics.shared.append("MenuBarAgent restriction failed; error=\(message); reason=\(reason)")
                }
            }
        }
    }

    private func addEvent(_ message: String) {
        guardianEvents.insert(GuardianEvent(date: .now, message: message), at: 0)
        guardianEvents = Array(guardianEvents.prefix(8))
    }

    private var isOneDriveRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.microsoft.OneDrive" }
    }

    private var canRebindIdentity: Bool {
        guard let lastIdentityRebind else { return true }
        return Date.now.timeIntervalSince(lastIdentityRebind) > 10
    }

    private func beginIdentityRebind(reason: String) {
        guard hasAccessibilityPermission, !identityRebindInProgress else { return }
        Diagnostics.shared.append("Identity rebind started; reason=\(reason)")
        identityRebindInProgress = true
        identityRebindShouldRecollapse = !settings.isExpanded
        lastIdentityRebind = .now
        statusBar?.setExpanded(true)
        addEvent(reason)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.refresh(reason: L("Identity rebinding"), reconcile: false)
        }
    }

    private func finishIdentityRebind() {
        guard identityRebindInProgress else { return }
        Diagnostics.shared.append("Identity rebind finished; items=\(items.count)")
        identityRebindInProgress = false
        if identityRebindShouldRecollapse {
            statusBar?.setExpanded(false)
        }
        identityRebindShouldRecollapse = false
        updateStatusBar()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refresh(reason: L("Post-rebind verification"), reconcile: true)
        }
    }

    private func collapseHiddenSection() {
        guard settings.isExpanded else { return }
        settings.isExpanded = false
        updateStatusBar()
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
    }

    private func restorePersistedWindowBindings() {
        let excluded = statusBar?.excludedWindowIDs ?? []
        let restored = settings.restoredItems(
            from: MenuBarDiscovery.statusWindows().filter { !excluded.contains($0.windowID) }
        )
        itemsByWindowID = Dictionary(
            restored.map { ($0.windowID, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        items = restored.sorted { lhs, rhs in
            if lhs.isOneDrive != rhs.isOneDrive { return lhs.isOneDrive }
            return lhs.frame.minX < rhs.frame.minX
        }
    }

    private func updateStatusBar() {
        statusBar?.setExpanded(effectiveExpanded)
        statusBar?.updateMenu(
            isExpanded: effectiveExpanded,
            guardianEnabled: settings.oneDriveGuardianEnabled,
            hasAccessibilityPermission: hasAccessibilityPermission
        )
    }

    private func configureTimer() {
        timer?.invalidate()
        timer = nil
        guard settings.continuousMonitorEnabled else { return }
        timer = .scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(reason: L("Continuous monitoring"), reconcile: true) }
        }
        timer?.tolerance = 1.0
    }

    private func configureObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        self?.refresh(reason: L("System state changed"), reconcile: true)
                    }
                }
            }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recheckAccessibilityPermission() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateDisplayState(reason: L("Display configuration changed"), apply: true)
            }
        })
    }

    private func updateDisplayState(reason: String, apply: Bool) {
        let screens = NSScreen.screens
        let displayInfo = screens.compactMap { screen -> (screen: NSScreen, builtIn: Bool)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return (screen, CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0)
        }
        externalDisplayConnected = displayInfo.contains { !$0.builtIn }
        let primary = displayInfo.first { abs($0.screen.frame.minX) < 0.5 && abs($0.screen.frame.minY) < 0.5 }
        externalDisplayIsPrimary = primary.map { !$0.builtIn } ?? false
        Diagnostics.shared.append(
            "Display mode applied; reason=\(reason); externalConnected=\(externalDisplayConnected); " +
            "externalPrimary=\(externalDisplayIsPrimary); mode=\(settings.externalDisplayMode.rawValue)"
        )
        updateStatusBar()
        objectWillChange.send()
        guard apply else { return }
        if MenuBarAgentBridge.isAvailable {
            applyMenuBarAgentVisibility(reason: reason)
        }
        refresh(reason: reason, reconcile: true)
    }

    private func schedulePermissionChecks() {
        for delay in [1.0, 3.0, 6.0, 10.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.hasAccessibilityPermission = AccessibilityResolver.isTrusted()
                self.updateStatusBar()
                if self.hasAccessibilityPermission {
                    if
                        !self.settings.isExpanded,
                        self.itemsByWindowID.isEmpty,
                        self.settings.windowBindings.isEmpty
                    {
                        self.beginIdentityRebind(reason: L("Permission active: identifying menu bar items"))
                    } else {
                        self.refresh(reason: L("Accessibility authorized"), reconcile: true)
                    }
                }
            }
        }
    }
}
