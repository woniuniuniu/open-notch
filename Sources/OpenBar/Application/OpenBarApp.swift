import AppKit
import SwiftUI

private final class OpenBarWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class OpenBarHostingView<Content: View>: NSHostingView<Content> {
    // Borderless windows do not get the normal titlebar drag region. Let
    // unhandled content areas move the window while SwiftUI controls keep
    // receiving their own mouse events.
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Some SwiftUI hosting configurations do not consult
        // mouseDownCanMoveWindow for a borderless window. Explicitly forward
        // background clicks to AppKit's native window drag implementation.
        if event.clickCount == 1, let window {
            window.performDrag(with: event)
            return
        }
        super.mouseDown(with: event)
    }
}

@main
enum OpenBarApplication {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateDuplicateInstances()
        AppModel.shared.start { [weak self] in self?.showWindow() }
        showWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showWindow()
        return true
    }

    private func showWindow() {
        if window == nil {
            let content = RootView()
                .environmentObject(AppModel.shared)
                .environmentObject(PolicyStore.shared)
            let created = OpenBarWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                styleMask: [.borderless, .resizable],
                backing: .buffered,
                defer: false
            )
            created.identifier = NSUserInterfaceItemIdentifier("OpenBar.Main")
            created.title = "OPEN BAR"
            // Let the SwiftUI visual-effect background show the desktop
            // through the window. An opaque background here defeats the
            // material and turns the whole app into a flat white rectangle.
            created.isOpaque = false
            created.backgroundColor = .clear
            created.hasShadow = true
            created.isMovableByWindowBackground = true
            created.collectionBehavior = [.managed, .moveToActiveSpace]
            created.isReleasedWhenClosed = false
            created.minSize = NSSize(width: 760, height: 560)
            created.contentView = OpenBarHostingView(rootView: content)
            configureWindowSurface(created)
            created.center()
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            keepWindowOnScreen(window)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    private func keepWindowOnScreen(_ window: NSWindow) {
        let currentFrame = window.frame
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(currentFrame) })
            ?? NSScreen.main
        guard let screen else { return }

        let visible = screen.visibleFrame.insetBy(dx: 20, dy: 20)
        var frame = currentFrame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: false)
    }

    private func configureWindowSurface(_ window: NSWindow) {
        // With a full-size content view, the hosting view owns the entire
        // window frame. Apply the same corner radius to the content and its
        // theme-frame parent so the native traffic lights sit inside the
        // clipped glass surface instead of above a rectangular layer.
        for view in [window.contentView, window.contentView?.superview].compactMap({ $0 }) {
            view.wantsLayer = true
            view.layer?.cornerRadius = OpenBarTheme.windowCorner
            view.layer?.masksToBounds = true
            view.layer?.backgroundColor = NSColor.clear.cgColor
        }

    }

    private func terminateDuplicateInstances() {
        guard let bundle = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        for application in NSWorkspace.shared.runningApplications
        where application.bundleIdentifier == bundle && application.processIdentifier != currentPID {
            application.terminate()
        }
    }
}
