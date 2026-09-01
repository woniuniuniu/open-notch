import AppKit
import Foundation

@MainActor
final class ApplicationIconResolver {
    static let shared = ApplicationIconResolver()

    private var cache: [String: NSImage] = [:]
    private let fallbackSymbolNames = ["square.grid.2x2", "app.dashed", "questionmark.app"]

    func icon(for item: ManagedMenuBarItem) -> NSImage? {
        // System menu extras are not normal applications. Asking NSWorkspace for
        // their app icon can return nil (or an unrelated helper icon), so they
        // are rendered with their semantic SF Symbol fallback instead.
        guard !isSystemItem(item) else { return nil }
        let cacheKey = item.id
        if let cached = cache[cacheKey] { return cached }

        // AX reports the host process for some menu extras (for example a
        // Setapp helper) instead of the app bundle that owns the visible item.
        // Prefer a live process icon first, then resolve the bundle on disk.
        let bundles = [item.bundleIdentifier, item.liveItem?.hostBundleIdentifier]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, bundle in
                if !result.contains(bundle) { result.append(bundle) }
            }

        for bundle in bundles {
            if let running = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundle)
                .first,
               let image = running.icon {
                let normalized = normalizedIcon(image)
                cache[cacheKey] = normalized
                return normalized
            }

            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                let normalized = normalizedIcon(NSWorkspace.shared.icon(forFile: url.path))
                cache[cacheKey] = normalized
                return normalized
            }
        }
        return nil
    }

    func symbolName(for item: ManagedMenuBarItem) -> String {
        let candidate = item.symbolName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.isEmpty,
           NSImage(systemSymbolName: candidate, accessibilityDescription: nil) != nil {
            return candidate
        }
        return fallbackSymbolNames.first {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
        } ?? "app.dashed"
    }

    private func isSystemItem(_ item: ManagedMenuBarItem) -> Bool {
        item.semanticIdentifier.hasPrefix("module:")
            || item.bundleIdentifier.hasPrefix("com.apple.")
            || item.bundleIdentifier.hasPrefix("com.apple.menuextra.")
    }

    private func normalizedIcon(_ image: NSImage) -> NSImage {
        image.isTemplate = false
        image.size = NSSize(width: 64, height: 64)
        return image
    }
}
