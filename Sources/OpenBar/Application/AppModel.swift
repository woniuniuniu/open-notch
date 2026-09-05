import AppKit
import Combine
import Foundation
import OpenBarCore
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var liveItems: [LiveMenuBarItem] = []
    @Published private(set) var isScanning = false
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var lastScanDate: Date?
    @Published private(set) var backendName = ""
    @Published private(set) var capabilities = BackendCapabilities(
        kind: .legacy,
        canInspectItems: false,
        supportsThreeSections: false,
        supportsNativeReorder: false,
        changesArePerApplication: false
    )
    @Published private(set) var activity: [ActivityEntry] = []
    @Published private(set) var aiProposal: AIPlacementProposal?
    @Published private(set) var isAIPlacementLoading = false
    @Published private(set) var aiPlacementNote: String?
    @Published private(set) var hasAIAPIKey = AIConfigurationStore.hasAPIKey
    @Published private(set) var lastOperationMessage: String?
    @Published var selectedPage: NavigationPage = .items
    @Published var selectedItemID: String?
    @Published var sectionFilter: ItemSection?
    @Published var searchText = ""
    @Published var quickBarSearchText = ""

    let store = PolicyStore.shared

    private var backend: MenuBarBackend?
    private var statusBar: StatusBarController?
    private var timer: Timer?
    private var permissionTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var openWindow: (() -> Void)?
    private var driftTracker = DriftTracker()
    private var lastReportedScanCount: Int?
    private var lastGuardianSignature: String?
    private var lastLiveOrderSignature: String?
    private var applyGeneration = 0

    private init() {}

    var canManage: Bool {
        guard let backend else { return false }
        return !backend.requiresAccessibility || hasAccessibilityPermission
    }

    var isExpanded: Bool { store.document.preferences.hiddenSectionExpanded }

    var managedItems: [ManagedMenuBarItem] {
        filteredItems(allManagedItems, query: searchText)
    }

    /// Number of items in the latest live inventory. Historical policies are
    /// intentionally excluded so this value describes the current menu bar.
    var currentItemCount: Int {
        liveItems.count
    }

    var rememberedItemCount: Int { allManagedItems.count }

    var displayedItems: [ManagedMenuBarItem] {
        let source: [ManagedMenuBarItem]
        if let sectionFilter {
            source = items(in: sectionFilter)
        } else {
            source = allManagedItems
        }
        return filteredItems(source, query: searchText)
    }

    var selectedItem: ManagedMenuBarItem? {
        if let selectedItemID, let match = displayedItems.first(where: { $0.id == selectedItemID }) {
            return match
        }
        return displayedItems.first
    }

    var quickBarItems: [ManagedMenuBarItem] {
        filteredItems(allManagedItems, query: quickBarSearchText)
    }

    private var allManagedItems: [ManagedMenuBarItem] {
        // The live scanner is the only source of truth for visible order.
        // Keep that array intact so each section remains a faithful left-to-right
        // projection of the current macOS menu bar. Historical items that are not
        // present in this scan are deliberately appended as offline records and
        // never allowed to perturb the live order.
        let liveIDs = Set(liveItems.map(\.id))
        let live = liveItems.map { item in
            ManagedMenuBarItem(
                id: item.id,
                bundleIdentifier: item.bundleIdentifier,
                semanticIdentifier: item.semanticIdentifier,
                displayName: item.displayName,
                symbolName: item.symbolName,
                isRunning: true,
                liveItem: item
            )
        }

        let offline = store.document.knownItems.values
            .filter { !liveIDs.contains($0.id) }
            .map { known in
                // A policy may outlive the status item that created it. Keep
                // that record for the next time the item appears, but do not
                // infer current menu-bar presence from the owning process:
                // many apps keep a helper process alive without a status item.
                return ManagedMenuBarItem(
                    id: known.id,
                    bundleIdentifier: known.bundleIdentifier,
                    semanticIdentifier: known.semanticIdentifier,
                    displayName: known.displayName,
                    symbolName: known.symbolName,
                    isRunning: false,
                    liveItem: nil
                )
            }
            .sorted { lhs, rhs in
                let lhsSection = sectionSortIndex(store.section(for: lhs.id))
                let rhsSection = sectionSortIndex(store.section(for: rhs.id))
                if lhsSection != rhsSection { return lhsSection < rhsSection }
                let lhsOrder = store.policy(for: lhs.id).preferredOrder ?? Int.max
                let rhsOrder = store.policy(for: rhs.id).preferredOrder ?? Int.max
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                return lhs.localizedDisplayName.localizedStandardCompare(rhs.localizedDisplayName) == .orderedAscending
            }

        return live + offline
    }

    func items(in section: ItemSection) -> [ManagedMenuBarItem] {
        allManagedItems.filter {
            store.section(for: $0.id) == section

        }
    }

    private func sectionSortIndex(_ section: ItemSection) -> Int {
        ItemSection.allCases.firstIndex(of: section) ?? Int.max
    }

    func managedItem(id: String) -> ManagedMenuBarItem? {
        allManagedItems.first { $0.id == id }
    }

    func selectItem(_ id: String?) {
        selectedItemID = id
    }

    func setSectionFilter(_ section: ItemSection?) {
        sectionFilter = section
        selectedPage = .items
        searchText = ""
        ensureSelection()
    }

    func showAllItems() {
        sectionFilter = nil
        selectedPage = .items
        ensureSelection()
    }

    func ensureSelection() {
        if let selectedItemID, displayedItems.contains(where: { $0.id == selectedItemID }) {
            return
        }
        selectedItemID = displayedItems.first?.id
    }

    func start(openWindow: @escaping () -> Void) {
        self.openWindow = openWindow
        hasAccessibilityPermission = AccessibilityInventory.isTrusted()
        // The status item must be created under the final activation policy.
        // Creating it as an accessory app and switching to regular afterward
        // leaves macOS 27's MenuBarAgent with an off-screen AX slot (x=-1).
        store.applyAppearance()
        NSApp.setActivationPolicy(store.document.preferences.showInDock ? .regular : .accessory)
        let status = StatusBarController(
            model: self,
            onOpen: openWindow,
            onQuit: { NSApp.terminate(nil) }
        )
        statusBar = status
        let selectedBackend = MenuBarBackendFactory.make(
            legacySections: status.legacySections,
            onAssessmentApplied: { [weak status] in
                status?.reassertNativeItem()
            }
        )
        backend = selectedBackend
        backendName = selectedBackend.name
        capabilities = selectedBackend.capabilities
        selectedBackend.setExpanded(isExpanded)
        status.update(expanded: isExpanded)
        configureObservers()
        configureTimer()
        addActivity(.info, LF("Started with %@ backend", backendName))
        Diagnostics.shared.append(
            "runtime path=\(Bundle.main.bundlePath); accessibility=\(hasAccessibilityPermission)"
        )
        if !hasAccessibilityPermission { schedulePermissionChecks() }
        // Give AppKit one run-loop turn to place the native status item before
        // MenuBarAgent applies its assessment. Applying the assertion in the
        // same turn can capture the item while it still has the temporary
        // off-screen AX frame (x=-1).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.statusBar?.reassertNativeItem()
            self.refresh(reconcile: true, reason: .startup)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        permissionTimer?.invalidate()
        permissionTimer = nil
        backend?.stop()
        statusBar?.stop()
        statusBar = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    func refresh(reconcile: Bool = false, reason: ApplyReason = .guardian) {
        Task { @MainActor [weak self] in await self?.performRefresh(reconcile: reconcile, reason: reason) }
    }

    private func performRefresh(reconcile: Bool = false, reason: ApplyReason = .guardian) async {
        guard !isScanning, let backend else { return }
        if !reconcile { lastOperationMessage = L("Scanning menu bar") }
        isScanning = true
        let previousPermission = hasAccessibilityPermission
        hasAccessibilityPermission = AccessibilityInventory.isTrusted()
        if previousPermission != hasAccessibilityPermission {
            configureTimer()
            if !hasAccessibilityPermission { schedulePermissionChecks() }
        }
        let knownIDsBeforeScan = Set(store.document.knownItems.keys)
        var scanned = await backend.scan().filter { !$0.isProtected }
        // The app's own control is a normal native status item, but the
        // inventory intentionally excludes the managing process to avoid
        // feeding it back into visibility policy. Add this one UI record only
        // for the before/after display and click affordance.
        if let ownItem = statusBar?.toggleMenuBarItem {
            scanned.append(ownItem)
            scanned.sort { $0.frame.minX < $1.frame.minX }
        }
        liveItems = scanned
        let order = scanned.enumerated().map { index, item in
            "\(index):\(item.displayName)[\(item.bundleIdentifier)]@x=\(Int(item.frame.minX))"
        }.joined(separator: " | ")
        if !reconcile || order != lastLiveOrderSignature {
            Diagnostics.shared.append("live menu bar order: \(order)")
            lastLiveOrderSignature = order
        }
        store.remember(scanned)
        lastScanDate = .now
        isScanning = false
        if !reconcile {
            lastOperationMessage = LF("Found %d menu bar items", scanned.count)
        }
        let newlyDiscovered = scanned.filter {
            !$0.isProtected && !knownIDsBeforeScan.contains($0.id)
        }
        if !newlyDiscovered.isEmpty {
            let names = newlyDiscovered.prefix(3).map { $0.displayName }.joined(separator: ", ")
            let suffix = newlyDiscovered.count > 3 ? "…" : ""
            addActivity(.info, LF("New menu bar items discovered: %@%@", names, suffix))
        }
        if lastReportedScanCount != scanned.count || !isGuardianReason(reason) {
            addActivity(.info, LF("Found %d menu bar items", scanned.count))
            lastReportedScanCount = scanned.count
        }
        statusBar?.update(expanded: isExpanded)

        guard reconcile, canManage, store.document.preferences.guardianEnabled else { return }
        if capabilities.kind == .menuBarAgent {
            apply(reason: reason)
        } else {
            let observations = scanned.compactMap { item -> ReconciliationObservation? in
                guard let actual = item.actualSection else { return nil }
                let policy = store.policy(for: item.id)
                return .init(
                    itemID: item.id,
                    desired: policy.section,
                    actual: actual,
                    guardsAgainstDrift: policy.guardsAgainstDrift
                )
            }
            if let intent = driftTracker.observe(observations).first {
                apply(reason: .user(itemID: intent.itemID))
            }
        }
    }

    func activateItem(_ item: ManagedMenuBarItem) {
        if item.id == StatusBarController.toggleID { openWindow?(); return }
        guard let live = item.liveItem else {
            lastOperationMessage = L("Not detected in the latest scan")
            return
        }
        statusBar?.hideQuickBar()
        if !AccessibilityInventory.activate(live) {
            lastOperationMessage = L("Unable to open this menu; try expanding hidden items")
        }
    }

    func rescan() {
        guard !isScanning else { return }
        refresh(reconcile: false)
    }

    func applyCurrentLayout() {
        guard canManage else {
            lastOperationMessage = L("Accessibility permission is required")
            addActivity(.warning, L("Accessibility permission is required"))
            return
        }
        guard !isScanning else { return }
        lastOperationMessage = L("Applying menu bar layout")
        // Refresh first so a newly launched status item is included, then
        // apply the saved policy even when the background guardian is off.
        Task { @MainActor in
            await performRefresh(reconcile: false)
            apply(reason: .startup)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.refresh(reconcile: false)

        }
    }

    func moveItem(id: String, to section: ItemSection) {
        guard canManage else {
            lastOperationMessage = L("Accessibility permission is required")
            addActivity(.warning, L("Accessibility permission is required"))
            return
        }
        guard let item = managedItem(id: id) else { return }
        if item.liveItem?.isProtected == true || id == StatusBarController.toggleID {
            store.setSection(section, for: id)
            statusBar?.update(expanded: isExpanded)
            lastOperationMessage = L("Menu bar policy applied")
            return
        }
        var orderedIDs = Dictionary(uniqueKeysWithValues: ItemSection.allCases.map { ($0, [String]()) })
        for item in allManagedItems where item.id != id {
            orderedIDs[store.section(for: item.id), default: []].append(item.id)
        }
        orderedIDs[section, default: []].append(id)
        store.setLayout(orderedIDs)
        apply(reason: .user(itemID: id))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refresh(reconcile: false)
        }
    }

    func toggleExpanded() {
        guard canManage else {
            lastOperationMessage = L("Accessibility permission is required")
            return
        }
        store.setExpanded(!isExpanded)
        backend?.setExpanded(isExpanded)
        statusBar?.update(expanded: isExpanded)
        apply(reason: .expansion)
        addActivity(.success, isExpanded ? L("Hidden items expanded") : L("Hidden items collapsed"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refresh(reconcile: false)
        }
    }

    func requestAccessibilityPermission() {
        _ = AccessibilityInventory.isTrusted(prompt: true)
        schedulePermissionChecks()
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    func recheckAccessibilityPermission() {
        hasAccessibilityPermission = AccessibilityInventory.isTrusted()
        configureTimer()
        if hasAccessibilityPermission {
            permissionTimer?.invalidate()
            permissionTimer = nil
            refresh(reconcile: true, reason: .startup)
        } else {
            schedulePermissionChecks()
        }
    }

    func prepareAIPlacement() {
        guard !isAIPlacementLoading else { return }
        // Only currently running items participate in a fresh AI reset. Closed
        // historical records keep their saved policy until they appear again.
        let items = allManagedItems.filter { $0.isRunning && $0.liveItem?.isProtected != true }
        guard !items.isEmpty else {
            lastOperationMessage = L("No menu bar items to arrange")
            return
        }
        isAIPlacementLoading = true
        aiPlacementNote = nil
        lastOperationMessage = L("AI is analyzing your Mac and menu bar")
        selectedPage = .items
        openWindow?()

        Task { [weak self] in
            guard let self else { return }
            // Preserve actual sections in the Before preview.
            let resetSectionForID: (String) -> ItemSection = { self.store.section(for: $0) }
            do {
                let result = try await AIPlacementClient.request(
                    items: items,
                    provider: self.store.document.preferences.aiProvider,
                    model: self.store.document.preferences.aiModel,
                    baseURL: self.store.document.preferences.aiBaseURL,
                    sectionForID: resetSectionForID
                )
                self.aiProposal = result.proposal
                self.aiPlacementNote = [result.title, result.summary]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                self.lastOperationMessage = L("AI placement proposal ready")
                self.addActivity(.info, L("AI placement proposal ready"))
            } catch {
                let mainDisplay = DeviceProfile.current.displays.first(where: \.isMain)
                let capacity = Self.visibleCapacity(for: mainDisplay?.menuBarRightWidthPoints ?? 480)
                let fallback = AIPlacementEngine.proposal(
                    for: items.map {
                        AIPlacementItem(
                            id: $0.id,
                            name: $0.displayName,
                            bundleIdentifier: $0.bundleIdentifier,
                            currentSection: self.store.section(for: $0.id)
                        )
                    },
                    maxShownItems: capacity
                )
                self.aiProposal = fallback
                if let placementError = error as? AIPlacementError,
                   case .missingAPIKey = placementError {
                    self.aiPlacementNote = L("No API key yet. This preview was generated on-device; add your DeepSeek key in Settings > AI.")
                } else {
                    self.aiPlacementNote = L("AI service is unavailable. Review this private on-device fallback plan.")
                }
                self.lastOperationMessage = error.localizedDescription
                self.addActivity(.warning, LF("AI fallback used: %@", error.localizedDescription))
            }
            self.isAIPlacementLoading = false
        }
    }

    func applyAIPlacement() {
        guard let proposal = aiProposal else { return }
        guard canManage else {
            lastOperationMessage = L("Accessibility permission is required")
            return
        }
        store.applyAIPlacement(proposal.decisions)
        apply(reason: .aiPlacement)
        aiProposal = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.refresh(reconcile: false)
        }
    }

    func cancelAIPlacement() {
        aiProposal = nil
        aiPlacementNote = nil
    }

    private static func visibleCapacity(for width: CGFloat) -> Int {
        switch width {
        case ..<380: 5
        case ..<560: 7
        default: 9
        }
    }

    func setGuardianEnabled(_ enabled: Bool) {
        store.setGuardianEnabled(enabled)
        driftTracker.reset()
        lastGuardianSignature = nil
        configureTimer()
        if enabled {
            refresh(reconcile: true, reason: .startup)
        } else {
            backend?.stop()
            refresh(reconcile: false)
        }
    }

    func setLanguage(_ language: AppLanguage) { store.setLanguage(language) }
    func setAppearance(_ appearance: AppearancePreference) { store.setAppearance(appearance) }
    func setShowInDock(_ enabled: Bool) { store.setShowInDock(enabled) }
    func setAIProvider(_ provider: AIProvider) { store.setAIProvider(provider) }
    func setAIModel(_ model: String) { store.setAIModel(model) }
    func setAIBaseURL(_ baseURL: String) { store.setAIBaseURL(baseURL) }

    @discardableResult
    func saveAIAPIKey(_ value: String) -> Bool {
        do {
            try AIConfigurationStore.saveAPIKey(value)
            hasAIAPIKey = true
            lastOperationMessage = L("DeepSeek API key saved securely")
            addActivity(.success, L("DeepSeek API key saved securely"))
            return true
        } catch {
            lastOperationMessage = error.localizedDescription
            addActivity(.error, error.localizedDescription)
            return false
        }
    }

    func clearAIAPIKey() {
        do {
            try AIConfigurationStore.clearAPIKey()
            hasAIAPIKey = false
            lastOperationMessage = L("DeepSeek API key removed")
            addActivity(.info, L("DeepSeek API key removed"))
        } catch {
            lastOperationMessage = error.localizedDescription
            addActivity(.error, error.localizedDescription)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try store.setLaunchAtLogin(enabled)
            addActivity(.success, enabled ? L("Launch at login enabled") : L("Launch at login disabled"))
        } catch {
            addActivity(.error, error.localizedDescription)
        }
    }

    func revealPolicyFile() {
        NSWorkspace.shared.activateFileViewerSelecting([store.exportURL()])
    }

    func exportDiagnostics() {
        let summary = "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
            + "Backend: \(backendName)\nAccessibility: \(hasAccessibilityPermission)\n"
            + "Live items: \(liveItems.count)\nKnown items: \(store.document.knownItems.count)"
        if Diagnostics.shared.export(summary: summary) != nil {
            addActivity(.success, L("Diagnostics exported"))
        }
    }

    private func apply(reason: ApplyReason) {
        guard let backend, canManage else {
            lastOperationMessage = L("Accessibility permission is required")
            return
        }
        if case .guardian = reason {
            let signature = guardianSignature()
            guard signature != lastGuardianSignature else { return }

        }
        applyGeneration += 1
        let generation = applyGeneration
        let signature = guardianSignature()
        Task { @MainActor [weak self] in
        guard let self else { return }
        let result = await backend.apply(
            document: store.document,
            liveItems: liveItems,
            reason: reason
        )
        guard generation == self.applyGeneration else { return }
        if result.accepted { self.lastGuardianSignature = signature }
        else { self.lastGuardianSignature = nil }
        // Reassert OPEN BAR's own status item immediately after every backend
        // visibility operation. It must never be swallowed by an AI plan.
        statusBar?.update(expanded: isExpanded)
        for delay in [0.05, 0.25, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.statusBar?.reassertNativeItem()
            }
        }
        lastOperationMessage = result.message
        addActivity(result.accepted ? .success : .warning, result.message)
        Diagnostics.shared.append("apply accepted=\(result.accepted); message=\(result.message)")
        }
    }

    private func filteredItems(
        _ items: [ManagedMenuBarItem],
        query: String
    ) -> [ManagedMenuBarItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.localizedDisplayName.localizedCaseInsensitiveContains(query)
                || $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    private func configureTimer() {
        timer?.invalidate()
        timer = nil
        // Discovery stays active even when the guardian is disabled. A newly
        // launched app must still appear in the workspace; the preference only
        // controls whether drift repair is performed after the scan.
        guard canManage else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(reconcile: true) }
        }
    }

    private func schedulePermissionChecks() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else {
                    timer.invalidate()
                    return
                }
                guard AccessibilityInventory.isTrusted() else { return }
                timer.invalidate()
                self.permissionTimer = nil
                self.hasAccessibilityPermission = true
                self.configureTimer()
                self.addActivity(.success, L("Accessibility permission granted"))
                self.refresh(reconcile: true, reason: .startup)
            }
        }
    }

    private func configureObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.lastGuardianSignature = nil
                    self?.refresh(reconcile: self?.store.document.preferences.guardianEnabled ?? false)
                    for delay in [1.0, 3.0, 8.0] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            self?.refresh(reconcile: true)
                        }
                    }
                }
            })
        }
    }

    private func addActivity(_ level: ActivityEntry.Level, _ message: String) {
        activity.insert(.init(level: level, message: message), at: 0)
        activity = Array(activity.prefix(80))
        Diagnostics.shared.append(message)
    }

    private func guardianSignature() -> String {
        let known = store.document.knownItems.keys.sorted().map { id in
            "\(id)=\(store.section(for: id).rawValue)"
        }
        let live = liveItems.filter { !$0.isProtected }.map { item in
            "\(item.id)=\(store.section(for: item.id).rawValue)"
        }.sorted()
        return [isExpanded ? "expanded" : "collapsed", known.joined(separator: ","), live.joined(separator: ",")]
            .joined(separator: "|")
    }

    private func isGuardianReason(_ reason: ApplyReason) -> Bool {
        if case .guardian = reason { return true }
        return false
    }
}
