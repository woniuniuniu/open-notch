import Foundation

public enum ItemIdentityResolver {
    private static let bundleScopedIdentities: Set<String> = [
        "com.microsoft.OneDrive",
    ]

    public static func resolve(
        bundleIdentifier: String,
        semanticIdentifier: String,
        title: String,
        scopeToBundle: Bool = false
    ) -> ItemIdentity? {
        let bundle = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundle.isEmpty, !bundle.hasPrefix("unknown.") else { return nil }

        if scopeToBundle || bundleScopedIdentities.contains(bundle) {
            return ItemIdentity(
                stableID: "bundle:\(bundle)",
                bundleIdentifier: bundle,
                semanticIdentifier: semanticIdentifier
            )
        }

        let semantic = semanticIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !semantic.isEmpty {
            return ItemIdentity(
                stableID: "item:\(bundle):\(escaped(semantic))",
                bundleIdentifier: bundle,
                semanticIdentifier: semantic
            )
        }

        let normalizedTitle = normalized(title)
        return ItemIdentity(
            stableID: "item:\(bundle):\(normalizedTitle.isEmpty ? "default" : normalizedTitle)",
            bundleIdentifier: bundle,
            semanticIdentifier: ""
        )
    }

    public static func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    private static func escaped(_ value: String) -> String {
        let normalized = normalized(value)
        return normalized.isEmpty ? "default" : normalized
    }
}
