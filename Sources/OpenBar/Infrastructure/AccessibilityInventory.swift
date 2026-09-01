import AppKit
import ApplicationServices
import Foundation
import OpenBarCore

struct AccessibilityMenuExtra {
    let hostPID: pid_t
    let bundleIdentifier: String
    let applicationName: String
    let identifier: String
    let title: String
    let detail: String
    let frame: CGRect
}

enum AccessibilityInventory {
    static func isTrusted(prompt: Bool = false) -> Bool {
        guard prompt else { return AXIsProcessTrusted() }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func menuExtras() -> [AccessibilityMenuExtra] {
        guard AXIsProcessTrusted() else { return [] }
        let ownBundle = Bundle.main.bundleIdentifier ?? "com.woniuniuniu.OpenBar"
        let requiredAgents: Set<String> = [
            "com.apple.controlcenter",
            "com.apple.systemuiserver",
            "com.apple.TextInputMenuAgent",
            "com.apple.Spotlight",
            "com.apple.MenuBarAgent",
        ]
        var result: [AccessibilityMenuExtra] = []

        for app in NSWorkspace.shared.runningApplications {
            guard let bundle = app.bundleIdentifier,
                  bundle != ownBundle,
                  app.activationPolicy != .prohibited || requiredAgents.contains(bundle)
            else { continue }

            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.1)
            var bars: [AXUIElement] = []
            var usesExtrasAttribute = false
            if let raw = value(application, "AXExtrasMenuBar" as CFString),
               CFGetTypeID(raw) == AXUIElementGetTypeID() {
                bars = [raw as! AXUIElement]
                usesExtrasAttribute = true
            } else {
                bars = children(of: application).filter {
                    string($0, kAXRoleAttribute as CFString) == kAXMenuBarRole
                }
            }

            for bar in bars {
                for element in children(of: bar) {
                    if !usesExtrasAttribute,
                       string(element, kAXSubroleAttribute as CFString) != "AXMenuExtra" {
                        continue
                    }
                    guard let position = point(element, kAXPositionAttribute as CFString),
                          let size = size(element, kAXSizeAttribute as CFString),
                          size.width > 0,
                          size.height > 0,
                          position.y < 100
                    else { continue }

                    let descendants = children(of: element)
                    let identifier = firstNonEmpty(
                        string(element, kAXIdentifierAttribute as CFString),
                        descendants.lazy.map { string($0, kAXIdentifierAttribute as CFString) }
                            .first { !$0.isEmpty }
                    )
                    let title = string(element, kAXTitleAttribute as CFString)
                    let detail = firstNonEmpty(
                        string(element, kAXDescriptionAttribute as CFString),
                        descendants.lazy.map { string($0, kAXDescriptionAttribute as CFString) }
                            .first { !$0.isEmpty }
                    )
                    if bundle == "com.apple.controlcenter",
                       identifier.isEmpty, title.isEmpty, detail.isEmpty {
                        continue
                    }
                    result.append(.init(
                        hostPID: app.processIdentifier,
                        bundleIdentifier: bundle,
                        applicationName: app.localizedName ?? bundle,
                        identifier: identifier,
                        title: title,
                        detail: detail,
                        frame: CGRect(origin: position, size: size)
                    ))
                }
            }
        }
        return removeMenuBarAgentDuplicates(result)
    }

