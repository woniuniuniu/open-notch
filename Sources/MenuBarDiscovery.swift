import AppKit
import CoreGraphics
import Foundation

struct RawStatusWindow {
    let windowID: CGWindowID
    let hostPID: pid_t
    let hostName: String
    let hostBundleIdentifier: String
    let title: String
    let frame: CGRect
}

struct MenuBarScanReport {
    let items: [MenuBarItem]
    let diagnosticSummary: String
}

/// Read-only inventory for status windows and accessibility identities.
/// This type never synthesizes or posts input events.
enum MenuBarDiscovery {
    static func scan(
        excluding excludedWindowIDs: Set<CGWindowID> = [],
        previousItems: [MenuBarItem] = []
    ) -> [MenuBarItem] {
        scanReport(excluding: excludedWindowIDs, previousItems: previousItems).items
    }

    static func scanReport(
        excluding excludedWindowIDs: Set<CGWindowID> = [],
        previousItems: [MenuBarItem] = []
    ) -> MenuBarScanReport {
        let inventory = statusWindowInventory()
        let windows = inventory.windows.filter { !excludedWindowIDs.contains($0.windowID) }
        let semanticExtras = AccessibilityResolver.menuExtras()
        let previousByWindowID = Dictionary(
            previousItems.map { ($0.windowID, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        var unmatchedExtras = semanticExtras
        var result = [MenuBarItem]()

        for window in windows.sorted(by: { $0.frame.minX < $1.frame.minX }) {
            let bestIndex = unmatchedExtras.indices.min { lhs, rhs in
                matchScore(window.frame, unmatchedExtras[lhs].frame) < matchScore(window.frame, unmatchedExtras[rhs].frame)
            }

            var semantic: SemanticMenuExtra?
            if let bestIndex, matchScore(window.frame, unmatchedExtras[bestIndex].frame) <= 12 {
                semantic = unmatchedExtras.remove(at: bestIndex)
            }

            if
                semantic == nil,
                let previous = previousByWindowID[window.windowID],
                !previous.isAnonymousControlCenterItem,
                !previous.hasUnknownHostIdentity
            {
                result.append(item(reusing: previous, window: window))
                continue
            }

            // Tahoe 26.5 changes a hosted item's title to Item-0 as soon as its
            // AX frame becomes unavailable. Without a previous binding there is
            // no safe way to know which app it belongs to, so do not expose it
            // as a new user-manageable item.
            if semantic == nil, isAnonymousControlCenterWindow(window) {
                continue
            }

            if semantic == nil, window.hostBundleIdentifier.hasPrefix("unknown.") {
                continue
            }

            let semanticBundle = semantic?.bundleIdentifier ?? window.hostBundleIdentifier
            let semanticIdentifier = semantic?.identifier ?? ""
            let rawTitle = firstNonEmpty(semantic?.title, semantic?.description, window.title)
            let stableID = persistentID(
                semanticBundleIdentifier: semanticBundle,
                semanticIdentifier: semanticIdentifier,
                title: rawTitle,
                window: window
            )
            let displayName = displayName(
                semanticBundleIdentifier: semanticBundle,
                semanticIdentifier: semanticIdentifier,
                applicationName: semantic?.applicationName,
                title: rawTitle,
                hostName: window.hostName
            )
            let protected = isProtected(semanticIdentifier: semanticIdentifier, bundleIdentifier: semanticBundle)

            result.append(MenuBarItem(
                id: stableID,
                windowID: window.windowID,
                hostPID: window.hostPID,
                hostBundleIdentifier: window.hostBundleIdentifier,
                semanticBundleIdentifier: semanticBundle,
                semanticIdentifier: semanticIdentifier,
                rawTitle: rawTitle,
                displayName: displayName,
                symbolName: symbolName(
                    semanticBundleIdentifier: semanticBundle,
                    semanticIdentifier: semanticIdentifier,
                    title: rawTitle
                ),
                frame: window.frame,
                isProtected: protected
            ))
        }

        return MenuBarScanReport(
            items: deduplicated(result),
            diagnosticSummary: "\(inventory.diagnosticSummary); axExtras=\(semanticExtras.count); matchedWindows=\(windows.count)"
        )
    }

    static func statusWindow(id: CGWindowID) -> RawStatusWindow? {
        statusWindows().first { $0.windowID == id }
    }

    static func closestStatusWindow(to frame: CGRect) -> RawStatusWindow? {
        statusWindows().min { lhs, rhs in
            matchScore(lhs.frame, frame) < matchScore(rhs.frame, frame)
        }.flatMap { matchScore($0.frame, frame) <= max(18, frame.width * 0.05) ? $0 : nil }
    }

    static func statusWindows() -> [RawStatusWindow] {
        statusWindowInventory().windows
    }

    static func publicStatusWindows() -> [RawStatusWindow] {
        rawStatusWindows(from: publicWindowDescriptions())
    }

    private static func publicWindowDescriptions() -> [[String: Any]] {
        CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
    }

    private struct StatusWindowInventory {
        let windows: [RawStatusWindow]
        let diagnosticSummary: String
    }

    private static func statusWindowInventory() -> StatusWindowInventory {
        let publicDescriptions: [[String: Any]]
        let selectedDescriptions: [[String: Any]]
        let source: String
        let cgsSummary: String

        if WindowServerBridge.usesIndividualWindowEnumeration {
            let cgs = WindowServerBridge.inventory()
            cgsSummary = cgs.diagnosticSummary
            if cgs.descriptions.isEmpty {
                publicDescriptions = publicWindowDescriptions()
                selectedDescriptions = publicDescriptions
                source = "CoreGraphics public fallback"
            } else {
                publicDescriptions = []
                selectedDescriptions = cgs.descriptions
                source = "WindowServer CGS"
            }
        } else {
            publicDescriptions = publicWindowDescriptions()
            selectedDescriptions = publicDescriptions
            source = "CoreGraphics public inventory"
            cgsSummary = "cgsRaw=not-requested; cgsEligible=not-requested; cgsDescriptions=not-requested"
        }

        let windows = rawStatusWindows(from: selectedDescriptions)
        let publicStatusCount = publicDescriptions.reduce(into: 0) { count, info in
            if (info[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.statusWindow)) {
                count += 1
            }
        }
        return StatusWindowInventory(
            windows: windows,
            diagnosticSummary: "requested=\(WindowServerBridge.enumerationName); effective=\(source); \(cgsSummary); publicDescriptions=\(publicDescriptions.count); publicStatus=\(publicStatusCount); usableStatus=\(windows.count)"
        )
    }

    private static func rawStatusWindows(from list: [[String: Any]]) -> [RawStatusWindow] {
        guard !list.isEmpty else {
            return []
        }

        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        return list.compactMap { info in
            guard
                let layer = info[kCGWindowLayer as String] as? Int,
                layer == statusLevel,
                let rawID = info[kCGWindowNumber as String] as? NSNumber,
                let rawPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: bounds),
                frame.width > 0,
                frame.height > 0,
                frame.minY < 80
            else { return nil }

            let pid = pid_t(rawPID.int32Value)
            let app = NSRunningApplication(processIdentifier: pid)
            return RawStatusWindow(
                windowID: CGWindowID(rawID.uint32Value),
                hostPID: pid,
                hostName: info[kCGWindowOwnerName as String] as? String ?? app?.localizedName ?? L("Unknown"),
                hostBundleIdentifier: app?.bundleIdentifier ?? "unknown.\(pid)",
                title: info[kCGWindowName as String] as? String ?? "",
                frame: frame
            )
        }
    }

    private static func matchScore(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.midX - rhs.midX) + abs(lhs.midY - rhs.midY) + abs(lhs.width - rhs.width) * 0.25
    }

    private static func item(reusing previous: MenuBarItem, window: RawStatusWindow) -> MenuBarItem {
        MenuBarItem(
            id: previous.id,
            windowID: window.windowID,
            hostPID: window.hostPID,
            hostBundleIdentifier: window.hostBundleIdentifier,
            semanticBundleIdentifier: previous.semanticBundleIdentifier,
            semanticIdentifier: previous.semanticIdentifier,
            rawTitle: previous.rawTitle,
            displayName: displayName(
                semanticBundleIdentifier: previous.semanticBundleIdentifier,
                semanticIdentifier: previous.semanticIdentifier,
                applicationName: nil,
                title: previous.rawTitle,
                hostName: window.hostName
            ),
            symbolName: previous.symbolName,
            frame: window.frame,
            isProtected: previous.isProtected
        )
    }

    private static func isAnonymousControlCenterWindow(_ window: RawStatusWindow) -> Bool {
        guard window.hostBundleIdentifier == "com.apple.controlcenter" else { return false }
        return window.title.isEmpty || window.title == "Item-0"
    }

    private static func persistentID(
        semanticBundleIdentifier: String,
        semanticIdentifier: String,
        title: String,
        window: RawStatusWindow
    ) -> String {
        if semanticBundleIdentifier == "com.microsoft.OneDrive" {
            return "app:com.microsoft.OneDrive"
        }
        if !semanticIdentifier.isEmpty {
            return "extra:\(semanticIdentifier)"
        }
        if semanticBundleIdentifier != "com.apple.controlcenter" {
            return "app:\(semanticBundleIdentifier):\(normalizedTitle(title))"
        }
        return "host:\(window.hostBundleIdentifier):\(normalizedTitle(title)):\(Int(window.frame.width.rounded()))"
    }

    private static func displayName(
        semanticBundleIdentifier: String,
        semanticIdentifier: String,
        applicationName: String?,
        title: String,
        hostName: String
    ) -> String {
        if semanticBundleIdentifier == "com.microsoft.OneDrive" { return "OneDrive" }
        let known: [String: String] = [
            "com.apple.menuextra.battery": L("Battery"),
            "com.apple.menuextra.clock": L("Clock"),
            "com.apple.menuextra.wifi": "Wi-Fi",
            "com.apple.menuextra.controlcenter": L("Control Center"),
            "com.apple.menuextra.focusmode": L("Focus"),
        ]
        if let knownName = known[semanticIdentifier] { return knownName }
        if semanticBundleIdentifier == "com.apple.systemuiserver", title == "Siri" { return "Siri" }
        if
            let applicationName,
            !applicationName.isEmpty,
            !applicationName.localizedCaseInsensitiveContains("控制中心"),
            !applicationName.localizedCaseInsensitiveContains("Control Center")
        {
            return applicationName
        }
        let firstLine = title.split(separator: "\n").first.map(String.init) ?? ""
        if !firstLine.isEmpty, firstLine != "Item-0" { return firstLine }
        let isControlCenter = hostName.localizedCaseInsensitiveContains("控制中心")
            || hostName.localizedCaseInsensitiveContains("Control Center")
        return isControlCenter ? L("Unrecognized menu bar item") : hostName
    }

    private static func symbolName(
        semanticBundleIdentifier: String,
        semanticIdentifier: String,
        title: String
    ) -> String {
        if semanticBundleIdentifier == "com.microsoft.OneDrive" { return "cloud.fill" }
        let known: [String: String] = [
            "com.apple.menuextra.battery": "battery.75percent",
            "com.apple.menuextra.clock": "clock",
            "com.apple.menuextra.wifi": "wifi",
            "com.apple.menuextra.controlcenter": "switch.2",
            "com.apple.menuextra.focusmode": "moon.fill",
            "com.apple.menuextra.audiovideo": "speaker.wave.2.fill",
        ]
        if let symbol = known[semanticIdentifier] { return symbol }
        let bundleSymbols: [String: String] = [
            "com.apple.Spotlight": "magnifyingglass",
            "com.apple.TextInputMenuAgent": "character.cursor.ibeam",
        ]
        if let symbol = bundleSymbols[semanticBundleIdentifier] { return symbol }
        if title.localizedCaseInsensitiveContains("Siri") { return "waveform.circle.fill" }
        return "app.dashed"
    }

    private static func isProtected(semanticIdentifier: String, bundleIdentifier: String) -> Bool {
        let protectedIdentifiers: Set<String> = [
            "com.apple.menuextra.clock",
            "com.apple.menuextra.controlcenter",
        ]
        return protectedIdentifiers.contains(semanticIdentifier) || bundleIdentifier == (Bundle.main.bundleIdentifier ?? "")
    }

    private static func normalizedTitle(_ title: String) -> String {
        title
            .split(separator: "\n").first
            .map(String.init)?
            .lowercased()
            .filter { $0.isLetter || $0.isNumber } ?? "untitled"
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        values.compactMap { $0 }.first { !$0.isEmpty } ?? ""
    }

    private static func deduplicated(_ items: [MenuBarItem]) -> [MenuBarItem] {
        var order = [String]()
        var best = [String: MenuBarItem]()
        for item in items {
            guard let existing = best[item.id] else {
                order.append(item.id)
                best[item.id] = item
                continue
            }
            if identityRank(item) > identityRank(existing) {
                best[item.id] = item
            }
        }
        return order.compactMap { best[$0] }
    }

    private static func identityRank(_ item: MenuBarItem) -> Int {
        if item.isOneDrive { return 4 }
        if !item.semanticIdentifier.isEmpty { return 3 }
        if item.semanticBundleIdentifier != "com.apple.controlcenter" { return 2 }
        return 1
    }
}
