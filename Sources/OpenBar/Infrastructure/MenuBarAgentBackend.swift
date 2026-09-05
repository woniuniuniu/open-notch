import AppKit
import Foundation
import OpenBarCore

@MainActor
final class MenuBarAgentBackend: MenuBarBackend {
    private static let systemItemIDs: [String: Int] = [
        "Battery": 0, "Bluetooth": 1, "Clock": 2, "Display": 3,
        "Keyboard": 4, "Sound": 5, "WiFi": 6, "ScreenMirroring": 7,
        "BentoBox": 8, "BentoBox-0": 8,
    ]

    let name = "MenuBarAgent"
    let capabilities = BackendCapabilities(
        kind: .menuBarAgent,
        canInspectItems: true,
        supportsThreeSections: true,
        supportsNativeReorder: false,
        changesArePerApplication: true
    )
    let requiresAccessibility = true
    let excludedWindowIDs: Set<CGWindowID> = []

    private let assessment = AssessmentVisibilityController()
    private let onAssessmentApplied: () -> Void

    init(onAssessmentApplied: @escaping () -> Void = {}) {
        self.onAssessmentApplied = onAssessmentApplied
    }

    func setExpanded(_ expanded: Bool) {}


    func scan() async -> [LiveMenuBarItem] {
        // The anonymous hosting frames exposed by MenuBarAgent are not
        // semantic status items. Their geometry can contain transient slots
        // and duplicated windows, so treating them as an ordering skeleton
        // invents products that are not actually present. The direct AX
        // inventory is the reliable source for the current item set; the app
        // intentionally follows that order and leaves native horizontal
        // ordering to macOS.
        let result = await AccessibilityInventory.menuExtras()
            .compactMap(makeItem)
            .sorted { $0.frame.minX < $1.frame.minX }

        var seen = Set<String>()
        return result
            .filter { !$0.isProtected && seen.insert($0.id).inserted }
    }

    func apply(
        document: PolicyDocument,
        liveItems: [LiveMenuBarItem],
        reason: ApplyReason
    ) async -> BackendApplyResult {
        guard !document.knownItems.isEmpty || !liveItems.isEmpty else {
            assessment.stop()
            return .init(accepted: false, message: L("Skipped an empty menu bar inventory"))
        }

        let expanded = document.preferences.hiddenSectionExpanded
        // MenuBarAgent uses the stable numeric IDs 0...8 for the built-in
        // system modules. Starting with a bounded set is important: passing
        // arbitrary IDs can make the agent allocate an invalid slot for the
        // app's own status item and place it at AX x=-1.
        var allowedSystemItems = Set(0...8)
        var bundleVisibility: [String: Bool] = [:]

        let liveIDs = Set(liveItems.map(\.id))
        for known in document.knownItems.values {
            // Historical panel modules are not evidence of a standalone icon.
            if known.semanticIdentifier.hasPrefix("module:"),
               known.semanticIdentifier != "module:BentoBox", !liveIDs.contains(known.id) {
                continue
            }
            let policy = document.policies[known.id] ?? ItemPolicy()
            let visible = shouldShow(policy.section, expanded: expanded)
            if known.semanticIdentifier.hasPrefix("module:") {
                let module = String(known.semanticIdentifier.dropFirst("module:".count))
                if !visible, let systemID = Self.systemItemIDs[module] {
                    allowedSystemItems.remove(systemID)
                }
            } else {
                bundleVisibility[known.bundleIdentifier, default: false] =
                    bundleVisibility[known.bundleIdentifier, default: false] || visible
            }
        }

        for item in liveItems where !item.isProtected {
            let policy = document.policies[item.id] ?? ItemPolicy()
            let visible = shouldShow(policy.section, expanded: expanded)
            if item.semanticIdentifier.hasPrefix("module:") {
                let module = String(item.semanticIdentifier.dropFirst("module:".count))
                if !visible, let systemID = Self.systemItemIDs[module] {
                    allowedSystemItems.remove(systemID)
                }
            } else {
                bundleVisibility[item.bundleIdentifier, default: false] =
                    bundleVisibility[item.bundleIdentifier, default: false] || visible
            }
        }

        var allowedBundles = Set(bundleVisibility.filter(\.value).map(\.key))
        allowedBundles.insert(Bundle.main.bundleIdentifier ?? "com.woniuniuniu.OpenBar")
        // Some Tahoe builds associate an NSStatusItem with the app's status
        // host preference domain rather than its main bundle identifier.
        // Keeping this harmless companion ID allowed makes the app's own
        // native control survive assessment on both layouts.
        allowedBundles.insert("com.woniuniuniu.OpenBar.StatusHost")
        return await withCheckedContinuation { continuation in
        assessment.apply(
            allowedSystemItems: allowedSystemItems,
            allowedBundleIdentifiers: allowedBundles
        ) { result in
            Task { @MainActor in
                switch result {
                case .applied:
                    Diagnostics.shared.append(
                        "assessment applied; bundles=\(allowedBundles.count); system=\(allowedSystemItems.count)"
                    )
                    self.onAssessmentApplied()
                    continuation.resume(returning: .init(accepted: true, message: L("Menu bar policy applied")))
                case .unavailable:
                    Diagnostics.shared.append("assessment unavailable; layout unchanged")
                    continuation.resume(returning: .init(accepted: false, message: L("Menu bar control is unavailable on this system")))
                case .failed(let message):
                    Diagnostics.shared.append("assessment failed; \(message)")
                    continuation.resume(returning: .init(accepted: false, message: message))
                }
            }
        }
        }
    }

