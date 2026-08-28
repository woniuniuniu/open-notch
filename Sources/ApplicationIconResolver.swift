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

    /// Returns the closest honest representation for a hidden menu item.
    ///
    /// macOS does not expose third-party menu-extra images through the
    /// accessibility tree. Guessing a glyph from an app name is misleading
    /// (and particularly noticeable in the compact hidden bar), so only
    /// symbols that come from a known Apple menu extra are used here. For a
    /// third-party item, the app's own icon is the stable identity we can
    /// actually verify.
    func statusBarSymbol(for item: MenuBarItem) -> NSImage? {
        if isTrustedSystemItem(item), let symbolName = statusBarSymbolName(for: item) {
            let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            if let image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: item.displayName
            )?.withSymbolConfiguration(configuration) {
                image.isTemplate = true
                return image
            }
        }

        // An unknown third-party menu extra is still more useful as its real
        // app icon than as a repeated placeholder. Keep it in color because
        // treating an opaque AppIcon as a template produces a solid square.
        if let applicationIcon = icon(for: item) {
            let copy = applicationIcon.copy() as? NSImage ?? applicationIcon
            copy.size = NSSize(width: 15, height: 15)
            copy.isTemplate = false
            return copy
        }

        let fallback = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: item.displayName)
        fallback?.isTemplate = true
        return fallback
    }

    private func statusBarSymbolName(for item: MenuBarItem) -> String? {
        guard item.symbolName != "app.dashed" else { return nil }
        return item.symbolName
    }

    private func isTrustedSystemItem(_ item: MenuBarItem) -> Bool {
        item.semanticBundleIdentifier.hasPrefix("com.apple.")
            || item.semanticIdentifier.hasPrefix("com.apple.")
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
