import AppKit
import Foundation

/// macOS 27 replaced independent status-item windows with a MenuBarAgent
/// composite. This controller updates that compositor directly and never posts
/// mouse or keyboard events.
@MainActor
final class MacOS27VisibilityController {
    static let shared = MacOS27VisibilityController()

    private var assertion: UnsafeMutableRawPointer?
    private(set) var concealedBundleIdentifiers = Set<String>()
    private var allowedBundleIdentifiers = Set<String>()

    private init() {}

    var isAvailable: Bool { PlatformVersion.isMacOS27OrNewer }

    func apply(items: [MenuBarItem], settings: SettingsStore, showAll: Bool = false) -> Bool {
        guard isAvailable else { return false }

        var hidden = Set<String>()
        let grouped = Dictionary(grouping: items, by: \.semanticBundleIdentifier)
        for (bundleID, siblings) in grouped where !showAll {
            guard !bundleID.isEmpty, !bundleID.hasPrefix("com.apple.MenuBarAgent") else { continue }
            // The system assertion works at bundle granularity. If an app owns
            // multiple icons, preserve all of them when any sibling is visible.
            let allHidden = siblings.allSatisfy {
                !$0.isProtected && settings.disposition(for: $0) == .hidden
            }
            if allHidden { hidden.insert(bundleID) }
        }

        var allowed = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        allowed.insert(Bundle.main.bundleIdentifier ?? "com.openbartender.OpenNotch")
        allowed.subtract(hidden)
        if assertion != nil,
           hidden == concealedBundleIdentifiers,
           allowed == allowedBundleIdentifiers
        {
            return true
        }
        let systemItems = (0...8).map(NSNumber.init(value:))
        guard let next = ONCreateVisibilityAssertion(systemItems, Array(allowed).sorted()) else {
            Diagnostics.shared.append("macOS 27 visibility assertion unavailable")
            return false
        }

        let previous = assertion
        assertion = next
        concealedBundleIdentifiers = hidden
        allowedBundleIdentifiers = allowed
        Diagnostics.shared.append(
            "macOS 27 visibility assertion applied; allowed=\(allowed.count); concealed=\(hidden.sorted().joined(separator: ","))"
        )
        if let previous {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                ONInvalidateVisibilityAssertion(previous)
            }
        }
        return true
    }

    func disposition(for item: MenuBarItem) -> ItemDisposition {
        concealedBundleIdentifiers.contains(item.semanticBundleIdentifier) ? .hidden : .visible
    }

    func invalidate() {
        if let assertion {
            ONInvalidateVisibilityAssertion(assertion)
            self.assertion = nil
        }
        concealedBundleIdentifiers.removeAll()
        allowedBundleIdentifiers.removeAll()
    }

    deinit {
        if let assertion { ONInvalidateVisibilityAssertion(assertion) }
    }
}
