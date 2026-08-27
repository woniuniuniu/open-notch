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
        return positions.compactMap(makeItem).sorted { $0.frame.minX < $1.frame.minX }
    }

    static func positions() -> [String: Double]? {
        guard
            let domainValues = UserDefaults.standard.persistentDomain(forName: domain),
            let rawPositions = domainValues[positionsKey] as? [String: Any]
        else { return nil }
        var result = [String: Double]()
        for (key, value) in rawPositions {
            if let number = value as? NSNumber { result[key] = number.doubleValue }
        }
        return result.isEmpty ? nil : result
    }

    /// Updates the preferred order without restarting MenuBarAgent. macOS 27
    /// consumes the preference during its next natural layout refresh; forcing
    /// that refresh by terminating the agent makes the entire menu bar blink.
    @MainActor
    static func moveItem(_ sourceKey: String, adjacentTo targetKey: String, placeAfterTarget: Bool) -> Bool {
        guard
            isAvailable,
            sourceKey.hasPrefix("status:"),
            targetKey.hasPrefix("status:"),
            sourceKey != targetKey,
            var current = positions(),
            current[sourceKey] != nil,
            current[targetKey] != nil
        else { return false }
        var orderedKeys = current.keys.sorted {
            let lhs = current[$0] ?? 0
            let rhs = current[$1] ?? 0
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }
        orderedKeys.removeAll { $0 == sourceKey }
        guard let targetIndex = orderedKeys.firstIndex(of: targetKey) else { return false }
        let insertionIndex = targetIndex + (placeAfterTarget ? 1 : 0)
        orderedKeys.insert(sourceKey, at: insertionIndex)
        let lower = insertionIndex > 0 ? current[orderedKeys[insertionIndex - 1]] : nil
        let upper = insertionIndex + 1 < orderedKeys.count ? current[orderedKeys[insertionIndex + 1]] : nil
        let newPosition: Double
        switch (lower, upper) {
        case let (lower?, upper?) where upper > lower:
            newPosition = lower + ((upper - lower) / 2)
        case let (lower?, upper?):
            newPosition = placeAfterTarget ? max(lower, upper) + 0.125 : min(lower, upper) - 0.125
        case let (nil, upper?):
            newPosition = upper - 16
        case let (lower?, nil):
            newPosition = lower + 16
        default:
            return false
        }
        current[sourceKey] = newPosition
        let suite = UserDefaults(suiteName: domain)
        suite?.set(current, forKey: positionsKey)
        let synchronized = suite?.synchronize() ?? false
        Diagnostics.shared.append(
            "MenuBarAgent reorder; source=\(sourceKey); target=\(targetKey); " +
            "after=\(placeAfterTarget); position=\(newPosition); synchronized=\(synchronized)"
        )
        return synchronized
    }

    @MainActor
    static func restorePosition(_ position: Double, for key: String) -> Bool {
        guard isAvailable, key.hasPrefix("status:"), var current = positions(), current[key] != nil else {
            return false
        }
        current[key] = position
        let suite = UserDefaults(suiteName: domain)
        suite?.set(current, forKey: positionsKey)
        let synchronized = suite?.synchronize() ?? false
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
