import AppKit
import CoreGraphics
import Foundation
import OpenBarCore

@MainActor
final class LegacySectionController {
    @MainActor
    private final class Boundary {
        let item: NSStatusItem
        private var widthConstraint: NSLayoutConstraint?

        init(autosaveName: String, position: Double) {
            UserDefaults.standard.set(position, forKey: "NSStatusItem Preferred Position \(autosaveName)")
            item = NSStatusBar.system.statusItem(withLength: 0)
            item.autosaveName = autosaveName
            if let button = item.button {
                button.image = nil
                button.title = ""
                button.alphaValue = 0
                button.isEnabled = false
                button.setAccessibilityIdentifier(autosaveName)
            }
            captureConstraint()
        }

        var windowID: CGWindowID? {
            guard let number = item.button?.window?.windowNumber, number > 0 else { return nil }
            return CGWindowID(number)
        }

        var frame: CGRect? {
            guard let window = item.button?.window, let screen = window.screen else { return nil }
            let cocoa = window.frame
            return CGRect(
                x: cocoa.minX,
                y: screen.frame.maxY - cocoa.maxY,
                width: cocoa.width,
                height: cocoa.height
            )
        }

        func setWide(_ wide: Bool) {
            if widthConstraint == nil { captureConstraint() }
            if wide {
                item.length = 10_000
                widthConstraint?.isActive = true
            } else {
                widthConstraint?.isActive = false
                item.length = 0
                item.button?.window?.setContentSize(NSSize(width: 1, height: item.button?.window?.frame.height ?? 24))
            }
        }

        private func captureConstraint() {
            guard let button = item.button,
                  let constraints = button.window?.contentView?.constraintsAffectingLayout(for: .horizontal)
            else { return }
            widthConstraint = constraints.first { $0.secondItem === button.superview }
        }
    }

    private let hiddenBoundary = Boundary(autosaveName: "OpenBar.HiddenBoundary", position: 1)
    private let alwaysBoundary = Boundary(autosaveName: "OpenBar.AlwaysHiddenBoundary", position: 2)

    var excludedWindowIDs: Set<CGWindowID> {
        Set([hiddenBoundary.windowID, alwaysBoundary.windowID].compactMap { $0 })
    }

    var hiddenBoundaryWindow: RawStatusWindow? { rawWindow(for: hiddenBoundary) }
    var alwaysBoundaryWindow: RawStatusWindow? { rawWindow(for: alwaysBoundary) }

    init() {
        setExpanded(false)
    }

    func setExpanded(_ expanded: Bool) {
        hiddenBoundary.setWide(!expanded)
        alwaysBoundary.setWide(expanded)
    }

    func prepareForMovement() {
        hiddenBoundary.setWide(false)
        alwaysBoundary.setWide(false)
    }

    func actualSection(for frame: CGRect) -> ItemSection? {
        guard let hidden = hiddenBoundary.frame, let always = alwaysBoundary.frame else { return nil }
        if frame.midX >= hidden.maxX - 2 { return .shown }
        if frame.midX >= always.maxX - 2 { return .hidden }
        return .alwaysHidden
    }

    func boundary(for section: ItemSection) -> RawStatusWindow? {
        switch section {
        case .shown, .hidden: hiddenBoundaryWindow
        case .alwaysHidden: alwaysBoundaryWindow
        }
    }

    private func rawWindow(for boundary: Boundary) -> RawStatusWindow? {
        guard let id = boundary.windowID, let frame = boundary.frame else { return nil }
        return RawStatusWindow(
            windowID: id,
            hostPID: ProcessInfo.processInfo.processIdentifier,
            hostName: "OPEN BAR",
            hostBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.woniuniuniu.OpenBar",
            title: "Boundary",
            frame: frame
        )
    }
}
