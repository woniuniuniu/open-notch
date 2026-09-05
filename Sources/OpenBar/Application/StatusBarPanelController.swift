import AppKit
import SwiftUI

private final class QuickBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class StatusBarPanelController: NSObject, NSWindowDelegate {
    private let panel: QuickBarPanel
    private let model: AppModel
    private let onVisibilityChanged: (Bool) -> Void
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init(model: AppModel, onVisibilityChanged: @escaping (Bool) -> Void) {
        self.model = model
        self.onVisibilityChanged = onVisibilityChanged
        panel = QuickBarPanel(contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.contentView = NSHostingView(rootView: QuickBarView()
            .environmentObject(model).environmentObject(PolicyStore.shared))
        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
    }

    func show(anchor: CGRect?) {
        guard let anchor else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        guard let screen else { return }
        let count = model.quickBarItems.filter {
            $0.isRunning && PolicyStore.shared.section(for: $0.id) == .hidden
                && $0.id != StatusBarController.toggleID
        }.count
        let width = min(max(180, CGFloat(count * 32 + 16)), screen.frame.width - 24)
        let x = max(screen.frame.minX + 12, min(anchor.midX - width / 2, screen.frame.maxX - width - 12))
        panel.setFrame(NSRect(x: x, y: anchor.minY - 60, width: width, height: 54), display: true)
        panel.makeKeyAndOrderFront(nil)
        onVisibilityChanged(true)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown && (event.keyCode == 53 || (event.keyCode == 13 && event.modifierFlags.contains(.command))) { self.hide(); return nil }
            if event.type != .keyDown && event.window !== self.panel { self.hide() }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    func hide() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        panel.orderOut(nil)
        onVisibilityChanged(false)
    }

    func windowDidResignKey(_ notification: Notification) { hide() }
    func windowWillClose(_ notification: Notification) { hide() }
}
