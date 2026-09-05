import AppKit
import Foundation
import OpenBarCore

@MainActor
final class LegacyMenuBarBackend: MenuBarBackend {
    let name = "WindowServer + Accessibility"
    let capabilities = BackendCapabilities(
        kind: .legacy,
        canInspectItems: true,
        supportsThreeSections: true,
        supportsNativeReorder: false,
        changesArePerApplication: false
    )
    let requiresAccessibility = true

    private let sections: LegacySectionController
    private var previousItems: [LiveMenuBarItem] = []

    init(sections: LegacySectionController) {
        self.sections = sections
    }

    var excludedWindowIDs: Set<CGWindowID> { sections.excludedWindowIDs }

    func setExpanded(_ expanded: Bool) {
        sections.setExpanded(expanded)
    }

    func scan() async -> [LiveMenuBarItem] {
        let windows = WindowInventory.statusWindows(excluding: excludedWindowIDs)
        var extras = await AccessibilityInventory.menuExtras()
        let previousByWindow = Dictionary(
            previousItems.map { ($0.windowID, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        var result: [LiveMenuBarItem] = []

        for window in windows {
            let closest = extras.indices.min {
                distance(window.frame, extras[$0].frame) < distance(window.frame, extras[$1].frame)
            }
            var semantic: AccessibilityMenuExtra?
            if let closest, distance(window.frame, extras[closest].frame) <= 14 {
                semantic = extras.remove(at: closest)
            }

            if semantic == nil, let previous = previousByWindow[window.windowID],
               !previous.bundleIdentifier.hasPrefix("unknown.") {
                result.append(rebound(previous, window: window))
                continue
            }

            let bundle = semantic?.bundleIdentifier ?? window.hostBundleIdentifier
            if bundle.hasPrefix("unknown.") { continue }
            if semantic == nil, bundle == "com.apple.controlcenter",
               window.title.isEmpty || window.title.hasPrefix("Item-") { continue }

            let identifier = semantic?.identifier ?? ""
            let rawTitle = firstNonEmpty(semantic?.title, semantic?.detail, window.title)
            guard let identity = ItemIdentityResolver.resolve(
                bundleIdentifier: bundle,
                semanticIdentifier: identifier,
                title: rawTitle
            ) else { continue }
            let ownBundle = Bundle.main.bundleIdentifier ?? "com.woniuniuniu.OpenBar"
            result.append(LiveMenuBarItem(
                id: identity.stableID,
                windowID: window.windowID,
                hostPID: window.hostPID,
                hostBundleIdentifier: window.hostBundleIdentifier,
                bundleIdentifier: identity.bundleIdentifier,
                semanticIdentifier: identity.semanticIdentifier,
                rawTitle: rawTitle,
                displayName: MenuBarItemPresentation.name(
                    bundle: bundle,
                    appName: semantic?.applicationName ?? window.hostName,
                    title: rawTitle,
                    identifier: identifier
                ),
                symbolName: MenuBarItemPresentation.symbol(
                    bundle: bundle,
                    identifier: identifier,
                    title: rawTitle
                ),
                frame: window.frame,
                isProtected: bundle == ownBundle,
                actualSection: sections.actualSection(for: window.frame)
            ))
        }
        var seen = Set<String>()
        previousItems = result.filter { seen.insert($0.id).inserted }
        return previousItems
    }

    func apply(
        document: PolicyDocument,
        liveItems: [LiveMenuBarItem],
        reason: ApplyReason
    ) async -> BackendApplyResult {
        let targets: [LiveMenuBarItem]
        switch reason {
        case .user(let itemID):
            targets = liveItems.filter { $0.id == itemID }
        case .guardian:
            targets = Array(liveItems.filter {
                guard let actual = $0.actualSection else { return false }
                let policy = document.policies[$0.id] ?? ItemPolicy()
                return policy.guardsAgainstDrift && policy.section != actual
            }.prefix(1))
        case .startup, .aiPlacement:
            targets = liveItems.filter {
                guard let actual = $0.actualSection else { return false }
                return (document.policies[$0.id] ?? ItemPolicy()).section != actual
            }
        case .expansion:
            return .init(accepted: true, message: L("Section visibility updated"))
        }

        guard !targets.isEmpty else {
            return .init(accepted: true, message: L("Layout is already in sync"))
        }
        sections.prepareForMovement()
        defer { sections.setExpanded(document.preferences.hiddenSectionExpanded) }

        var moved = 0
        var deferred = 0
        for item in targets {
            let target = document.policies[item.id]?.section ?? .shown
            guard let boundary = sections.boundary(for: target) else { continue }
            switch TargetedDragController.move(item, to: target, boundary: boundary) {
            case .moved: moved += 1
            case .userBusy: deferred += 1
            case .failed: break
            }
        }
        if deferred > 0 {
            return .init(accepted: false, message: L("Deferred while you are using the pointer"))
        }
        return .init(
            accepted: moved == targets.count,
            message: LF("Updated %d menu bar items", moved)
        )
    }

    func stop() {}

    private func rebound(_ item: LiveMenuBarItem, window: RawStatusWindow) -> LiveMenuBarItem {
        LiveMenuBarItem(
            id: item.id,
            windowID: window.windowID,
            hostPID: window.hostPID,
            hostBundleIdentifier: window.hostBundleIdentifier,
            bundleIdentifier: item.bundleIdentifier,
            semanticIdentifier: item.semanticIdentifier,
            rawTitle: item.rawTitle,
            displayName: item.displayName,
            symbolName: item.symbolName,
            frame: window.frame,
            isProtected: item.isProtected,
            actualSection: sections.actualSection(for: window.frame)
        )
    }

    private func distance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.midX - rhs.midX) + abs(lhs.midY - rhs.midY)
    }

    private func firstNonEmpty(_ values: String?...) -> String {
        values.compactMap { $0 }.first { !$0.isEmpty } ?? ""
    }
}
