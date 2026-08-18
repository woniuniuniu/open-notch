import AppKit
import Foundation

@MainActor
final class ApplicationIconResolver {
    static let shared = ApplicationIconResolver()

    private var cache = [String: NSImage?]()

    private init() {}

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
}
