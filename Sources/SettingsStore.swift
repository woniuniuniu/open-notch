import AppKit
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Key {
        static let policies = "itemPolicies.v1"
        static let knownItems = "knownItems.v1"
        static let windowBindings = "windowBindings.v1"
        static let guardianEnabled = "oneDriveGuardianEnabled"
        static let monitorEnabled = "continuousMonitorEnabled"
        static let expanded = "hiddenSectionExpanded"
        static let repairCount = "oneDriveRepairCount"
        static let language = Localization.languageDefaultsKey
        static let appearance = "appearanceMode"
    }

    @Published var policies: [String: ItemDisposition] {
        didSet { persistPolicies() }
    }

    @Published var knownItems: [String: KnownMenuBarItem] {
        didSet { persistKnownItems() }
    }

    private(set) var windowBindings: [String: PersistedWindowBinding] {
        didSet { persistWindowBindings() }
    }

    @Published var oneDriveGuardianEnabled: Bool {
        didSet { defaults.set(oneDriveGuardianEnabled, forKey: Key.guardianEnabled) }
    }

    @Published var continuousMonitorEnabled: Bool {
        didSet { defaults.set(continuousMonitorEnabled, forKey: Key.monitorEnabled) }
    }

    @Published var isExpanded: Bool {
        didSet { defaults.set(isExpanded, forKey: Key.expanded) }
    }

    @Published var repairCount: Int {
        didSet { defaults.set(repairCount, forKey: Key.repairCount) }
    }

    @Published var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: Key.language) }
    }

    @Published var appearanceMode: AppearanceMode {
        didSet { defaults.set(appearanceMode.rawValue, forKey: Key.appearance) }
    }

    private let defaults = UserDefaults.standard

    private init() {
        if
            let data = defaults.data(forKey: Key.policies),
            let decoded = try? JSONDecoder().decode([String: ItemDisposition].self, from: data)
        {
            policies = decoded.filter { !Self.isAnonymousStableID($0.key) }
        } else {
            policies = [:]
        }

        if
            let data = defaults.data(forKey: Key.knownItems),
            let decoded = try? JSONDecoder().decode([String: KnownMenuBarItem].self, from: data)
        {
            knownItems = decoded.filter { !Self.isAnonymousStableID($0.key) }
        } else {
            knownItems = [:]
        }

        if
            let data = defaults.data(forKey: Key.windowBindings),
            let decoded = try? JSONDecoder().decode([String: PersistedWindowBinding].self, from: data)
        {
            windowBindings = decoded.filter { Self.isUsableBinding($0.value) }
        } else {
            windowBindings = [:]
        }

        oneDriveGuardianEnabled = defaults.object(forKey: Key.guardianEnabled) as? Bool ?? true
        continuousMonitorEnabled = defaults.object(forKey: Key.monitorEnabled) as? Bool ?? true
        isExpanded = defaults.object(forKey: Key.expanded) as? Bool ?? true
        repairCount = defaults.integer(forKey: Key.repairCount)
        language = AppLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .english
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .light

        // Persist the sanitized values so invalid identities from pre-0.1.3
        // builds cannot return on the next launch.
        persistPolicies()
        persistKnownItems()
        persistWindowBindings()
    }

    func disposition(for item: MenuBarItem) -> ItemDisposition {
        if item.isOneDrive, oneDriveGuardianEnabled {
            return .visible
        }
        return policies[item.id] ?? .visible
    }

    func setDisposition(_ disposition: ItemDisposition, for id: String) {
        policies[id] = disposition
    }

    func applyAppearance() {
        NSApp.appearance = NSAppearance(named: appearanceMode.appearanceName)
    }

    func remember(_ items: [MenuBarItem]) {
        var updated = knownItems
        var updatedBindings = windowBindings
        for item in items where
            !item.isProtected
            && !item.isAnonymousControlCenterItem
            && !item.hasUnknownHostIdentity
        {
            updated[item.id] = KnownMenuBarItem(
                id: item.id,
                displayName: item.displayName,
                detail: item.detail,
                symbolName: item.symbolName,
                semanticBundleIdentifier: item.semanticBundleIdentifier,
                lastSeen: .now
            )
            updatedBindings = updatedBindings.filter {
                $0.value.stableID != item.id || $0.key == String(item.windowID)
            }
            updatedBindings[String(item.windowID)] = PersistedWindowBinding(
                stableID: item.id,
                displayName: item.displayName,
                symbolName: item.symbolName,
                semanticBundleIdentifier: item.semanticBundleIdentifier,
                semanticIdentifier: item.semanticIdentifier,
                rawTitle: item.rawTitle,
                isProtected: item.isProtected
            )
        }
        knownItems = updated
        windowBindings = updatedBindings
    }

    func restoredItems(from windows: [RawStatusWindow]) -> [MenuBarItem] {
        windows.compactMap { window in
            guard let binding = windowBindings[String(window.windowID)] else { return nil }
            return MenuBarItem(
                id: binding.stableID,
                windowID: window.windowID,
                hostPID: window.hostPID,
                hostBundleIdentifier: window.hostBundleIdentifier,
                semanticBundleIdentifier: binding.semanticBundleIdentifier,
                semanticIdentifier: binding.semanticIdentifier,
                rawTitle: binding.rawTitle,
                displayName: binding.displayName,
                symbolName: binding.symbolName,
                frame: window.frame,
                isProtected: binding.isProtected
            )
        }
    }

    private func persistPolicies() {
        guard let data = try? JSONEncoder().encode(policies) else { return }
        defaults.set(data, forKey: Key.policies)
    }

    private func persistKnownItems() {
        guard let data = try? JSONEncoder().encode(knownItems) else { return }
        defaults.set(data, forKey: Key.knownItems)
    }

    private func persistWindowBindings() {
        guard let data = try? JSONEncoder().encode(windowBindings) else { return }
        defaults.set(data, forKey: Key.windowBindings)
    }

    private static func isAnonymousStableID(_ stableID: String) -> Bool {
        stableID.hasPrefix("host:com.apple.controlcenter:")
            || stableID.hasPrefix("app:unknown.")
    }

    private static func isUsableBinding(_ binding: PersistedWindowBinding) -> Bool {
        !isAnonymousStableID(binding.stableID)
            && !(binding.semanticBundleIdentifier == "com.apple.controlcenter" && binding.semanticIdentifier.isEmpty)
            && !binding.semanticBundleIdentifier.hasPrefix("unknown.")
            && binding.displayName != "未识别的菜单栏图标"
            && binding.displayName != "Unrecognized menu bar item"
    }
}