    /// Returns the complete left-to-right frame sequence exposed by macOS 27's
    /// MenuBarAgent. The agent owns the hosting windows for both third-party
    /// status items and system modules, so this is the authoritative ordering
    /// skeleton when individual apps do not expose a semantic AX element.
    static func menuBarAgentFrames() -> [CGRect] {
        guard AXIsProcessTrusted() else { return [] }
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.MenuBarAgent"
        }) else { return [] }

        let application = AXUIElementCreateApplication(app.processIdentifier)
        let windows = children(of: application).filter {
            string($0, kAXRoleAttribute as CFString) == kAXWindowRole
        }

        var frames: [CGRect] = []
        for window in windows {
            for child in children(of: window) {
                guard let position = point(child, kAXPositionAttribute as CFString),
                      let size = size(child, kAXSizeAttribute as CFString),
                      size.width > 0,
                      size.height > 0,
                      position.y < 100
                else { continue }
                frames.append(CGRect(origin: position, size: size))
            }
        }

        // MenuBarAgent currently exposes two mirrored hosting windows. De-dupe
        // their children by geometry, then sort once more for deterministic
        // left-to-right output.
        var unique: [CGRect] = []
        for frame in frames.sorted(by: { $0.minX < $1.minX }) {
            guard !unique.contains(where: { sameFrame($0, frame) }) else { continue }
            unique.append(frame)
        }
        return unique
    }

    private static func removeMenuBarAgentDuplicates(
        _ extras: [AccessibilityMenuExtra]
    ) -> [AccessibilityMenuExtra] {
        let directFrames = extras.filter { $0.bundleIdentifier != "com.apple.MenuBarAgent" }.map(\.frame)
        return extras.filter { extra in
            guard extra.bundleIdentifier == "com.apple.MenuBarAgent" else { return true }
            return !directFrames.contains {
                abs($0.midX - extra.frame.midX) <= 2 && abs($0.midY - extra.frame.midY) <= 2
            }
        }
    }

    private static func sameFrame(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 2
            && abs(lhs.minY - rhs.minY) <= 2
            && abs(lhs.width - rhs.width) <= 2
            && abs(lhs.height - rhs.height) <= 2
    }

    private static func value(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &result) == .success else { return nil }
        return result
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: CFString) -> String {
        value(element, attribute) as? String ?? ""
    }

    private static func point(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
        guard let raw = value(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var result = CGPoint.zero
        guard AXValueGetValue(raw as! AXValue, .cgPoint, &result) else { return nil }
        return result
    }

    private static func size(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
        guard let raw = value(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var result = CGSize.zero
        guard AXValueGetValue(raw as! AXValue, .cgSize, &result) else { return nil }
        return result
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        values.compactMap { $0 }.first { !$0.isEmpty } ?? ""
    }
}

enum MenuBarItemPresentation {
    static func name(bundle: String, appName: String, title: String, identifier: String) -> String {
        if bundle == "com.microsoft.OneDrive" { return "OneDrive" }
        if bundle == "com.apple.controlcenter", let module = moduleName(identifier + " " + title) {
            return moduleDisplayName(module)
        }
        if !appName.isEmpty, !appName.hasPrefix("com.apple.") { return appName }
        if !title.isEmpty { return title }
        if !identifier.isEmpty { return identifier }
        return bundle
    }

    static func symbol(bundle: String, identifier: String, title: String = "") -> String {
        let normalizedBundle = bundle.lowercased()
        let haystack = (bundle + " " + identifier + " " + title)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()

        let isSystemBundle = normalizedBundle.hasPrefix("com.apple.")
            || normalizedBundle.hasPrefix("module:")
        if isSystemBundle,
           let module = moduleName(identifier + " " + title + " " + bundle) {
            return moduleSymbol(module)
        }
        if normalizedBundle == "com.apple.textinputmenuagent" || haystack.contains("inputmenu") {
            return "keyboard"
        }
        if normalizedBundle == "com.apple.spotlight" || haystack.contains("spotlight") {
            return "magnifyingglass"
        }
        if normalizedBundle == "com.apple.campo" || haystack.contains("siri") {
            return "waveform"
        }
        if haystack.contains("onedrive") || haystack.contains("icloud") { return "cloud" }
        if haystack.contains("dropbox") { return "shippingbox" }
        if haystack.contains("wifi") { return "wifi" }
        if haystack.contains("battery") { return "battery.75percent" }
        if haystack.contains("clock") { return "clock" }
        if haystack.contains("sound") || haystack.contains("audio") { return "speaker.wave.2" }
        if haystack.contains("bluetooth") { return "antenna.radiowaves.left.and.right" }
        if haystack.contains("vpn") { return "network.badge.shield.half.filled" }
        if haystack.contains("controlcenter") || haystack.contains("bentobox") { return "switch.2" }
        if haystack.contains("screenmirroring") { return "rectangle.on.rectangle" }
        if haystack.contains("nowplaying") { return "play.circle" }
        if normalizedBundle == "com.apple.systemuiserver" { return "menubar.rectangle" }
        return "square.grid.2x2"
    }

    static func moduleName(_ raw: String) -> String? {
        let value = raw
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        let compact = value
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        let matches: [(String, String)] = [
            ("screenmirroring", "ScreenMirroring"), ("屏幕镜像", "ScreenMirroring"),
            ("nowplaying", "NowPlaying"), ("正在播放", "NowPlaying"), ("现在播放", "NowPlaying"),
            ("bentobox0", "BentoBox"), ("bentobox", "BentoBox"),
            ("controlcenter", "BentoBox"), ("控制中心", "BentoBox"),
            ("wi-fi", "WiFi"), ("wifi", "WiFi"), ("wirelesslan", "WiFi"),
            ("无线局域网", "WiFi"), ("无线网络", "WiFi"),
            ("battery", "Battery"), ("电池", "Battery"),
            ("bluetooth", "Bluetooth"), ("蓝牙", "Bluetooth"),
            ("clock", "Clock"), ("时钟", "Clock"),
            ("sound", "Sound"), ("volume", "Sound"), ("audio", "AudioVideoModule"),
            ("声音", "Sound"), ("音量", "Sound"), ("音频", "AudioVideoModule"),
            ("display", "Display"), ("显示器", "Display"), ("显示", "Display"),
            ("keyboard", "Keyboard"), ("键盘", "Keyboard"),
        ]
        return matches.first {
            value.contains($0.0) || compact.contains($0.0.replacingOccurrences(of: "-", with: ""))
        }?.1
    }

    static func moduleSymbol(_ module: String) -> String {
        switch module {
        case "Battery": return "battery.75percent"
        case "WiFi": return "wifi"
        case "Bluetooth": return "antenna.radiowaves.left.and.right"
        case "Clock": return "clock"
        case "Sound", "AudioVideoModule": return "speaker.wave.2"
        case "ScreenMirroring": return "rectangle.on.rectangle"
        case "NowPlaying": return "play.circle"
        case "Display": return "display"
        case "Keyboard": return "keyboard"
        case "BentoBox", "BentoBox-0": return "switch.2"
        default: return "square.grid.2x2"
        }
    }

    static func moduleDisplayName(_ module: String) -> String {
        switch module {
        case "Battery": L("Battery")
        case "Clock": L("Clock")
        case "Sound": L("Sound")
        case "WiFi": L("Wi-Fi")
        case "Bluetooth": L("Bluetooth")
        case "NowPlaying": L("Now Playing")
        case "ScreenMirroring": L("Screen Mirroring")
        case "Display": L("Display")
        case "Keyboard": L("Keyboard")
        case "BentoBox", "BentoBox-0", "AudioVideoModule": L("Control Center")
        default: module
        }
    }
}
