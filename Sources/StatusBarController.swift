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

    var onToggle: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onToggleGuardian: (() -> Void)?
    var onRestart: (() -> Void)?

    override init() {
        let defaults = UserDefaults.standard
        let toggleKey = "NSStatusItem Preferred Position \(AutosaveName.toggle)"
        let boundaryKey = "NSStatusItem Preferred Position \(AutosaveName.boundary)"
        // A second menu bar manager can persist a new position for these control
        // items. Reassert their adjacent order before AppKit recreates them.
        defaults.set(0.0, forKey: toggleKey)
        defaults.set(1.0, forKey: boundaryKey)

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

    func setExpanded(_ expanded: Bool) {
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
        toggleItem.button?.toolTip = "Open Notch"
    }

    func updateMenu(isExpanded: Bool, guardianEnabled: Bool, hasAccessibilityPermission: Bool) {
        let menu = NSMenu(title: "Open Notch")
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

        let guardianItem = NSMenuItem(
            title: L("Keep OneDrive Pinned"),
            action: #selector(toggleGuardianFromMenu),
            keyEquivalent: ""
        )
        guardianItem.target = self
        guardianItem.state = guardianEnabled ? .on : .off
        guardianItem.isEnabled = true
        menu.addItem(guardianItem)

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
        button.setAccessibilityLabel("Open Notch")
        button.toolTip = "Open Notch"
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

    @objc private func toggleFromMenu() { onToggle?() }
    @objc private func toggleGuardianFromMenu() { onToggleGuardian?() }
    @objc private func refreshFromMenu() { onRefresh?() }
    @objc private func openSettingsFromMenu() { onOpenSettings?() }
    @objc private func restart() { onRestart?() }
    @objc private func quit() { NSApp.terminate(nil) }
}
