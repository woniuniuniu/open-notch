import AppKit
import Foundation
import ObjectiveC

/// Native macOS 27 inventory and visibility bridge. Symbols are resolved at
/// runtime so older macOS releases keep using the existing window-based path.
enum MenuBarAgentBridge {
    private static let domain = "com.apple.MenuBarAgent"
    private static let positionsKey = "TrailingItemPreferredPositions"
    static let frameworkPath = "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"
    static let enumerationName = "MenuBarAgent positions (experimental macOS 27)"

    static var isAvailable: Bool {
        // Private frameworks can live only in the dyld shared cache, so their
        // install-name path is loadable even when FileManager cannot see it.
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    static func items() -> [MenuBarItem] {
        guard isAvailable, let positions = positions() else { return [] }
        let extras = AccessibilityResolver.menuExtras()
        var result = positions.compactMap(makeItem).filter(isInstalledOrSystemItem).map { item in
            guard let extra = bestAccessibilityMatch(for: item, in: extras) else { return item }
            return replacingFrame(of: item, with: extra.frame)
        }
        if let ownItem = openNotchToggleItem(in: extras) {
            result.append(ownItem)
        }
        // A running status item can be absent from the preference dictionary
        // until MenuBarAgent has laid it out at least once. Keep every real AX
        // menu extra in the inventory so newly launched apps (for example
        // ChatGPT and FlClash) are never silently omitted from Settings.
        for (index, extra) in extras.enumerated()
        where extra.bundleIdentifier != "com.apple.weather.menu" && !isRepresented(extra, in: result) {
            let rawTitle = [extra.identifier, extra.title, extra.description]
                .first(where: { !$0.isEmpty }) ?? "Item-\(index)"
            let key = "status:\(extra.bundleIdentifier)::\(rawTitle)"
            let window = MenuBarDiscovery.closestStatusWindow(to: extra.frame)
            let pid = NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier == extra.bundleIdentifier
            }?.processIdentifier ?? window?.hostPID ?? 0
            result.append(MenuBarItem(
                id: "agent:\(key)", windowID: window?.windowID ?? syntheticWindowID(for: key),
                hostPID: pid, hostBundleIdentifier: extra.bundleIdentifier,
                semanticBundleIdentifier: extra.bundleIdentifier,
                semanticIdentifier: key, rawTitle: rawTitle,
                displayName: extra.applicationName,
                symbolName: symbolName(for: extra.bundleIdentifier, itemID: rawTitle),
                frame: extra.frame,
                isProtected: extra.bundleIdentifier == Bundle.main.bundleIdentifier
            ))
        }
        // Weather is an independent system status item on macOS 27 and is not
        // represented in TrailingItemPreferredPositions. Add its real AX item
        // so it can still be hidden and physically reordered like other extras.
        if !result.contains(where: { $0.semanticBundleIdentifier == "com.apple.weather.menu" }),
           let weather = extras.first(where: { $0.bundleIdentifier == "com.apple.weather.menu" }) {
            let key = "status:com.apple.weather.menu::Weather"
            let weatherWindow = MenuBarDiscovery.closestStatusWindow(to: weather.frame)
            let weatherPID = NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier == weather.bundleIdentifier
            }?.processIdentifier ?? weatherWindow?.hostPID ?? 0
            result.append(MenuBarItem(
                id: "agent:\(key)", windowID: weatherWindow?.windowID ?? syntheticWindowID(for: key),
                hostPID: weatherPID,
                hostBundleIdentifier: weather.bundleIdentifier,
                semanticBundleIdentifier: weather.bundleIdentifier,
                semanticIdentifier: key, rawTitle: weather.identifier.isEmpty ? "Weather" : weather.identifier,
                displayName: L("Weather"), symbolName: "cloud.sun.fill",
                frame: weather.frame, isProtected: false
            ))
        }
        return result.sorted { $0.frame.minX < $1.frame.minX }
    }

    private static func isRepresented(_ extra: SemanticMenuExtra, in items: [MenuBarItem]) -> Bool {
        items.contains { item in
            item.semanticBundleIdentifier == extra.bundleIdentifier
                && abs(item.frame.midX - extra.frame.midX) < 2
                && abs(item.frame.midY - extra.frame.midY) < 2
        }
    }

    private static func openNotchToggleItem(in extras: [SemanticMenuExtra]) -> MenuBarItem? {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.openbartender.OpenNotch"
        let extra = extras.first(where: {
            $0.bundleIdentifier == bundleID
                && ($0.identifier == "OpenNotch.Toggle"
                    || $0.title == "OpenNotch.Toggle"
                    || $0.description == "OpenNotch.Toggle")
        })
        let window = MenuBarDiscovery.statusWindows().first { $0.title == "OpenNotch.Toggle" }
        guard extra != nil || window != nil else { return nil }
        let key = "status:\(bundleID)::OpenNotch.Toggle"
        return MenuBarItem(
            id: "agent:\(key)", windowID: window?.windowID ?? syntheticWindowID(for: key),
            hostPID: window?.hostPID ?? ProcessInfo.processInfo.processIdentifier,
            hostBundleIdentifier: bundleID, semanticBundleIdentifier: bundleID,
            semanticIdentifier: key, rawTitle: "OpenNotch.Toggle",
            displayName: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Open Notch",
            symbolName: "menubar.rectangle", frame: extra?.frame ?? window!.frame, isProtected: false
        )
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
        guard let rawPositions = CFPreferencesCopyValue(
            positionsKey as CFString,
            domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String: Any] else { return nil }
        var result = [String: Double]()
        for (key, value) in rawPositions {
            if let number = value as? NSNumber { result[key] = number.doubleValue }
        }
        return result.isEmpty ? nil : result
    }

    static func preferredPosition(for key: String) -> Double? {
        positions()?[key]
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
        livePositions: [String: Double]
    ) -> Bool {
        guard
            isAvailable,
            sourceKey != targetKey,
            var current = positions()
        else { return false }
        // AX-only status items may not have reached this dictionary yet.
        // Seed only the two items participating in the move from their real
        // menu-bar coordinates. This makes the operation persistent without
        // posting Command-drag events into the global input stream.
        if current[sourceKey] == nil { current[sourceKey] = livePositions[sourceKey] }
        if current[targetKey] == nil { current[targetKey] = livePositions[targetKey] }
        guard current[sourceKey] != nil, current[targetKey] != nil else { return false }
        // Change only the dragged item. Reassigning every visible item's slot
        // mixes unrelated MenuBarAgent number ranges and can scramble the
        // entire bar. AppKit itself uses a small fractional offset to express
        // adjacency, which also leaves every other icon untouched.
        guard let targetPosition = current[targetKey] else { return false }
        current[sourceKey] = targetPosition + (placeAfterTarget ? 0.25 : -0.25)
        CFPreferencesSetValue(
            positionsKey as CFString,
            current as CFDictionary,
            domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        let synchronized = CFPreferencesSynchronize(
            domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        Diagnostics.shared.append(
            "MenuBarAgent reorder; source=\(sourceKey); target=\(targetKey); " +
            "after=\(placeAfterTarget); slot=\(current[sourceKey] ?? -1); " +
            "inputSynthesis=false; synchronized=\(synchronized)"
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
        CFPreferencesSetValue(
            positionsKey as CFString,
            current as CFDictionary,
            domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        let synchronized = CFPreferencesSynchronize(
            domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
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
                isProtected: false
            )
        }
        if key.hasPrefix("module:") {
            let module = String(key.dropFirst("module:".count))
            let names: [String: String] = [
                "AudioVideoModule": L("Control Center"), "Battery": L("Battery"),
                "BentoBox-0": L("Control Center"), "Clock": L("Clock"),
                "NowPlaying": L("Now Playing"), "ScreenMirroring": L("Screen Mirroring"),
                "Sound": L("Sound"), "WiFi": "Wi-Fi",
            ]
            let symbols: [String: String] = [
                "Battery": "battery.75percent", "Clock": "clock", "Sound": "speaker.wave.2.fill",
                "WiFi": "wifi", "NowPlaying": "play.circle", "ScreenMirroring": "rectangle.on.rectangle",
            ]
            return MenuBarItem(
                id: "agent:\(key)", windowID: syntheticWindowID(for: key), hostPID: 0,
                hostBundleIdentifier: "com.apple.MenuBarAgent",
                semanticBundleIdentifier: "com.apple.menuextra.\(module.lowercased())",
                semanticIdentifier: key, rawTitle: module, displayName: names[module] ?? module,
                symbolName: symbols[module] ?? "switch.2",
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

    private static func symbolName(for bundleID: String, itemID: String) -> String {
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
