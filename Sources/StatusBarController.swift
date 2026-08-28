import AppKit
import Foundation

@MainActor
final class StatusBarController: NSObject {
    private enum AutosaveName {
        static let toggle = "OpenNotch.Toggle"
        static let boundary = "OpenNotch.HiddenBoundary"
    }

    private let toggleItem: NSStatusItem
    private let boundaryItem: NSStatusItem
    private var boundaryWidthConstraint: NSLayoutConstraint?
    private var menu: NSMenu?
    private var positionRefreshGeneration: UInt64 = 0

    var onToggle: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onRestart: (() -> Void)?
    var onExportDebug: (() -> Void)?

    override init() {
        if !PlatformVersion.isMacOS27OrNewer {
            let defaults = UserDefaults.standard
            let toggleKey = "NSStatusItem Preferred Position \(AutosaveName.toggle)"
            let boundaryKey = "NSStatusItem Preferred Position \(AutosaveName.boundary)"
            // Legacy hiding relies on these two control items remaining
            // adjacent. macOS 27 preserves the user's chosen toggle position.
            defaults.set(0.0, forKey: toggleKey)
            defaults.set(1.0, forKey: boundaryKey)
        }

        boundaryItem = NSStatusBar.system.statusItem(withLength: 0)
        toggleItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        boundaryItem.autosaveName = AutosaveName.boundary
        toggleItem.autosaveName = AutosaveName.toggle
        configureBoundary()
        configureToggle()
        captureBoundaryWidthConstraint()
    }

    var excludedWindowIDs: Set<CGWindowID> {
        Set([boundaryWindowID, toggleWindowID].compactMap { $0 })
    }

    var boundaryWindowID: CGWindowID? {
        rawWindow(for: boundaryItem)?.windowID
    }

    var toggleWindowID: CGWindowID? {
        rawWindow(for: toggleItem)?.windowID
    }

    var toggleMenuBarItem: MenuBarItem? {
        let raw = rawWindow(for: toggleItem)
        let detectedFrame = raw?.frame ?? statusItemFrame(for: toggleItem)
        let frame = (detectedFrame?.width ?? 0) > 1 ? detectedFrame! : estimatedToggleFrame
        let bundleID = Bundle.main.bundleIdentifier ?? "com.openbartender.OpenNotch"
        let key = "status:\(bundleID)::OpenNotch.Toggle"
        return MenuBarItem(
            id: "agent:\(key)", windowID: raw?.windowID ?? 0,
            hostPID: raw?.hostPID ?? ProcessInfo.processInfo.processIdentifier,
            hostBundleIdentifier: bundleID, semanticBundleIdentifier: bundleID,
            semanticIdentifier: key, rawTitle: "OpenNotch.Toggle",
            displayName: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Open Notch",
            symbolName: "menubar.rectangle", frame: frame, isProtected: false
        )
    }

    private var estimatedToggleFrame: CGRect {
        let screen = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGRect(x: screen.maxX - 220, y: 0, width: 24, height: 24)
    }

    func setExpanded(_ expanded: Bool) {
        // macOS 27 hides items through MenuBarAgent. A wide transparent
        // boundary window is unnecessary there and can intercept clicks meant
        // for Wi-Fi, Battery, and other system items.
        if PlatformVersion.isMacOS27OrNewer {
            boundaryWidthConstraint?.isActive = false
            boundaryItem.length = 0
            if let window = boundaryItem.button?.window {
                window.setContentSize(NSSize(width: 1, height: window.frame.height))
                window.ignoresMouseEvents = true
            }
            toggleItem.button?.contentTintColor = nil
            toggleItem.button?.toolTip = L("App Name")
            return
        }

        if expanded {
            boundaryItem.length = 0
            boundaryWidthConstraint?.isActive = false
            if let window = boundaryItem.button?.window {
                window.setContentSize(NSSize(width: 1, height: window.frame.height))
            }
        } else {
            boundaryWidthConstraint?.isActive = true
            boundaryItem.length = 10_000
        }

        // Template images are tinted by the menu bar, independently of the
        // appearance selected for the settings window.
        toggleItem.button?.contentTintColor = nil
        toggleItem.button?.toolTip = L("App Name")
    }

