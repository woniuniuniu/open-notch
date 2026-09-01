import AppKit
import SwiftUI

private final class QuickBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class StatusBarPanelController: NSObject, NSWindowDelegate {
    private let panel: QuickBarPanel
    private let model: AppModel
    private let onVisibilityChanged: (Bool) -> Void

    init(
        model: AppModel,
        onVisibilityChanged: @escaping (Bool) -> Void
    ) {
        self.model = model
        self.onVisibilityChanged = onVisibilityChanged
        panel = QuickBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 54),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        let content = QuickBarView()
        .environmentObject(model)
        .environmentObject(PolicyStore.shared)

        panel.contentView = NSHostingView(rootView: content)
        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .none
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
    }

    func show() {
        let itemCount = model.quickBarItems.filter {
            $0.isRunning && PolicyStore.shared.section(for: $0.id) != .shown
        }.count
        guard itemCount > 0 else { return }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }

        let naturalWidth = CGFloat(itemCount * 42 + 16)
        let width = min(max(58, naturalWidth), visibleFrame.width - 24)
        let height = CGFloat(54)
        var x = pointer.x - width / 2
        x = max(visibleFrame.minX + 12, min(x, visibleFrame.maxX - width - 12))
        let y = visibleFrame.maxY - height - 6

        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        panel.orderFrontRegardless()
        onVisibilityChanged(true)
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        onVisibilityChanged(false)
    }

    func windowDidResignKey(_ notification: Notification) { hide() }
    func windowWillClose(_ notification: Notification) { onVisibilityChanged(false) }
}
