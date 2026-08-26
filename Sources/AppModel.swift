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
    @Published var selectedPane: SettingsPane? = .overview
    @Published var searchText = ""

    let settings = SettingsStore.shared

    private var statusBar: StatusBarController?
    private var timer: Timer?
    private var observers = [NSObjectProtocol]()
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

    private init() {}

    var isExpanded: Bool { settings.isExpanded }
    var oneDriveItem: MenuBarItem? { items.first(where: \.isOneDrive) }

    var visibleItems: [MenuBarItem] {
        items.filter { disposition(for: $0) == .visible }
    }

    var hiddenItems: [MenuBarItem] {
        items.filter { disposition(for: $0) == .hidden }
    }

    var filteredItems: [MenuBarItem] {
        guard !searchText.isEmpty else { return items.filter { !$0.isProtected } }
        return items.filter {
            !$0.isProtected && ($0.displayName.localizedCaseInsensitiveContains(searchText) || $0.detail.localizedCaseInsensitiveContains(searchText))
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
        statusBar.onToggle = { [weak self] in self?.toggleExpanded() }
        statusBar.onOpenSettings = { [weak self] in self?.openSettingsAction?() }
        statusBar.onRefresh = { [weak self] in self?.refresh(reason: L("Manual scan"), reconcile: true) }
        statusBar.onToggleGuardian = { [weak self] in self?.toggleGuardian() }
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
                self.itemsByWindowID = Dictionary(
                    scanned.map { ($0.windowID, $0) },
                    uniquingKeysWith: { current, _ in current }
                )
                self.items = scanned.sorted { lhs, rhs in
                    if lhs.isOneDrive != rhs.isOneDrive { return lhs.isOneDrive }
                    return lhs.frame.minX < rhs.frame.minX
                }
                self.updateActualDispositions()
                self.settings.remember(scanned)
                self.lastScanDate = .now
                self.isScanning = false
                Diagnostics.shared.append("Scan finished; items=\(scanned.count); visible=\(self.visibleItems.count); hidden=\(self.hiddenItems.count); accessibility=\(self.hasAccessibilityPermission)")
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

    private func runPendingRefreshIfNeeded() {
        guard let pendingRefresh else { return }
        self.pendingRefresh = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.refresh(reason: pendingRefresh.reason, reconcile: pendingRefresh.reconcile)
        }
    }

    func setDisposition(_ disposition: ItemDisposition, for item: MenuBarItem) {
        Diagnostics.shared.append("User disposition; item=\(item.displayName); id=\(item.id); window=\(item.windowID); hostPID=\(item.hostPID); target=\(disposition.rawValue)")
        settings.setDisposition(disposition, for: item.id)
        layoutReconciler.reset(item.id)
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
        move(
            item,
            to: disposition,
            reason: L("User change"),
            force: true,
            collapseAfterSuccess: disposition == .hidden
        )
    }

    func disposition(for item: MenuBarItem) -> ItemDisposition {
        actualDispositions[item.id] ?? settings.disposition(for: item)
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.refresh(reason: L("Expand hidden section"), reconcile: false)
            }
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
            if settings.policies[item.id] != nil {
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
            return
        }

        if LayoutReconciler.isInSection(item.frame, disposition: disposition, boundary: boundary.frame) {
            if collapseAfterSuccess { collapseHiddenSection() }
            if item.isOneDrive, force {
                addEvent(L("OneDrive is already pinned"))
            }
            Diagnostics.shared.append("Move unnecessary; item=\(item.displayName); already=\(disposition.rawValue)")
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
                    self?.refresh(reason: L("Post-move verification"), reconcile: false)
                }
            }
        }
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
        statusBar?.setExpanded(settings.isExpanded)
        statusBar?.updateMenu(
            isExpanded: settings.isExpanded,
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