    /// Ask MenuBarAgent to consume newly saved preferred positions without
    /// restarting it or synthesizing pointer events. This compositor-preserving
    /// status-item length nudge follows Thaw's GPL-3.0-only ControlItem approach.
    func requestMenuBarPositionRefresh() {
        positionRefreshGeneration &+= 1
        let generation = positionRefreshGeneration
        let baseline = toggleItem.length

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.positionRefreshGeneration == generation else { return }
            let renderedWidth = self.toggleItem.button?.bounds.width ?? 0
            guard renderedWidth > 0 else { return }
            let temporaryLength: CGFloat
            if baseline == NSStatusItem.variableLength {
                temporaryLength = max(1, renderedWidth)
            } else if abs(baseline - renderedWidth) < 0.5 {
                temporaryLength = renderedWidth + 1
            } else {
                temporaryLength = renderedWidth
            }
            self.toggleItem.length = temporaryLength
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
                guard let self, self.positionRefreshGeneration == generation else { return }
                self.toggleItem.length = baseline
            }
        }
    }

    /// Persists the Open Notch status item next to an item that has a native
    /// MenuBarAgent slot. This path never posts mouse events.
    func moveToggle(adjacentTo item: MenuBarItem, placeAfter: Bool) -> Bool {
        guard let target = MenuBarAgentBridge.preferredPosition(for: item.semanticIdentifier) else {
            return false
        }
        let key = "NSStatusItem Preferred Position \(AutosaveName.toggle)"
        UserDefaults.standard.set(target + (placeAfter ? 0.25 : -0.25), forKey: key)
        toggleItem.autosaveName = nil
        toggleItem.autosaveName = AutosaveName.toggle
        requestMenuBarPositionRefresh()
        return true
    }

    func updateMenu(isExpanded: Bool, hasAccessibilityPermission: Bool) {
        let menu = NSMenu(title: L("App Name"))
        menu.autoenablesItems = false

        let titleItem = NSMenuItem(title: L("Status Menu Title"), action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let permissionItem = NSMenuItem(
            title: hasAccessibilityPermission ? L("Accessibility access granted") : L("Accessibility access not granted"),
            action: nil,
            keyEquivalent: ""
        )
        permissionItem.image = NSImage(
            systemSymbolName: hasAccessibilityPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            accessibilityDescription: nil
        )
        permissionItem.isEnabled = false
        menu.addItem(permissionItem)
        menu.addItem(.separator())

        let visibilityItem = NSMenuItem(
            title: isExpanded ? L("Collapse Hidden Items") : L("Expand Hidden Items"),
            action: #selector(toggleFromMenu),
            keyEquivalent: ""
        )
        visibilityItem.target = self
        visibilityItem.image = NSImage(systemSymbolName: isExpanded ? "eye.slash" : "eye", accessibilityDescription: nil)
        visibilityItem.isEnabled = true
        menu.addItem(visibilityItem)

        let refreshItem = NSMenuItem(title: L("Scan Now"), action: #selector(refreshFromMenu), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.keyEquivalentModifierMask = .command
        refreshItem.isEnabled = true
        menu.addItem(refreshItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: L("Settings…"), action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.isEnabled = true
        menu.addItem(settingsItem)

        let debugItem = NSMenuItem(title: L("Export Debug Log"), action: #selector(exportDebug), keyEquivalent: "")
        debugItem.target = self
        debugItem.image = NSImage(systemSymbolName: "ladybug", accessibilityDescription: nil)
        debugItem.isEnabled = true
        menu.addItem(debugItem)

        let restartItem = NSMenuItem(title: L("Restart Open Notch"), action: #selector(restart), keyEquivalent: "")
        restartItem.target = self
        restartItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        restartItem.isEnabled = true
        menu.addItem(restartItem)

        let quitItem = NSMenuItem(title: L("Quit Open Notch"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        quitItem.keyEquivalentModifierMask = .command
        quitItem.isEnabled = true
        menu.addItem(quitItem)

        self.menu = menu
        toggleItem.menu = menu
    }

    private func configureBoundary() {
        guard let button = boundaryItem.button else { return }
        button.imagePosition = .imageOnly
        button.image = nil
        button.isEnabled = false
        button.alphaValue = 0
        button.setAccessibilityIdentifier("OpenNotch.HiddenBoundary")
        button.setAccessibilityLabel(L("Open Notch hidden-section boundary"))
    }

    private func configureToggle() {
        guard let button = toggleItem.button else { return }
        button.imagePosition = .imageOnly
        button.image = symbol("menubar.rectangle", pointSize: 14, weight: .semibold)
        button.setAccessibilityIdentifier("OpenNotch.Toggle")
        button.setAccessibilityLabel(L("App Name"))
        button.toolTip = L("App Name")
    }

    private func captureBoundaryWidthConstraint() {
        guard
            let button = boundaryItem.button,
            let constraints = button.window?.contentView?.constraintsAffectingLayout(for: .horizontal)
        else { return }
        boundaryWidthConstraint = constraints.first { $0.secondItem === button.superview }
    }

    private func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration) else { return nil }
        image.isTemplate = true
        return image
    }

    private func rawWindow(for item: NSStatusItem) -> RawStatusWindow? {
        let expectedTitle = item === boundaryItem ? "OpenNotch.HiddenBoundary" : "OpenNotch.Toggle"
        if let exactMatch = MenuBarDiscovery.statusWindows().first(where: { $0.title == expectedTitle }) {
            return exactMatch
        }

        guard
            let window = item.button?.window,
            let screen = window.screen,
            let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }

        let cocoaFrame = window.frame
        let displayBounds = CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
        let cgFrame = CGRect(
            x: displayBounds.minX + (cocoaFrame.minX - screen.frame.minX),
            y: displayBounds.minY + (screen.frame.maxY - cocoaFrame.maxY),
            width: cocoaFrame.width,
            height: cocoaFrame.height
        )
        return MenuBarDiscovery.closestStatusWindow(to: cgFrame)
    }

    private func statusItemFrame(for item: NSStatusItem) -> CGRect? {
        if let button = item.button {
            let accessibilityFrame = button.accessibilityFrame()
            if accessibilityFrame.width > 0, accessibilityFrame.height > 0,
               let screen = NSScreen.screens.first(where: { $0.frame.intersects(accessibilityFrame) }) {
                return CGRect(
                    x: accessibilityFrame.minX,
                    y: screen.frame.maxY - accessibilityFrame.maxY,
                    width: accessibilityFrame.width,
                    height: accessibilityFrame.height
                )
            }
        }
        guard
            let window = item.button?.window,
            let screen = window.screen,
            let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let cocoaFrame = window.frame
        let displayBounds = CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
        return CGRect(
            x: displayBounds.minX + (cocoaFrame.minX - screen.frame.minX),
            y: displayBounds.minY + (screen.frame.maxY - cocoaFrame.maxY),
            width: cocoaFrame.width,
            height: cocoaFrame.height
        )
    }

    @objc private func toggleFromMenu() { onToggle?() }
    @objc private func refreshFromMenu() { onRefresh?() }
    @objc private func openSettingsFromMenu() { onOpenSettings?() }
    @objc private func exportDebug() { onExportDebug?() }
    @objc private func restart() { onRestart?() }
    @objc private func quit() { NSApp.terminate(nil) }
}
