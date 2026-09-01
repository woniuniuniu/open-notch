import AppKit
import Combine
import Foundation
import OpenBarCore
import ServiceManagement

@MainActor
final class PolicyStore: ObservableObject {
    static let shared = PolicyStore()

    @Published private(set) var document: PolicyDocument
    @Published private(set) var persistenceError: String?

    private let fileURL: URL
    private let encoder: JSONEncoder

    private init() {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Open Bar", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("policies.json")

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           var decoded = try? decoder.decode(PolicyDocument.self, from: data) {
            decoded.sanitize()
            document = decoded
        } else {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let suffix = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
                try? FileManager.default.moveItem(
                    at: fileURL,
                    to: directory.appendingPathComponent("policies.corrupt.\(suffix).json")
                )
            }
            document = PolicyDocument()
        }
        let invalidIDs = document.knownItems.keys.filter {
            $0.hasPrefix("module:StatusModule-")
                || $0 == "bundle:com.woniuniuniu.OpenBar.StatusHost"
        }
        if !invalidIDs.isEmpty {
            for id in invalidIDs {
                document.knownItems.removeValue(forKey: id)
                document.policies.removeValue(forKey: id)
            }
            if let data = try? encoder.encode(document) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
        migrateLegacyModuleAliases()
        UserDefaults.standard.set(document.preferences.language.rawValue, forKey: "OpenBar.Language")
    }

    private func migrateLegacyModuleAliases() {
        let legacyID = "module:BentoBox-0"
        let canonicalID = "module:BentoBox"
        guard let legacy = document.knownItems.removeValue(forKey: legacyID) else { return }

        if document.knownItems[canonicalID] == nil {
            document.knownItems[canonicalID] = KnownItem(
                id: canonicalID,
                bundleIdentifier: legacy.bundleIdentifier,
                semanticIdentifier: canonicalID,
                displayName: legacy.displayName,
                symbolName: legacy.symbolName,
                lastSeen: legacy.lastSeen
            )
        }
        if document.policies[canonicalID] == nil,
           let legacyPolicy = document.policies[legacyID] {
            document.policies[canonicalID] = legacyPolicy
        }
        document.policies.removeValue(forKey: legacyID)
        if let data = try? encoder.encode(document) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func policy(for id: String) -> ItemPolicy {
        document.policies[id] ?? ItemPolicy()
    }

    func section(for id: String) -> ItemSection {
        policy(for: id).section
    }

    func setSection(_ section: ItemSection, for id: String) {
        var policy = policy(for: id)
        policy.section = section
        policy.guardsAgainstDrift = true
        document.policies[id] = policy
        persist()
    }

    func setLayout(_ orderedIDs: [ItemSection: [String]]) {
        for section in ItemSection.allCases {
            for (index, id) in (orderedIDs[section] ?? []).enumerated() {
                var policy = policy(for: id)
                policy.section = section
                policy.preferredOrder = index
                policy.guardsAgainstDrift = true
                document.policies[id] = policy
            }
        }
        persist()
    }

    func applyAIPlacement(_ decisions: [AIPlacementDecision]) {
        for decision in decisions {
            var policy = policy(for: decision.itemID)
            policy.section = decision.proposedSection
            // AI changes visibility only. Horizontal order remains the live
            // macOS order because macOS 26/27 does not expose a reliable API
            // for third-party status-item reordering.
            policy.preferredOrder = decision.currentOrder
            policy.guardsAgainstDrift = true
            document.policies[decision.itemID] = policy
        }
        persist()
    }

    func remember(_ items: [LiveMenuBarItem]) {
        let now = Date.now
        var changed = false
        // On macOS 26/27 there is no reliable cross-app writable ordering API.
        // Treat the observed system order as the source of truth instead of
        // preserving a stale drag order from an older build.
        var observedOrder: [ItemSection: [String]] = [:]
        for item in items where !item.isProtected {
            if item.id.hasPrefix("bundle:") {
                let obsoleteIDs = document.knownItems.values
                    .filter { $0.bundleIdentifier == item.bundleIdentifier && $0.id != item.id }
                    .sorted { $0.lastSeen > $1.lastSeen }
                    .map(\.id)
                if !obsoleteIDs.isEmpty {
                    if document.policies[item.id] == nil {
                        document.policies[item.id] = obsoleteIDs.lazy
                            .compactMap { self.document.policies[$0] }
                            .first
                    }
                    for obsoleteID in obsoleteIDs {
                        document.knownItems.removeValue(forKey: obsoleteID)
                        document.policies.removeValue(forKey: obsoleteID)
                    }
                    changed = true
                }
            }

            let currentSection = policy(for: item.id).section
            observedOrder[currentSection, default: []].append(item.id)

            var known = item.knownItem
            known.lastSeen = now
            let previous = document.knownItems[item.id]
            let identityChanged = previous.map {
                $0.bundleIdentifier != known.bundleIdentifier
                    || $0.semanticIdentifier != known.semanticIdentifier
                    || $0.displayName != known.displayName
                    || $0.symbolName != known.symbolName
            } ?? true
            let observationIsStale = previous.map { now.timeIntervalSince($0.lastSeen) >= 300 } ?? true
            if identityChanged || observationIsStale {
                document.knownItems[item.id] = known
                changed = true
            }
        }

        for section in ItemSection.allCases {
            for (index, id) in observedOrder[section, default: []].enumerated() {
                var policy = policy(for: id)
                if policy.preferredOrder != index {
                    policy.preferredOrder = index
                    document.policies[id] = policy
                    changed = true
                }
            }
        }
        if changed { persist() }
    }

    func setLanguage(_ language: AppLanguage) {
        document.preferences.language = language
        UserDefaults.standard.set(language.rawValue, forKey: "OpenBar.Language")
        persist()
    }

    func setAppearance(_ appearance: AppearancePreference) {
        document.preferences.appearance = appearance
        applyAppearance()
        persist()
    }

    func setShowInDock(_ enabled: Bool) {
        document.preferences.showInDock = enabled
        NSApp.setActivationPolicy(enabled ? .regular : .accessory)
        persist()
    }

    func setGuardianEnabled(_ enabled: Bool) {
        document.preferences.guardianEnabled = enabled
        persist()
    }

    func setExpanded(_ expanded: Bool) {
        document.preferences.hiddenSectionExpanded = expanded
        persist()
    }

    func setAIProvider(_ provider: AIProvider) {
        document.preferences.aiProvider = provider
        persist()
    }

    func setAIModel(_ model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        document.preferences.aiModel = trimmed.isEmpty ? "deepseek-chat" : trimmed
        persist()
    }

    func setAIBaseURL(_ baseURL: String) {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        document.preferences.aiBaseURL = trimmed.isEmpty ? "https://api.deepseek.com" : trimmed
        persist()
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        document.preferences.launchAtLogin = enabled
        persist()
    }

    func applyAppearance() {
        switch document.preferences.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func exportURL() -> URL { fileURL }

    private func persist() {
        document.savedAt = .now
        do {
            try encoder.encode(document).write(to: fileURL, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
        objectWillChange.send()
    }
}
