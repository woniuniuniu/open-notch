import AppKit
import Foundation

@MainActor
final class ApplicationIconResolver {
    static let shared = ApplicationIconResolver()

    private var cache = [String: NSImage]()

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

        if let cached = cache[bundleIdentifier] { return cached }

        // Menu-bar helpers often expose a different bundle identifier from
        // their parent application. Resolve the concrete process first so
        // helper items still receive the icon that is actually running.
        let runningApplication = item.hostPID > 0
            ? NSRunningApplication(processIdentifier: item.hostPID)
            : nil
        let application = runningApplication
            ?? NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleIdentifier }

        let image: NSImage?
        if let applicationIcon = application?.icon {
            image = applicationIcon
        } else if let applicationURL = application?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            image = NSWorkspace.shared.icon(forFile: applicationURL.path)
        } else {
            image = nil
        }

        guard let image else {
            // Do not permanently cache a miss: an app may launch after the
            // first discovery pass and become resolvable on the next refresh.
            return nil
        }
        let copy = image.copy() as? NSImage ?? image
        copy.isTemplate = false
        cache[bundleIdentifier] = copy
        return copy
    }
}
