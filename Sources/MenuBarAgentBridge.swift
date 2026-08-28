import AppKit
import Foundation
import ObjectiveC

/// Native macOS 27 inventory and visibility bridge. Symbols are resolved at
/// runtime so older macOS releases keep using the existing window-based path.
enum MenuBarAgentBridge {
    private static let domain = "com.apple.MenuBarAgent"
    private static let controlCenterDomain = "com.apple.controlcenter"
    private static let positionsKey = "TrailingItemPreferredPositions"
    private static let controlCenterPositionPrefix = "NSStatusItem Preferred Position "
    private static let inventoryLock = NSLock()
    private static var inventorySupportsVisibility = false
    static let frameworkPath = "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"
    static let enumerationName = "MenuBarAgent positions (experimental macOS 27)"

    static var isAvailable: Bool {
        // Private frameworks can live only in the dyld shared cache, so their
        // install-name path is loadable even when FileManager cannot see it.
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    static var canApplyVisibility: Bool {
        inventoryLock.lock()
        defer { inventoryLock.unlock() }
        return inventorySupportsVisibility
    }

    static func items() -> [MenuBarItem] {
        guard isAvailable else {
            setInventorySupportsVisibility(false)
            return []
        }
        let extras = AccessibilityResolver.menuExtras()
        let positioned = positions()?.compactMap(makeItem).filter(isInstalledOrSystemItem) ?? []
        // During a MenuBarAgent rebuild, beta releases can expose only the
        // built-in module slots while Accessibility has no real menu extras.
        // That is an incomplete inventory, not an empty menu bar; let the
        // public WindowServer/AX fallback handle this pass instead.
        let ownBundleID = Bundle.main.bundleIdentifier ?? "com.openbartender.OpenNotch"
        let supportsVisibility = extras.contains {
            $0.bundleIdentifier != ownBundleID
                && $0.bundleIdentifier != "com.apple.MenuBarAgent"
        } || positioned.contains {
            $0.semanticIdentifier.hasPrefix("status:")
                && $0.semanticBundleIdentifier != ownBundleID
        }
        setInventorySupportsVisibility(supportsVisibility)
        if !supportsVisibility {
            return []
        }
        let agentItems = positioned.map { item in
            guard let extra = bestAccessibilityMatch(for: item, in: extras) else { return item }
            return replacingFrame(of: item, with: extra.frame)
        }

        // macOS 27 beta builds do not always publish
        // `TrailingItemPreferredPositions`. Accessibility still exposes the
        // real menu extras in that case, so use those identities as a
        // read-only inventory instead of treating the menu bar as empty.
        let accessibilityItems = extras.compactMap { makeItem(from: $0) }
        let existingKeys = Set(agentItems.map(identityKey))
        let existingBundles = Set(
            agentItems
                .filter { !$0.semanticIdentifier.hasPrefix("module:") }
                .map(\.semanticBundleIdentifier)
        )
        let supplemental = accessibilityItems.filter {
            !existingKeys.contains(identityKey($0))
                && ($0.semanticIdentifier.hasPrefix("module:")
                    || !existingBundles.contains($0.semanticBundleIdentifier))
        }
        return (agentItems + supplemental)
            .filter(isInstalledOrSystemItem)
            .sorted { lhs, rhs in
                if lhs.frame.minX == rhs.frame.minX { return lhs.id < rhs.id }
                return lhs.frame.minX < rhs.frame.minX
            }
    }

    private static func setInventorySupportsVisibility(_ supported: Bool) {
        inventoryLock.lock()
        inventorySupportsVisibility = supported
        inventoryLock.unlock()
    }

    private static func identityKey(_ item: MenuBarItem) -> String {
        if item.semanticIdentifier.hasPrefix("module:") {
            return item.semanticIdentifier
        }
        return item.semanticBundleIdentifier
    }

    private static func isInstalledOrSystemItem(_ item: MenuBarItem) -> Bool {
        guard item.semanticIdentifier.hasPrefix("status:") else { return true }
        let bundleID = item.semanticBundleIdentifier
        if bundleID.hasPrefix("com.apple.") { return true }
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) {
            return true
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static func positions() -> [String: Double]? {
        var result = [String: Double]()
        if let rawPositions = CFPreferencesCopyValue(
            positionsKey as CFString,
            domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String: Any] {
            for (key, value) in rawPositions {
                if let number = value as? NSNumber { result[key] = number.doubleValue }
            }
        }

        // Tahoe 27 currently stores the built-in module slots in
        // com.apple.controlcenter instead of MenuBarAgent. Keep this bridge
        // deliberately narrow: only known module names become synthetic
        // module identities; arbitrary preference keys are ignored.
        let knownModules = Set([
            "AudioVideoModule", "Battery", "BentoBox", "BentoBox-0", "Clock",
            "Display", "Keyboard", "NowPlaying", "ScreenMirroring", "Sound", "WiFi"
        ])
        for module in knownModules {
            let key = controlCenterPositionPrefix + module
            if let number = CFPreferencesCopyValue(
                key as CFString,
                controlCenterDomain as CFString,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            ) as? NSNumber {
                result["module:\(module)"] = number.doubleValue
            }
        }

        // Third-party status items keep their preferred position in the
        // owning app's preference domain on current macOS 27 builds. Read
        // only the NSStatusItem key family from running apps; this
        // avoids treating unrelated app preferences as menu bar identities.
        let bundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for bundleID in bundleIDs {
            guard let values = CFPreferencesCopyMultiple(
                nil,
                bundleID as CFString,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            ) as? [String: Any] else { continue }
            for (key, value) in values {
                guard
                    key.hasPrefix(controlCenterPositionPrefix),
                    let number = value as? NSNumber
                else { continue }
                let itemID = String(key.dropFirst(controlCenterPositionPrefix.count))
                guard !itemID.isEmpty else { continue }
                result["status:\(bundleID)::\(itemID)"] = number.doubleValue
            }
        }
        return result.isEmpty ? nil : result
    }

    private static func writePosition(_ position: Double, for key: String) -> String? {
        let domain: String
        let preferenceKey: String
        if key.hasPrefix("status:") {
            let payload = String(key.dropFirst("status:".count))
            let parts = payload.components(separatedBy: "::")
            guard parts.count >= 2, let bundleID = parts.first, !bundleID.isEmpty else { return nil }
            domain = bundleID
            preferenceKey = controlCenterPositionPrefix + parts.dropFirst().joined(separator: "::")
        } else if key.hasPrefix("module:") {
            domain = controlCenterDomain
            preferenceKey = controlCenterPositionPrefix + String(key.dropFirst("module:".count))
        } else {
            // Native MenuBarAgent values are written as one dictionary by
            // writePositions(). Writing one NSNumber per raw key would
            // corrupt TrailingItemPreferredPositions.
            return nil
        }
        CFPreferencesSetValue(
            preferenceKey as CFString,
            NSNumber(value: position),
            domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        return domain
    }

    private static func writePositions(_ values: [String: Double]) -> Bool {
        var nativePositions = [String: Double]()
        var domains = Set<String>()
        for (key, position) in values {
            if key.hasPrefix("status:") || key.hasPrefix("module:") {
                if let domain = writePosition(position, for: key) { domains.insert(domain) }
            } else {
                nativePositions[key] = position
            }
        }
        if !nativePositions.isEmpty {
            CFPreferencesSetValue(
                positionsKey as CFString,
                nativePositions as CFDictionary,
                domain as CFString,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
            domains.insert(domain)
        }
        return domains.allSatisfy {
            CFPreferencesSynchronize(
                $0 as CFString,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
        }
    }

    static func preferredPosition(for key: String) -> Double? {
        positions()?[key]
    }

    private static func makeItem(from extra: SemanticMenuExtra) -> MenuBarItem? {
        guard !extra.bundleIdentifier.isEmpty,
              extra.bundleIdentifier != "com.apple.MenuBarAgent"
        else { return nil }

        if extra.bundleIdentifier == "com.apple.controlcenter" {
            guard let module = moduleName(from: extra) else { return nil }
            return MenuBarItem(
                id: "agent:module:\(module)",
                windowID: syntheticWindowID(for: "module:\(module)"),
                hostPID: extra.hostPID,
                hostBundleIdentifier: extra.bundleIdentifier,
                semanticBundleIdentifier: "com.apple.menuextra.\(module.lowercased())",
                semanticIdentifier: "module:\(module)",
                rawTitle: module,
                displayName: moduleDisplayName(module),
                symbolName: moduleSymbolName(module),
                frame: extra.frame,
                isProtected: false
            )
        }

        let rawTitle = firstNonEmpty(extra.title, extra.description, extra.identifier)
        guard !rawTitle.isEmpty else { return nil }
        let semanticIdentifier = extra.identifier
        let id: String
        if extra.bundleIdentifier == "com.microsoft.OneDrive" {
            id = "app:com.microsoft.OneDrive"
        } else if !semanticIdentifier.isEmpty {
            id = "extra:\(semanticIdentifier)"
        } else {
            id = "app:\(extra.bundleIdentifier):\(normalizedTitle(rawTitle))"
        }
        let displayName = extra.bundleIdentifier == "com.microsoft.OneDrive"
            ? "OneDrive"
            : (extra.applicationName.isEmpty ? rawTitle : extra.applicationName)
        return MenuBarItem(
            id: id,
            windowID: syntheticWindowID(for: id),
            hostPID: extra.hostPID,
            hostBundleIdentifier: extra.bundleIdentifier,
            semanticBundleIdentifier: extra.bundleIdentifier,
            semanticIdentifier: semanticIdentifier,
            rawTitle: rawTitle,
            displayName: displayName,
            symbolName: symbolName(for: extra.bundleIdentifier, itemID: semanticIdentifier),
            frame: extra.frame,
            isProtected: extra.bundleIdentifier == Bundle.main.bundleIdentifier
        )
    }

    private static func moduleName(from extra: SemanticMenuExtra) -> String? {
        let haystack = [extra.identifier, extra.title, extra.description]
            .joined(separator: " ")
            .lowercased()
        let matches: [(String, String)] = [
            ("wifi", "WiFi"), ("wi-fi", "WiFi"), ("battery", "Battery"),
            ("sound", "Sound"), ("audio", "AudioVideoModule"), ("clock", "Clock"),
            ("bentobox-0", "BentoBox-0"), ("bentobox", "BentoBox"),
            ("screenmirroring", "ScreenMirroring"), ("nowplaying", "NowPlaying"),
            ("display", "Display"), ("keyboard", "Keyboard")
        ]
        return matches.first { haystack.contains($0.0) }?.1
    }

    private static func moduleDisplayName(_ module: String) -> String {
        switch module {
        case "Battery": return L("Battery")
        case "Clock": return L("Clock")
        case "Sound": return L("Sound")
        case "WiFi": return "Wi-Fi"
        case "NowPlaying": return L("Now Playing")
        case "ScreenMirroring": return L("Screen Mirroring")
        case "BentoBox", "BentoBox-0", "AudioVideoModule": return L("Control Center")
        default: return module
        }
    }

    private static func moduleSymbolName(_ module: String) -> String {
        switch module {
        case "Battery": return "battery.75percent"
        case "Clock": return "clock"
        case "Sound", "AudioVideoModule": return "speaker.wave.2.fill"
        case "WiFi": return "wifi"
        case "NowPlaying": return "play.circle"
        case "ScreenMirroring": return "rectangle.on.rectangle"
        default: return "switch.2"
        }
    }

    /// Updates the preferred order without restarting MenuBarAgent. macOS 27
    /// treats these values as sortable slots. Reassigning existing slots is
    /// substantially more reliable than inventing fractional values between
    /// neighbors, which MenuBarAgent may normalize back to its previous order.
    @MainActor
    static func moveItem(
        _ sourceKey: String,
        adjacentTo targetKey: String,
        placeAfterTarget: Bool,
        liveOrder: [String]
    ) -> Bool {
        guard
            isAvailable,
            sourceKey != targetKey,
            var current = positions(),
            current[sourceKey] != nil,
            current[targetKey] != nil
        else { return false }
        // Preserve the slots currently occupying each real AX position and
        // assign those slots to the requested order. The numeric values are
        // not globally monotonic on macOS 27 (different item families use
        // different ranges), so sorting the numbers corrupts the live order.
        var orderedKeys = liveOrder.filter { current[$0] != nil }
        guard orderedKeys.contains(sourceKey), orderedKeys.contains(targetKey) else { return false }
        let existingSlots = orderedKeys.compactMap { current[$0] }
        guard existingSlots.count == orderedKeys.count else { return false }
        orderedKeys.removeAll { $0 == sourceKey }
        guard let targetIndex = orderedKeys.firstIndex(of: targetKey) else { return false }
        let insertionIndex = targetIndex + (placeAfterTarget ? 1 : 0)
        orderedKeys.insert(sourceKey, at: insertionIndex)

        guard orderedKeys.count == existingSlots.count else { return false }
        for (index, key) in orderedKeys.enumerated() {
            current[key] = existingSlots[index]
        }
        let synchronized = writePositions(current)
        Diagnostics.shared.append(
            "MenuBarAgent reorder; source=\(sourceKey); target=\(targetKey); " +
            "after=\(placeAfterTarget); slot=\(current[sourceKey] ?? -1); synchronized=\(synchronized)"
        )
        return synchronized
    }

    private static func bestAccessibilityMatch(
        for item: MenuBarItem,
        in extras: [SemanticMenuExtra]
    ) -> SemanticMenuExtra? {
        if item.semanticIdentifier.hasPrefix("status:") {
            let candidates = extras.filter { $0.bundleIdentifier == item.semanticBundleIdentifier }
            if candidates.count == 1 { return candidates[0] }
            return candidates.first {
                $0.identifier == item.rawTitle || $0.title == item.rawTitle || $0.description == item.rawTitle
            }
        }
        guard item.semanticIdentifier.hasPrefix("module:") else { return nil }
        let module = item.rawTitle.lowercased()
        return extras.first {
            $0.identifier.lowercased().contains(module)
                || $0.title.lowercased().contains(module)
                || $0.description.lowercased().contains(module)
        }
    }

    private static func replacingFrame(of item: MenuBarItem, with frame: CGRect) -> MenuBarItem {
        MenuBarItem(
            id: item.id, windowID: item.windowID, hostPID: item.hostPID,
            hostBundleIdentifier: item.hostBundleIdentifier,
            semanticBundleIdentifier: item.semanticBundleIdentifier,
            semanticIdentifier: item.semanticIdentifier, rawTitle: item.rawTitle,
            displayName: item.displayName, symbolName: item.symbolName,
            frame: frame, isProtected: item.isProtected
        )
    }

    @MainActor
    static func restorePosition(_ position: Double, for key: String) -> Bool {
        guard isAvailable, key.hasPrefix("status:"), var current = positions(), current[key] != nil else {
            return false
        }
        current[key] = position
        let synchronized = writePositions(current)
        Diagnostics.shared.append("MenuBarAgent position restored; key=\(key); position=\(position); synchronized=\(synchronized)")
        return synchronized
    }

    private static func makeItem(key: String, position: Double) -> MenuBarItem? {
        if key.hasPrefix("status:") {
            let payload = String(key.dropFirst("status:".count))
            let parts = payload.components(separatedBy: "::")
            guard let bundleID = parts.first, !bundleID.isEmpty else { return nil }
            let itemID = parts.dropFirst().joined(separator: "::")
            let app = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
            let name = bundleID == "com.microsoft.OneDrive"
                ? "OneDrive"
                : app?.localizedName ?? displayName(from: bundleID)
            return MenuBarItem(
                id: bundleID == "com.microsoft.OneDrive" ? "app:com.microsoft.OneDrive" : "agent:\(key)",
                windowID: syntheticWindowID(for: key), hostPID: app?.processIdentifier ?? 0,
                hostBundleIdentifier: bundleID, semanticBundleIdentifier: bundleID,
                semanticIdentifier: key, rawTitle: itemID, displayName: name,
                symbolName: symbolName(for: bundleID, itemID: itemID),
                frame: CGRect(x: position, y: 0, width: 1, height: 24),
                isProtected: bundleID == Bundle.main.bundleIdentifier
            )
        }
        if key.hasPrefix("module:") {
            let module = String(key.dropFirst("module:".count))
            return MenuBarItem(
                id: "agent:\(key)", windowID: syntheticWindowID(for: key), hostPID: 0,
                hostBundleIdentifier: "com.apple.MenuBarAgent",
                semanticBundleIdentifier: "com.apple.menuextra.\(module.lowercased())",
                semanticIdentifier: key, rawTitle: module, displayName: moduleDisplayName(module),
                symbolName: moduleSymbolName(module),
                frame: CGRect(x: position, y: 0, width: 1, height: 24),
                isProtected: false
            )
        }
        return nil
    }

    private static func displayName(from bundleID: String) -> String {
        let component = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return component.replacingOccurrences(of: "-", with: " ")
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

    private static func symbolName(for bundleID: String, itemID: String) -> String {
        if bundleID == "com.microsoft.OneDrive" { return "cloud.fill" }
        if itemID.localizedCaseInsensitiveContains("siri") { return "waveform.circle.fill" }
        let known: [String: String] = [
            "com.apple.Spotlight": "magnifyingglass",
            "com.apple.TextInputMenuAgent": "character.cursor.ibeam",
            "com.apple.systemuiserver": "waveform.circle.fill",
        ]
        return known[bundleID] ?? "app.dashed"
    }

    /// Keeps the existing model's per-item indexing intact without pretending
    /// these identifiers are usable WindowServer window numbers.
    private static func syntheticWindowID(for key: String) -> CGWindowID {
        var value: UInt32 = 2_166_136_261
        for byte in key.utf8 {
            value = (value ^ UInt32(byte)) &* 16_777_619
        }
        return value | 0x8000_0000
    }
}

final class MenuBarAgentVisibilityController {
    enum ApplyResult { case applied, unavailable, failed(String) }
    private var assertion: NSObject?
    private var generation: UInt64 = 0
    private let lock = NSLock()

    deinit { invalidate() }

    func apply(
        allowedSystemItems: Set<Int>,
        allowedBundleIdentifiers: Set<String>,
        completion: @escaping (ApplyResult) -> Void
    ) {
        guard MenuBarAgentBridge.isAvailable else { completion(.unavailable); return }
        guard dlopen(MenuBarAgentBridge.frameworkPath, RTLD_NOW) != nil,
              let configurationClass = NSClassFromString("MBAssessmentModeConfiguration") as? NSObject.Type,
              let assertionClass = NSClassFromString("MBAssessmentModeAssertion") as? NSObject.Type
        else { completion(.unavailable); return }

        guard let configuration = class_createInstance(configurationClass, 0) as AnyObject? else {
            completion(.failed("configuration allocation failed")); return
        }
        let configSelector = NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")
        typealias ConfigIMP = @convention(c) (AnyObject, Selector, NSArray, NSArray) -> AnyObject?
        guard let configMethod = class_getInstanceMethod(configurationClass, configSelector) else {
            completion(.unavailable); return
        }
        let configured = unsafeBitCast(method_getImplementation(configMethod), to: ConfigIMP.self)(
            configuration, configSelector, allowedSystemItems.sorted().map(NSNumber.init(value:)) as NSArray,
            allowedBundleIdentifiers.sorted() as NSArray
        )
        guard let configured else { completion(.failed("configuration rejected")); return }

        let candidate = assertionClass.init()
        lock.lock()
        generation &+= 1
        let requestGeneration = generation
        lock.unlock()
        let activateSelector = NSSelectorFromString("activateWithConfiguration:completionHandler:")
        typealias CompletionBlock = @convention(block) (NSError?) -> Void
        typealias ActivateIMP = @convention(c) (AnyObject, Selector, AnyObject, CompletionBlock) -> Void
        guard let activateMethod = class_getInstanceMethod(assertionClass, activateSelector) else {
            completion(.unavailable); return
        }
        let activate = unsafeBitCast(method_getImplementation(activateMethod), to: ActivateIMP.self)
        let callback: CompletionBlock = { [weak self] error in
            guard let self else { return }
            self.lock.lock()
            let isCurrent = self.generation == requestGeneration
            if !isCurrent {
                self.lock.unlock()
                Self.invalidate(candidate)
                return
            }
            if let error {
                self.lock.unlock()
                completion(.failed(error.localizedDescription))
                return
            }
            let previous = self.assertion
            self.assertion = candidate
            self.lock.unlock()
            Self.invalidate(previous)
            completion(.applied)
        }
        activate(candidate, activateSelector, configured, callback)
    }

    func invalidate() {
        lock.lock()
        generation &+= 1
        let current = assertion
        assertion = nil
        lock.unlock()
        Self.invalidate(current)
    }

    private static func invalidate(_ object: NSObject?) {
        guard let object else { return }
        let selector = NSSelectorFromString("invalidate")
        guard let method = class_getInstanceMethod(type(of: object), selector) else { return }
        typealias InvalidateIMP = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(method_getImplementation(method), to: InvalidateIMP.self)(object, selector)
    }
}