    func stop() { assessment.stop() }

    private func shouldShow(_ section: ItemSection, expanded: Bool) -> Bool {
        switch section {
        case .shown: true
        case .hidden: expanded
        case .alwaysHidden: false
        }
    }

    private func makeItem(_ extra: AccessibilityMenuExtra) -> LiveMenuBarItem? {
        guard !extra.bundleIdentifier.isEmpty else { return nil }
        if extra.bundleIdentifier == "com.apple.MenuBarAgent",
           MenuBarItemPresentation.moduleName([extra.identifier, extra.title, extra.detail].joined(separator: " ")) == nil {
            return nil
        }

        let rawTitle = firstNonEmpty(extra.title, extra.detail, extra.identifier)
        if extra.bundleIdentifier == "com.apple.controlcenter" || extra.bundleIdentifier == "com.apple.MenuBarAgent" {
            guard let module = MenuBarItemPresentation.moduleName(
                [extra.identifier, extra.title, extra.detail].joined(separator: " ")
            ) else { return nil }
            let canonicalModule = module == "BentoBox-0" ? "BentoBox" : module
            let semantic = "module:\(canonicalModule)"
            return LiveMenuBarItem(
                id: semantic,
                windowID: 0,
                hostPID: extra.hostPID,
                hostBundleIdentifier: extra.bundleIdentifier,
                bundleIdentifier: "com.apple.menuextra.\(canonicalModule.lowercased())",
                semanticIdentifier: semantic,
                rawTitle: canonicalModule,
                displayName: MenuBarItemPresentation.moduleDisplayName(canonicalModule),
                symbolName: MenuBarItemPresentation.symbol(bundle: semantic, identifier: canonicalModule),
                frame: extra.frame,
                isProtected: false,
                actualSection: nil
            )
        }

        guard let identity = ItemIdentityResolver.resolve(
            bundleIdentifier: extra.bundleIdentifier,
            semanticIdentifier: extra.identifier,
            title: rawTitle,
            scopeToBundle: true
        ) else { return nil }
        return LiveMenuBarItem(
            id: identity.stableID,
            windowID: 0,
            hostPID: extra.hostPID,
            hostBundleIdentifier: extra.bundleIdentifier,
            bundleIdentifier: identity.bundleIdentifier,
            semanticIdentifier: identity.semanticIdentifier,
            rawTitle: rawTitle,
            displayName: MenuBarItemPresentation.name(
                bundle: extra.bundleIdentifier,
                appName: extra.applicationName,
                title: rawTitle,
                identifier: extra.identifier
            ),
            symbolName: MenuBarItemPresentation.symbol(
                bundle: extra.bundleIdentifier,
                identifier: extra.identifier,
                title: rawTitle
            ),
            frame: extra.frame,
            isProtected: false,
            actualSection: nil
        )
    }

    private func firstNonEmpty(_ values: String...) -> String {
        values.first { !$0.isEmpty } ?? ""
    }
}
