import AppKit
import ApplicationServices
import Foundation

struct SemanticMenuExtra {
    let bundleIdentifier: String
    let applicationName: String
    let identifier: String
    let title: String
    let description: String
    let frame: CGRect
}

enum AccessibilityResolver {
    static func isTrusted(prompt: Bool = false) -> Bool {
        guard prompt else { return AXIsProcessTrusted() }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func menuExtras() -> [SemanticMenuExtra] {
        guard AXIsProcessTrusted() else { return [] }

        var extras = [SemanticMenuExtra]()
        let excludedBundles: Set<String> = [
            Bundle.main.bundleIdentifier ?? "com.openbartender.OpenNotch",
        ]
        let requiredSystemAgents: Set<String> = [
            "com.apple.controlcenter",
            "com.apple.systemuiserver",
            "com.apple.TextInputMenuAgent",
            "com.apple.Spotlight",
        ]

        for app in NSWorkspace.shared.runningApplications {
            guard
                let bundleIdentifier = app.bundleIdentifier,
                !excludedBundles.contains(bundleIdentifier),
                app.activationPolicy != .prohibited || requiredSystemAgents.contains(bundleIdentifier)
            else { continue }

            let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(applicationElement, 0.12)
            for menuBar in children(of: applicationElement) where string(menuBar, kAXRoleAttribute as CFString) == kAXMenuBarRole {
                for element in children(of: menuBar) where string(element, kAXSubroleAttribute as CFString) == "AXMenuExtra" {
                    guard
                        let position = point(element, kAXPositionAttribute as CFString),
                        let size = size(element, kAXSizeAttribute as CFString),
                        size.width > 0,
                        size.height > 0,
                        position.y < 100
                    else { continue }

                    let identifier = string(element, kAXIdentifierAttribute as CFString)
                    let title = string(element, kAXTitleAttribute as CFString)
                    let description = string(element, kAXDescriptionAttribute as CFString)

                    // Tahoe can expose a blank Control Center container over the
                    // real third-party AX menu extra. It is not an item identity
                    // and must not win the geometric match.
                    if
                        bundleIdentifier == "com.apple.controlcenter",
                        identifier.isEmpty,
                        title.isEmpty,
                        description.isEmpty
                    {
                        continue
                    }

                    extras.append(SemanticMenuExtra(
                        bundleIdentifier: bundleIdentifier,
                        applicationName: app.localizedName ?? bundleIdentifier,
                        identifier: identifier,
                        title: title,
                        description: description,
                        frame: CGRect(origin: position, size: size)
                    ))
                }
            }
        }
        return extras
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
}
