import AppKit
import SwiftUI

private final class OpenBarWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class OpenBarHostingView<Content: View>: NSHostingView<Content> {
    // Borderless accessory windows can otherwise consume the first click only
    // to become key, making every control appear unresponsive after launch.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
    private var windowDragMonitor: Any?
    private var dragStartScreenPoint: NSPoint?
    private var dragStartWindowOrigin: NSPoint?

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateDuplicateInstances()
        AppModel.shared.start { [weak self] in self?.showWindow() }
        showWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let windowDragMonitor {
            NSEvent.removeMonitor(windowDragMonitor)
            self.windowDragMonitor = nil
        }
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
                // Keep the surface borderless, but explicitly opt into the
                // window capabilities used by our in-surface traffic lights.
                // A borderless window otherwise reports itself as neither
                // closable nor miniaturizable, making those actions no-ops.
                styleMask: [.borderless, .resizable, .closable, .miniaturizable],
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
            // Window movement is handled only by the dedicated top strip in
            // OpenBarContentView; never let clicks on content drag the window.
            created.isMovableByWindowBackground = false
            created.collectionBehavior = [.managed, .moveToActiveSpace]
            created.isReleasedWhenClosed = false
            created.minSize = NSSize(width: 760, height: 560)
            created.contentView = OpenBarHostingView(rootView: content)
            configureWindowSurface(created)
            created.center()
            window = created
            installWindowDragMonitor(for: created)
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

    private func installWindowDragMonitor(for window: NSWindow) {
        windowDragMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self, weak window] event in
            guard let self, let window, event.window === window else { return event }

            let contentHeight = window.contentView?.bounds.height ?? window.frame.height
            let point = event.locationInWindow
            let isTopDragArea = point.x >= 84 && point.y >= contentHeight - 28

            switch event.type {
            case .leftMouseDown where isTopDragArea:
                self.dragStartScreenPoint = window.convertPoint(toScreen: point)
                self.dragStartWindowOrigin = window.frame.origin
                NSCursor.closedHand.push()
                return nil
            case .leftMouseDragged where self.dragStartScreenPoint != nil:
                guard let startPoint = self.dragStartScreenPoint,
                      let startOrigin = self.dragStartWindowOrigin
                else { return nil }
                let currentPoint = window.convertPoint(toScreen: point)
                window.setFrameOrigin(NSPoint(
                    x: startOrigin.x + currentPoint.x - startPoint.x,
                    y: startOrigin.y + currentPoint.y - startPoint.y
                ))
                return nil
            case .leftMouseUp where self.dragStartScreenPoint != nil:
                self.dragStartScreenPoint = nil
                self.dragStartWindowOrigin = nil
                NSCursor.pop()
                return nil
            default:
                return event
            }
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
