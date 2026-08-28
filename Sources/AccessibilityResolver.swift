import AppKit
import ApplicationServices
import Foundation

struct SemanticMenuExtra {
    let hostPID: pid_t
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
            "com.apple.MenuBarAgent",
        ]

        for app in NSWorkspace.shared.runningApplications {
            guard
                let bundleIdentifier = app.bundleIdentifier,
                !excludedBundles.contains(bundleIdentifier),
                app.activationPolicy != .prohibited || requiredSystemAgents.contains(bundleIdentifier)
            else { continue }

            let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(applicationElement, 0.12)
            var menuBars = [AXUIElement]()
            var usesExtrasMenuBarAttribute = false
            if let extrasBar = value(applicationElement, "AXExtrasMenuBar" as CFString),
               CFGetTypeID(extrasBar) == AXUIElementGetTypeID()
            {
                menuBars.append(extrasBar as! AXUIElement)
                usesExtrasMenuBarAttribute = true
            } else {
                menuBars.append(contentsOf: children(of: applicationElement).filter {
                    string($0, kAXRoleAttribute as CFString) == kAXMenuBarRole
                })
            }

            for menuBar in menuBars {
                for element in children(of: menuBar) {
                    if !usesExtrasMenuBarAttribute,
                       string(element, kAXSubroleAttribute as CFString) != "AXMenuExtra"
                    {
                        continue
                    }
                    guard
                        let position = point(element, kAXPositionAttribute as CFString),
                        let size = size(element, kAXSizeAttribute as CFString),
                        size.width > 0,
                        size.height > 0,
                        position.y < 100
                    else { continue }

                    let descendants = children(of: element)
                    let identifier = firstNonEmpty(
                        string(element, kAXIdentifierAttribute as CFString),
                        descendants.lazy.map { string($0, kAXIdentifierAttribute as CFString) }.first { !$0.isEmpty }
                    )
                    let title = string(element, kAXTitleAttribute as CFString)
                    let description = firstNonEmpty(
                        string(element, kAXDescriptionAttribute as CFString),
                        descendants.lazy.map { string($0, kAXDescriptionAttribute as CFString) }.first { !$0.isEmpty }
                    )

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
                        hostPID: app.processIdentifier,
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
        return dropMenuBarAgentRevends(extras)
    }

    static func press(_ item: MenuBarItem) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: item.semanticBundleIdentifier
        )
        for application in applications {
            let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
            AXUIElementSetMessagingTimeout(applicationElement, 0.4)
            var bars = [AXUIElement]()
            if let extrasBar = value(applicationElement, "AXExtrasMenuBar" as CFString),
               CFGetTypeID(extrasBar) == AXUIElementGetTypeID()
            {
                bars = [extrasBar as! AXUIElement]
            } else {
                bars = children(of: applicationElement).filter {
                    string($0, kAXRoleAttribute as CFString) == kAXMenuBarRole
                }
            }

            let allCandidates = bars.flatMap(children)
            var candidates = allCandidates.filter { element in
                let descendants = children(of: element)
                let identifier = firstNonEmpty(
                    string(element, kAXIdentifierAttribute as CFString),
                    descendants.lazy.map { string($0, kAXIdentifierAttribute as CFString) }.first { !$0.isEmpty }
                )
                if !item.semanticIdentifier.isEmpty, identifier == item.semanticIdentifier { return true }
                guard let position = point(element, kAXPositionAttribute as CFString),
                      let size = size(element, kAXSizeAttribute as CFString)
                else { return false }
                let frame = CGRect(origin: position, size: size)
                return abs(frame.midX - item.frame.midX) <= 4 && abs(frame.midY - item.frame.midY) <= 4
            }
            if candidates.isEmpty,
               item.semanticIdentifier.isEmpty,
               item.frame == .zero,
               allCandidates.count == 1
            {
                candidates = allCandidates
            }
            for candidate in candidates {
                for element in children(of: candidate) + [candidate] {
                    if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                        return true
                    }
                }
            }
        }
        return false
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

    /// macOS 27 may publish a third-party item twice: once below its owning
    /// application and once below MenuBarAgent. Keep the directly attributed
    /// copy so identity remains stable across launches.
    private static func dropMenuBarAgentRevends(_ extras: [SemanticMenuExtra]) -> [SemanticMenuExtra] {
        let directFrames = extras
            .filter { $0.bundleIdentifier != "com.apple.MenuBarAgent" }
            .map(\.frame)
        return extras.filter { extra in
            guard extra.bundleIdentifier == "com.apple.MenuBarAgent" else { return true }
            return !directFrames.contains {
                abs($0.midX - extra.frame.midX) <= 2 && abs($0.midY - extra.frame.midY) <= 2
            }
        }
    }
}
