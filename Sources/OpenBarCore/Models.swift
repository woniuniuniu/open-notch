import Foundation

public enum ItemSection: String, CaseIterable, Codable, Identifiable, Sendable {
    case shown
    case hidden
    case alwaysHidden

    public var id: String { rawValue }
}

public struct ItemIdentity: Codable, Hashable, Sendable {
    public let stableID: String
    public let bundleIdentifier: String
    public let semanticIdentifier: String

    public init(stableID: String, bundleIdentifier: String, semanticIdentifier: String) {
        self.stableID = stableID
        self.bundleIdentifier = bundleIdentifier
        self.semanticIdentifier = semanticIdentifier
    }
}

public struct KnownItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var bundleIdentifier: String
    public var semanticIdentifier: String
    public var displayName: String
    public var symbolName: String
    public var lastSeen: Date

    public init(
        id: String,
        bundleIdentifier: String,
        semanticIdentifier: String,
        displayName: String,
        symbolName: String,
        lastSeen: Date
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.semanticIdentifier = semanticIdentifier
        self.displayName = displayName
        self.symbolName = symbolName
        self.lastSeen = lastSeen
    }
}

public struct ItemPolicy: Codable, Equatable, Sendable {
    public var section: ItemSection
    public var guardsAgainstDrift: Bool
    public var preferredOrder: Int?

    public init(
        section: ItemSection = .shown,
        guardsAgainstDrift: Bool = true,
        preferredOrder: Int? = nil
    ) {
        self.section = section
        self.guardsAgainstDrift = guardsAgainstDrift
        self.preferredOrder = preferredOrder
    }
}

public enum AppLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case english
    case simplifiedChinese

    public var id: String { rawValue }
}

public enum AppearancePreference: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }
}

public enum AIProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case deepSeek

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .deepSeek: "DeepSeek"
        }
    }
}

public struct OpenBarPreferences: Codable, Equatable, Sendable {
    public var language: AppLanguage
    public var appearance: AppearancePreference
    public var launchAtLogin: Bool
    public var showInDock: Bool
    public var guardianEnabled: Bool
    public var hiddenSectionExpanded: Bool
    public var aiProvider: AIProvider
    public var aiModel: String
    public var aiBaseURL: String

    public init(
        language: AppLanguage = .system,
        appearance: AppearancePreference = .system,
        launchAtLogin: Bool = false,
        showInDock: Bool = false,
        guardianEnabled: Bool = true,
        hiddenSectionExpanded: Bool = false,
        aiProvider: AIProvider = .deepSeek,
        aiModel: String = "deepseek-chat",
        aiBaseURL: String = "https://api.deepseek.com"
    ) {
        self.language = language
        self.appearance = appearance
        self.launchAtLogin = launchAtLogin
        self.showInDock = showInDock
        self.guardianEnabled = guardianEnabled
        self.hiddenSectionExpanded = hiddenSectionExpanded
        self.aiProvider = aiProvider
        self.aiModel = aiModel
        self.aiBaseURL = aiBaseURL
    }

    private enum CodingKeys: String, CodingKey {
        case language, appearance, launchAtLogin, showInDock, guardianEnabled, hiddenSectionExpanded
        case aiProvider, aiModel, aiBaseURL
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            language: try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system,
            appearance: try container.decodeIfPresent(AppearancePreference.self, forKey: .appearance) ?? .system,
            launchAtLogin: try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false,
            showInDock: try container.decodeIfPresent(Bool.self, forKey: .showInDock) ?? false,
            guardianEnabled: try container.decodeIfPresent(Bool.self, forKey: .guardianEnabled) ?? true,
            hiddenSectionExpanded: try container.decodeIfPresent(Bool.self, forKey: .hiddenSectionExpanded) ?? false,
            aiProvider: try container.decodeIfPresent(AIProvider.self, forKey: .aiProvider) ?? .deepSeek,
            aiModel: try container.decodeIfPresent(String.self, forKey: .aiModel) ?? "deepseek-chat",
            aiBaseURL: try container.decodeIfPresent(String.self, forKey: .aiBaseURL) ?? "https://api.deepseek.com"
        )
    }
}

public struct PolicyDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var policies: [String: ItemPolicy]
    public var knownItems: [String: KnownItem]
    public var preferences: OpenBarPreferences
    public var savedAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        policies: [String: ItemPolicy] = [:],
        knownItems: [String: KnownItem] = [:],
        preferences: OpenBarPreferences = .init(),
        savedAt: Date = .now
    ) {
        self.schemaVersion = schemaVersion
        self.policies = policies
        self.knownItems = knownItems
        self.preferences = preferences
        self.savedAt = savedAt
    }

    public mutating func sanitize() {
        policies = policies.filter { !$0.key.isEmpty }
        knownItems = knownItems.filter { id, item in
            !id.isEmpty && !item.bundleIdentifier.isEmpty
        }
        // Per-item drift protection is intentionally always on. The user-facing
        // control is the single global guardian switch; legacy files that stored
        // a disabled item-level flag are upgraded to the strong default here.
        for id in policies.keys {
            policies[id]?.guardsAgainstDrift = true
        }
        if preferences.aiModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            preferences.aiModel = "deepseek-chat"
        }
        if preferences.aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            preferences.aiBaseURL = "https://api.deepseek.com"
        }
        schemaVersion = Self.currentSchemaVersion
    }
}

public enum BackendKind: String, Codable, Sendable {
    case legacy
    case menuBarAgent
}

public struct BackendCapabilities: Equatable, Sendable {
    public let kind: BackendKind
    public let canInspectItems: Bool
    public let supportsThreeSections: Bool
    public let supportsNativeReorder: Bool
    public let changesArePerApplication: Bool

    public init(
        kind: BackendKind,
        canInspectItems: Bool,
        supportsThreeSections: Bool,
        supportsNativeReorder: Bool,
        changesArePerApplication: Bool
    ) {
        self.kind = kind
        self.canInspectItems = canInspectItems
        self.supportsThreeSections = supportsThreeSections
        self.supportsNativeReorder = supportsNativeReorder
        self.changesArePerApplication = changesArePerApplication
    }
}

public struct ActivityEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let level: Level
    public let message: String

    public enum Level: String, Sendable {
        case info
        case success
        case warning
        case error
    }

    public init(id: UUID = UUID(), date: Date = .now, level: Level, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.message = message
    }
}
