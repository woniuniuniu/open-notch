import AppKit
import Foundation

@MainActor
final class ApplicationIconResolver {
    static let shared = ApplicationIconResolver()

    private var cache = [String: NSImage?]()
    private var nameCache = [String: String]()

    private init() {}

    func preload(_ items: [MenuBarItem]) {
        for item in items {
            _ = icon(for: item)
        }
    }

    func icon(for item: MenuBarItem) -> NSImage? {
        let bundleIdentifier = item.semanticBundleIdentifier
        guard
            !bundleIdentifier.isEmpty,
            bundleIdentifier != "com.apple.controlcenter",
            !bundleIdentifier.hasPrefix("com.apple.menuextra."),
            !bundleIdentifier.hasPrefix("unknown."),
            !(bundleIdentifier.hasPrefix("com.apple.") && item.symbolName != "app.dashed")
        else { return nil }

        if let cached = cache[bundleIdentifier] {
            return cached
        }

        let applicationURL = NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleIdentifier }?
            .bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)

        guard let applicationURL else {
            cache[bundleIdentifier] = nil
            return nil
        }

        let image = NSWorkspace.shared.icon(forFile: applicationURL.path)
        let copy = image.copy() as? NSImage ?? image
        copy.isTemplate = false
        cache[bundleIdentifier] = copy
        return copy
    }

    /// Produces a monochrome glyph for surfaces that visually extend the menu
    /// bar. Dock icons remain useful in settings, but do not belong in a row of
    /// status items and cannot follow the menu bar's light/dark appearance.
    func statusBarSymbol(for item: MenuBarItem) -> NSImage? {
        let symbolName = item.symbolName == "app.dashed" ? "circle.dashed" : item.symbolName
        let configuration = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        guard let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: item.displayName
        )?.withSymbolConfiguration(configuration) else { return nil }
        image.isTemplate = true
        return image
    }

    func applicationName(for bundleIdentifier: String, fallback: String) -> String {
        guard !bundleIdentifier.isEmpty else { return fallback }
        if let cached = nameCache[bundleIdentifier] { return cached }

        if let runningName = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleIdentifier })?
            .localizedName,
           !runningName.isEmpty
        {
            nameCache[bundleIdentifier] = runningName
            return runningName
        }

        guard
            let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
            let bundle = Bundle(url: applicationURL)
        else {
            nameCache[bundleIdentifier] = fallback
            return fallback
        }
        let localized = bundle.localizedInfoDictionary
        let info = bundle.infoDictionary
        let resolved = (localized?["CFBundleDisplayName"] as? String)
            ?? (localized?["CFBundleName"] as? String)
            ?? (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? applicationURL.deletingPathExtension().lastPathComponent
        let name = resolved.isEmpty ? fallback : resolved
        nameCache[bundleIdentifier] = name
        return name
    }
}
