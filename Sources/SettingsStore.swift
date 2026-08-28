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
        static let showInDock = "showInDock"
        static let aiInstallationID = "aiInstallationID.v1"
        static let aiLastRecommendationDate = "aiLastRecommendationDate.v1"
        static let aiRecommendationDates = "aiRecommendationDates.v1"
        static let aiItemDescriptions = "aiItemDescriptions.v1"
        static let hiddenItemPositions = "hiddenItemPositions.v1"
        static let restoredSystemItemVisibility = "restoredSystemItemVisibility.v2"
        static let externalDisplayMode = "externalDisplayMode.v1"
        static let restoredWeatherVisibility = "restoredWeatherVisibility.v1"
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

    @Published var showInDock: Bool {
        didSet { defaults.set(showInDock, forKey: Key.showInDock) }
    }

    @Published var externalDisplayMode: ExternalDisplayMode {
        didSet { defaults.set(externalDisplayMode.rawValue, forKey: Key.externalDisplayMode) }
    }

    let aiInstallationID: String

    @Published private(set) var aiRecommendationDates: [Date] {
        didSet {
            guard let data = try? JSONEncoder().encode(aiRecommendationDates) else { return }
            defaults.set(data, forKey: Key.aiRecommendationDates)
        }
    }

    @Published private(set) var aiItemDescriptions: [String: [String: String]] {
        didSet { persistAIItemDescriptions() }
    }

    private var hiddenItemPositions: [String: Double] = [:] {
        didSet { defaults.set(hiddenItemPositions, forKey: Key.hiddenItemPositions) }
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
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        showInDock = defaults.object(forKey: Key.showInDock) as? Bool ?? false
        externalDisplayMode = ExternalDisplayMode(
            rawValue: defaults.string(forKey: Key.externalDisplayMode) ?? ""
        ) ?? .sameLayout
        if let storedID = defaults.string(forKey: Key.aiInstallationID), !storedID.isEmpty {
            aiInstallationID = storedID
        } else {
            let generatedID = UUID().uuidString.lowercased()
            aiInstallationID = generatedID
            defaults.set(generatedID, forKey: Key.aiInstallationID)
        }
        if
            let data = defaults.data(forKey: Key.aiRecommendationDates),
            let decoded = try? JSONDecoder().decode([Date].self, from: data)
        {
            aiRecommendationDates = decoded
        } else if let legacyDate = defaults.object(forKey: Key.aiLastRecommendationDate) as? Date {
            aiRecommendationDates = [legacyDate]
        } else {
            aiRecommendationDates = []
        }
        if
            let data = defaults.data(forKey: Key.aiItemDescriptions),
            let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        {
            aiItemDescriptions = decoded
        } else {
            aiItemDescriptions = [:]
        }
        hiddenItemPositions = defaults.dictionary(forKey: Key.hiddenItemPositions)?.compactMapValues {
            ($0 as? NSNumber)?.doubleValue
        } ?? [:]

        // One experimental build accidentally treated every Apple-owned item
        // as hidden and then made it read-only. Restore those items once, but
        // keep them manageable so later choices remain entirely user-driven.
        if !defaults.bool(forKey: Key.restoredSystemItemVisibility) {
            policies = policies.filter { id, _ in
                !Self.isSystemStableID(id, knownItems: knownItems)
            }
            if let controlCenter = UserDefaults(suiteName: "com.apple.controlcenter") {
                for item in ["Battery", "WiFi", "Sound", "BentoBox", "BentoBox-0", "Clock"] {
                    controlCenter.set(true, forKey: "NSStatusItem Visible \(item)")
                    controlCenter.set(true, forKey: "NSStatusItem VisibleCC \(item)")
                }
                _ = controlCenter.synchronize()
            }
            defaults.set(true, forKey: Key.restoredSystemItemVisibility)
        }

        // Weather is a newer system menu-bar control and was omitted by the
        // original macOS 27 assessment allow-list. Restore the user's system
        // checkbox once; subsequent choices remain user-controlled.
        if !defaults.bool(forKey: Key.restoredWeatherVisibility) {
            CFPreferencesSetValue(
                "Weather" as CFString,
                NSNumber(value: 8),
                "com.apple.controlcenter" as CFString,
                kCFPreferencesCurrentUser,
                kCFPreferencesCurrentHost
            )
            _ = CFPreferencesSynchronize(
                "com.apple.controlcenter" as CFString,
                kCFPreferencesCurrentUser,
                kCFPreferencesCurrentHost
            )
            defaults.set(true, forKey: Key.restoredWeatherVisibility)
        }

        // Persist the sanitized values so invalid identities from pre-0.1.3
        // builds cannot return on the next launch.
        persistPolicies()
        persistKnownItems()
        persistWindowBindings()
    }

    func disposition(for item: MenuBarItem) -> ItemDisposition {
        if item.isOpenNotchControl {
            return .visible
        }
        if item.isOneDrive, oneDriveGuardianEnabled {
            return .visible
        }
        return policies[item.id] ?? .visible
    }

    func setDisposition(_ disposition: ItemDisposition, for id: String) {
        policies[id] = disposition
    }

    func rememberPosition(_ position: Double, for id: String) {
        hiddenItemPositions[id] = position
    }

    func rememberedPosition(for id: String) -> Double? {
        hiddenItemPositions[id]
    }

    func aiDescription(for id: String, language: AppLanguage) -> String? {
        aiItemDescriptions[language.rawValue]?[id]
    }

    func setAIDescriptions(_ descriptions: [String: String], language: AppLanguage) {
        guard !descriptions.isEmpty else { return }
        var localizedDescriptions = aiItemDescriptions[language.rawValue] ?? [:]
        localizedDescriptions.merge(descriptions) { _, new in new }
        aiItemDescriptions[language.rawValue] = localizedDescriptions
    }

    func recordAIRecommendation(at date: Date = .now) {
        aiRecommendationDates = aiRecommendationDates.filter {
            Calendar.current.isDate($0, inSameDayAs: date)
        } + [date]
    }

    func applyAppearance() {
        NSApp.appearance = appearanceMode.appearance
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
                // Old builds persisted Clock and Control Center as protected.
                // Recompute this instead of reviving that obsolete restriction.
                isProtected: binding.semanticBundleIdentifier == Bundle.main.bundleIdentifier
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

    private func persistAIItemDescriptions() {
        guard let data = try? JSONEncoder().encode(aiItemDescriptions) else { return }
        defaults.set(data, forKey: Key.aiItemDescriptions)
    }

    private static func isAnonymousStableID(_ stableID: String) -> Bool {
        stableID.hasPrefix("host:com.apple.controlcenter:")
            || stableID.hasPrefix("app:unknown.")
    }

    private static func isSystemStableID(
        _ stableID: String,
        knownItems: [String: KnownMenuBarItem]
    ) -> Bool {
        stableID.hasPrefix("agent:status:com.apple.")
            || stableID.hasPrefix("agent:module:")
            || knownItems[stableID]?.semanticBundleIdentifier.hasPrefix("com.apple.") == true
    }

    private static func isUsableBinding(_ binding: PersistedWindowBinding) -> Bool {
        !isAnonymousStableID(binding.stableID)
            && !(binding.semanticBundleIdentifier == "com.apple.controlcenter" && binding.semanticIdentifier.isEmpty)
            && !binding.semanticBundleIdentifier.hasPrefix("unknown.")
            && binding.displayName != "未识别的菜单栏图标"
            && binding.displayName != "Unrecognized menu bar item"
    }
}
