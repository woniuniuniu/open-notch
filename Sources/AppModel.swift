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
    private(set) var lastScanDate: Date?
    @Published private(set) var launchAtLogin = false
    @Published private(set) var aiRecommendation: AIRecommendation?
    @Published private(set) var isRequestingAIRecommendation = false
    @Published private(set) var aiRecommendationMessage: String?
    @Published private(set) var aiRequestPhase: AIRequestPhase?
    @Published var selectedAIPlanID: String?
    @Published var selectedPane: SettingsPane? = .menuItems
    @Published var searchText = ""

    let settings = SettingsStore.shared

    private var statusBar: StatusBarController?
    private var timer: Timer?
    private var observers = [NSObjectProtocol]()
    private var scanInProgress = false
    private var isMoving = false
    private var pendingRefresh: (reason: String, reconcile: Bool, showsProgress: Bool)?
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
    private var pendingAIRequest = false
    private var permissionCheckToken = UUID()
    private struct PendingExplicitMove {
        let item: MenuBarItem
        let disposition: ItemDisposition
        let reason: String
        let collapseAfterSuccess: Bool
    }
    private var pendingExplicitMoves = [String: PendingExplicitMove]()
    private var pendingExplicitMoveOrder = [String]()

    private init() {}

    var oneDriveItem: MenuBarItem? { items.first(where: \.isOneDrive) }

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
        !isRequestingAIRecommendation && !scanInProgress && aiRemainingRecommendationCount > 0
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

    private var currentlyManageableItems: [MenuBarItem] {
        let manageable = items.filter { !$0.isProtected }
        guard PlatformVersion.isMacOS27OrNewer else { return manageable }
        var seenBundles = Set<String>()
        return manageable.filter { item in
            guard !item.semanticBundleIdentifier.isEmpty else { return false }
            return seenBundles.insert(item.semanticBundleIdentifier).inserted
        }
    }

    var managedItems: [MenuBarItem] {
        let current = currentlyManageableItems
        let currentBundles = Set(current.map(\.semanticBundleIdentifier))
        var latestByBundle = [String: KnownMenuBarItem]()
        for known in settings.knownItems.values where !currentBundles.contains(known.semanticBundleIdentifier) {
            guard
                !known.semanticBundleIdentifier.isEmpty,
                !(PlatformVersion.isMacOS27OrNewer && known.semanticBundleIdentifier.hasPrefix("com.apple."))
            else { continue }
            if latestByBundle[known.semanticBundleIdentifier].map({ $0.lastSeen < known.lastSeen }) ?? true {
                latestByBundle[known.semanticBundleIdentifier] = known
            }
        }
        let dormant: [MenuBarItem] = latestByBundle.values.map { known in
            let resolvedName = ApplicationIconResolver.shared.applicationName(
                for: known.semanticBundleIdentifier,
                fallback: known.displayName
            )
            return MenuBarItem(
                id: known.id,
                windowID: 0,
                hostPID: 0,
                hostBundleIdentifier: known.semanticBundleIdentifier,
                semanticBundleIdentifier: known.semanticBundleIdentifier,
                semanticIdentifier: known.semanticIdentifier ?? "",
                rawTitle: known.detail,
                displayName: resolvedName,
                symbolName: known.symbolName,
                frame: .zero,
                isProtected: false
            )
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return current + dormant
    }

    func isItemCurrentlyAvailable(_ item: MenuBarItem) -> Bool {
        items.contains { $0.id == item.id && !$0.isProtected }
    }

    var filteredItems: [MenuBarItem] {
        guard !searchText.isEmpty else { return managedItems }
        return managedItems.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
                || $0.detail.localizedCaseInsensitiveContains(searchText)
        }
    }

    func start(openSettings: @escaping () -> Void) {
        openSettingsAction = openSettings
        hasAccessibilityPermission = AccessibilityResolver.isTrusted()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        Diagnostics.shared.append("App started; macOS=\(ProcessInfo.processInfo.operatingSystemVersionString); accessibility=\(hasAccessibilityPermission); enumeration=\(WindowServerBridge.enumerationName)")
        // Expansion is a temporary preview, not a preference. Always start with
        // hidden items actually offscreen so the UI matches the menu bar.
        settings.isExpanded = false

        let statusBar = StatusBarController()
        statusBar.onShowHiddenItems = { [weak self] in self?.showHiddenItemsPopover() }
        statusBar.onOpenSettings = { [weak self] in self?.openSettingsAction?() }
        statusBar.onRefresh = { [weak self] in self?.refresh(reason: L("Manual scan"), reconcile: true) }
        statusBar.onRestart = { [weak self] in self?.restartApplication() }
        statusBar.onExportDebug = { [weak self] in self?.exportDebugReport() }
        self.statusBar = statusBar
        restorePersistedWindowBindings()
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
        }
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
        Enumeration: \(WindowServerBridge.enumerationName)
        Accessibility: \(hasAccessibilityPermission)
        Expanded: \(settings.isExpanded)
        Continuous monitor: \(settings.continuousMonitorEnabled)
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

    func refresh(
        reason: String = L("Scan"),
        reconcile: Bool = false,
        showsProgress: Bool = false
    ) {
        guard !isRequestingAIRecommendation else {
            queuePendingRefresh(reason: reason, reconcile: reconcile, showsProgress: showsProgress)
            Diagnostics.shared.append("Scan deferred while AI recommendation is running; reason=\(reason)")
            return
        }
        guard !scanInProgress else {
            // Coalesce bursts from timers, workspace notifications, and user actions.
            queuePendingRefresh(reason: reason, reconcile: reconcile, showsProgress: showsProgress)
            Diagnostics.shared.append("Scan coalesced; reason=\(reason); reconcile=\(reconcile)")
            return
        }
        Diagnostics.shared.append("Scan started; reason=\(reason); reconcile=\(reconcile)")
        scanInProgress = true
        if showsProgress { isScanning = true }
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
                let scanChanged = !self.isEquivalentScan(scanned)
                self.itemsByWindowID = Dictionary(
                    scanned.map { ($0.windowID, $0) },
                    uniquingKeysWith: { current, _ in current }
                )
                if scanChanged {
                    self.items = scanned.sorted { $0.frame.minX < $1.frame.minX }
                }
                let actualChanged = self.updateActualDispositions()
                self.settings.remember(scanned)
                self.lastScanDate = .now
                self.scanInProgress = false
                if self.isScanning { self.isScanning = false }
                Diagnostics.shared.append("Scan finished; items=\(scanned.count); visible=\(self.visibleItems.count); hidden=\(self.hiddenItems.count); accessibility=\(self.hasAccessibilityPermission)")
                if scanChanged || actualChanged { self.objectWillChange.send() }

                if self.identityRebindInProgress {
                    self.finishIdentityRebind()
                    return
                }
                if reconcile { self.reconcile(reason: reason) }
                self.runPendingRefreshIfNeeded()
                if self.pendingAIRequest {
                    self.pendingAIRequest = false
                    DispatchQueue.main.async { [weak self] in self?.requestAIRecommendation() }
                }
            }
        }
    }

    private func queuePendingRefresh(reason: String, reconcile: Bool, showsProgress: Bool) {
        guard let current = pendingRefresh else {
            pendingRefresh = (reason, reconcile, showsProgress)
            return
        }
        pendingRefresh = (
            showsProgress ? reason : current.reason,
            current.reconcile || reconcile,
            current.showsProgress || showsProgress
        )
    }

    private func isEquivalentScan(_ scanned: [MenuBarItem]) -> Bool {
        guard scanned.count == items.count else { return false }
        let currentByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return scanned.allSatisfy { item in
            guard let current = currentByID[item.id] else { return false }
            return current.displayName == item.displayName
                && current.symbolName == item.symbolName
                && current.semanticBundleIdentifier == item.semanticBundleIdentifier
                && current.semanticIdentifier == item.semanticIdentifier
                && current.windowID == item.windowID
                && current.hostPID == item.hostPID
                && current.isProtected == item.isProtected
                && abs(current.frame.minX - item.frame.minX) < 0.5
                && abs(current.frame.maxX - item.frame.maxX) < 0.5
                && abs(current.frame.minY - item.frame.minY) < 0.5
                && abs(current.frame.maxY - item.frame.maxY) < 0.5
        }
    }

    private func runPendingRefreshIfNeeded() {
        guard let pendingRefresh else { return }
        self.pendingRefresh = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.refresh(
                reason: pendingRefresh.reason,
                reconcile: pendingRefresh.reconcile,
                showsProgress: pendingRefresh.showsProgress
            )
        }
    }

    func setDisposition(_ disposition: ItemDisposition, for item: MenuBarItem) {
        Diagnostics.shared.append("User disposition; item=\(item.displayName); id=\(item.id); window=\(item.windowID); hostPID=\(item.hostPID); target=\(disposition.rawValue)")
        settings.setDisposition(disposition, for: item)
        layoutReconciler.reset(item.id)
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
        guard isItemCurrentlyAvailable(item) else {
            Diagnostics.shared.append(
                "Dormant item policy saved; item=\(item.displayName); bundle=\(item.semanticBundleIdentifier); target=\(disposition.rawValue)"
            )
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
        if scanInProgress {
            pendingAIRequest = true
            aiRecommendationMessage = L("Preparing the latest scan")
            return
        }
        guard canRequestAIRecommendation else {
            aiRecommendationMessage = aiAvailabilityMessage
            return
        }
        let manageable = currentlyManageableItems
        guard !manageable.isEmpty else {
            aiRecommendationMessage = L("No menu bar items are available for AI analysis")
            return
        }

        updateActualDispositions()
        isRequestingAIRecommendation = true
        aiRequestPhase = .preparing
        aiRecommendationMessage = nil
        // The cloud contract accepts at most 80 items. Keep the local snapshot
        // identical to what is sent so validation cannot reject a valid reply.
        let snapshotItems = Array(manageable.prefix(80))
        let snapshotDispositions = Dictionary(uniqueKeysWithValues: snapshotItems.map { ($0.id, disposition(for: $0)) })
        aiRecommendationItems = snapshotItems
        aiRecommendationBeforeDispositions = snapshotDispositions
        aiRecommendation = nil
        selectedAIPlanID = nil
        let language = settings.language
        let installationID = settings.aiInstallationID
        let deviceContext = AIRecommendationService.deviceContext()
        Diagnostics.shared.append(
            "AI request context; model=\(deviceContext.modelIdentifier); macOS=\(deviceContext.macOSVersion); " +
            "systemItems=\(deviceContext.systemItemManagement); displays=\(deviceContext.displays.count); items=\(snapshotItems.count)"
        )
        aiRequestPhase = .analyzing

        Task { [weak self] in
            do {
                let recommendation = try await AIRecommendationService.shared.request(
                    items: snapshotItems,
                    dispositions: snapshotDispositions,
                    language: language,
                    installationID: installationID,
                    device: deviceContext
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
                let planSummary = recommendation.plans.map { plan in
                    let changed = plan.items.filter { decision in
                        guard let index = Int(decision.id.replacingOccurrences(of: "item-", with: "")),
                              snapshotItems.indices.contains(index)
                        else { return false }
                        return snapshotDispositions[snapshotItems[index].id] != decision.disposition
                    }.count
                    return "\(plan.id):\(changed)"
                }.joined(separator: ",")
                Diagnostics.shared.append("AI recommendation received; recommended=\(recommendation.recommendedPlanID); changes=\(planSummary)")
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
        let currentIDs = Set(currentlyManageableItems.prefix(80).map(\.id))
        guard currentIDs == snapshotIDs else { return false }
        return recommendation.plans.allSatisfy { plan in
            let planIDs = Set(plan.items.compactMap { item -> String? in
                guard let index = Int(item.id.replacingOccurrences(of: "item-", with: "")) else { return nil }
                return aiRecommendationItems.indices.contains(index) ? aiRecommendationItems[index].id : nil
            })
            return planIDs == snapshotIDs && plan.items.count == snapshotIDs.count
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
            guard !item.isProtected else { continue }
            previous[item.id] = aiBeforeDisposition(for: item)
            if aiBeforeDisposition(for: item) != decision.disposition {
                queue.append((item, decision.disposition))
            }
            settings.setDisposition(decision.disposition, for: item)
            layoutReconciler.reset(item.id)
        }
        let changedCount = queue.count
        aiUndoPolicies = previous
        // macOS 27 applies one bundle-set assertion for the complete layout;
        // running the same assertion once per changed row only adds delay.
        aiApplyQueue = PlatformVersion.isMacOS27OrNewer ? Array(queue.prefix(1)) : queue
        aiApplyChangedCount = changedCount
        aiApplyCompletionMessage = LF("AI layout applied to %d items", changedCount)
        aiRecommendationMessage = LF("Applying AI layout to %d items…", changedCount)
        objectWillChange.send()
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
            let current = aiRecommendationItems.first(where: { $0.id == id }).map { self.disposition(for: $0) }
            guard let item = aiRecommendationItems.first(where: { $0.id == id }) else { continue }
            settings.setDisposition(disposition, for: item)
            layoutReconciler.reset(id)
            if current != disposition {
                queue.append((item, disposition))
            }
        }
        let changedCount = queue.count
        self.aiUndoPolicies = nil
        aiApplyQueue = PlatformVersion.isMacOS27OrNewer ? Array(queue.prefix(1)) : queue
        aiApplyChangedCount = changedCount
        aiApplyCompletionMessage = L("Previous menu bar layout restored")
        aiRecommendationMessage = L("Restoring the previous menu bar layout…")
        objectWillChange.send()
        processNextAIApply()
    }

    var canUndoAIRecommendation: Bool { aiUndoPolicies != nil }

    private func processNextAIApply() {
        guard hasAccessibilityPermission else {
            aiApplyQueue.removeAll()
            aiApplyChangedCount = 0
            aiApplyCompletionMessage = ""
            aiRecommendationMessage = L("The menu bar could not be reached. Check Accessibility permission and try again.")
            return
        }
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

    func disposition(for item: MenuBarItem) -> ItemDisposition {
        actualDispositions[item.id] ?? settings.disposition(for: item)
    }

    @discardableResult
    private func updateActualDispositions() -> Bool {
        let previous = actualDispositions
        if PlatformVersion.isMacOS27OrNewer {
            actualDispositions = Dictionary(uniqueKeysWithValues: items.map {
                ($0.id, MacOS27VisibilityController.shared.disposition(for: $0))
            })
            return actualDispositions != previous
        }
        guard let boundaryWindowID = statusBar?.boundaryWindowID,
              let boundary = MenuBarDiscovery.statusWindow(id: boundaryWindowID)
        else {
            actualDispositions = [:]
            return actualDispositions != previous
        }
        actualDispositions = Dictionary(uniqueKeysWithValues: items.map { item in
            let disposition: ItemDisposition = LayoutReconciler.isInSection(
                item.frame,
                disposition: .hidden,
                boundary: boundary.frame
            ) ? .hidden : .visible
            return (item.id, disposition)
        })
        return actualDispositions != previous
    }

    func setDockVisibility(_ visible: Bool) {
        settings.showInDock = visible
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
        if visible { NSApp.activate(ignoringOtherApps: true) }
        objectWillChange.send()
    }

    func setExternalDisplayMode(_ mode: ExternalDisplayMode) {
        guard settings.externalDisplayMode != mode else { return }
        settings.externalDisplayMode = mode
        applyCurrentDisplayMode(reason: L("Display mode changed"))
        objectWillChange.send()
    }

    func setContinuousMonitor(_ enabled: Bool) {
        settings.continuousMonitorEnabled = enabled
        configureTimer()
        objectWillChange.send()
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
        if PlatformVersion.isMacOS27OrNewer {
            guard !settings.isExpanded else { return }
            let succeeded = MacOS27VisibilityController.shared.apply(
                items: items,
                settings: settings,
                showAll: shouldShowAllForCurrentDisplay
            )
            Diagnostics.shared.append("macOS 27 reconcile; reason=\(reason); succeeded=\(succeeded)")
            if updateActualDispositions() {
                objectWillChange.send()
            }
            return
        }
        if shouldShowAllForCurrentDisplay {
            statusBar?.setExpanded(true)
            return
        }
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
            settings.disposition(forBundleIdentifier: "com.microsoft.OneDrive") == .visible,
            oneDriveItem == nil,
            isOneDriveRunning,
            !settings.isExpanded,
            hasAccessibilityPermission,
            !identityRebindInProgress,
            canRebindIdentity
        {
            beginIdentityRebind(reason: L("OneDrive window changed: rebinding"))
            return
        }

        var desiredPositions = [String: ItemDisposition]()
        for item in items where !item.isProtected {
            if settings.hasPolicy(for: item) {
                desiredPositions[item.id] = settings.disposition(for: item)
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
        guard hasAccessibilityPermission else {
            Diagnostics.shared.append("Move skipped; item=\(item.displayName); alreadyMoving=\(isMoving); accessibility=false")
            return
        }
        if isMoving {
            if force {
                pendingExplicitMoves[item.id] = PendingExplicitMove(
                    item: item,
                    disposition: disposition,
                    reason: reason,
                    collapseAfterSuccess: collapseAfterSuccess
                )
                if !pendingExplicitMoveOrder.contains(item.id) {
                    pendingExplicitMoveOrder.append(item.id)
                }
                Diagnostics.shared.append("Move queued; item=\(item.displayName); target=\(disposition.rawValue)")
            } else {
                Diagnostics.shared.append("Move skipped; item=\(item.displayName); alreadyMoving=true; accessibility=true")
            }
            return
        }
        guard force || canMove(item.id) else {
            Diagnostics.shared.append("Move throttled; item=\(item.displayName)")
            return
        }
        if PlatformVersion.isMacOS27OrNewer {
            isMoving = true
            lastMoveByItem[item.id] = .now
            Diagnostics.shared.append("macOS 27 visibility change started; item=\(item.displayName); bundle=\(item.semanticBundleIdentifier); target=\(disposition.rawValue); reason=\(reason)")
            let succeeded = MacOS27VisibilityController.shared.apply(
                items: items,
                settings: settings,
                showAll: shouldShowAllForCurrentDisplay
            )
            isMoving = false
            if succeeded {
                failedMoveUntil[item.id] = nil
                if collapseAfterSuccess { collapseHiddenSection() }
            } else {
                failedMoveUntil[item.id] = .now.addingTimeInterval(30)
                addEvent(LF("Could not move %@. Check Accessibility permission.", item.displayName))
            }
            updateActualDispositions()
            objectWillChange.send()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                self.refresh(reason: L("Post-move verification"), reconcile: false)
                if !self.aiApplyQueue.isEmpty || self.aiApplyChangedCount > 0 {
                    self.processNextAIApply()
                }
            }
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
            if processNextPendingExplicitMove() {
                return
            } else if !aiApplyQueue.isEmpty {
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
                    if self.processNextPendingExplicitMove() {
                        return
                    } else if !self.aiApplyQueue.isEmpty {
                        self.processNextAIApply()
                    } else if self.aiApplyChangedCount > 0 {
                        self.processNextAIApply()
                    }
                }
            }
        }
    }

    @discardableResult
    private func processNextPendingExplicitMove() -> Bool {
        guard !isMoving else { return false }
        while let id = pendingExplicitMoveOrder.first {
            pendingExplicitMoveOrder.removeFirst()
            guard let pending = pendingExplicitMoves.removeValue(forKey: id) else { continue }
            let current = items.first(where: { $0.id == id })
                ?? items.first(where: {
                    $0.semanticBundleIdentifier == pending.item.semanticBundleIdentifier
                })
                ?? pending.item
            move(
                current,
                to: pending.disposition,
                reason: pending.reason,
                force: true,
                collapseAfterSuccess: pending.collapseAfterSuccess
            )
            return true
        }
        return false
    }

    private func canMove(_ id: String) -> Bool {
        if let retryDate = failedMoveUntil[id], retryDate > .now { return false }
        guard let lastMove = lastMoveByItem[id] else { return true }
        return Date.now.timeIntervalSince(lastMove) > 4
    }

    private func addEvent(_ message: String) {
        guardianEvents.insert(GuardianEvent(date: .now, message: message), at: 0)
        guardianEvents = Array(guardianEvents.prefix(8))
    }

    private var isOneDriveRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.microsoft.OneDrive" }
    }

    var hasExternalDisplay: Bool {
        NSScreen.screens.contains { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) == 0
        }
    }

    var mainDisplayIsExternal: Bool {
        CGDisplayIsBuiltin(CGMainDisplayID()) == 0
    }

    private var shouldShowAllForCurrentDisplay: Bool {
        settings.externalDisplayMode == .showAll && mainDisplayIsExternal
    }

    private func applyCurrentDisplayMode(reason: String) {
        Diagnostics.shared.append(
            "Display mode applied; reason=\(reason); externalConnected=\(hasExternalDisplay); " +
            "mainExternal=\(mainDisplayIsExternal); mode=\(settings.externalDisplayMode.rawValue)"
        )
        if PlatformVersion.isMacOS27OrNewer {
            guard !settings.isExpanded else { return }
            _ = MacOS27VisibilityController.shared.apply(
                items: items,
                settings: settings,
                showAll: shouldShowAllForCurrentDisplay
            )
            updateActualDispositions()
        } else {
            statusBar?.setExpanded(settings.isExpanded || shouldShowAllForCurrentDisplay)
        }
    }

    private func showHiddenItemsPopover() {
        let runningBundles = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let hidden = managedItems.filter {
            (isItemCurrentlyAvailable($0) || runningBundles.contains($0.semanticBundleIdentifier))
                && settings.disposition(for: $0) == .hidden
        }
        Diagnostics.shared.append(
            "Hidden-items bar requested; currentItems=\(items.count); configuredHidden=\(hidden.count); " +
            "actualHidden=\(hiddenItems.count)"
        )
        statusBar?.showHiddenItems(
            hidden,
            activate: { [weak self] item in self?.activateMenuBarItem(item) },
            manage: { [weak self] in self?.openSettingsAction?() }
        )
    }

    private func activateMenuBarItem(_ item: MenuBarItem) {
        DispatchQueue.global(qos: .userInitiated).async {
            let pressed = AccessibilityResolver.press(item)
            if !pressed, let app = NSRunningApplication(processIdentifier: item.hostPID) {
                DispatchQueue.main.async { app.activate(options: []) }
            }
        }
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
        items = restored.sorted { $0.frame.minX < $1.frame.minX }
    }

    private func updateStatusBar() {
        statusBar?.setExpanded(settings.isExpanded)
        statusBar?.updateMenu(
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
                self?.statusBar?.closeHiddenItemsBar()
                self?.applyCurrentDisplayMode(reason: L("Display configuration changed"))
                self?.refresh(reason: L("Display configuration changed"), reconcile: true)
            }
        })
    }

    private func schedulePermissionChecks() {
        permissionCheckToken = UUID()
        let token = permissionCheckToken
        for delay in [1.0, 3.0, 6.0, 10.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                guard self.permissionCheckToken == token else { return }
                self.hasAccessibilityPermission = AccessibilityResolver.isTrusted()
                self.updateStatusBar()
                if self.hasAccessibilityPermission {
                    self.permissionCheckToken = UUID()
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
