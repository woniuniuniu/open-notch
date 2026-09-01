import AppKit
import SwiftUI

private final class OpenBarWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class OpenBarDragStrip: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { self }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var dragStartScreenPoint: NSPoint?
    private var dragStartWindowOrigin: NSPoint?

    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown, let window else { return }
        dragStartScreenPoint = window.convertPoint(toScreen: event.locationInWindow)
        dragStartWindowOrigin = window.frame.origin
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window,
              let dragStartScreenPoint,
              let dragStartWindowOrigin
        else { return }
        let currentScreenPoint = window.convertPoint(toScreen: event.locationInWindow)
        let delta = NSPoint(
            x: currentScreenPoint.x - dragStartScreenPoint.x,
            y: currentScreenPoint.y - dragStartScreenPoint.y
        )
        window.setFrameOrigin(NSPoint(
            x: dragStartWindowOrigin.x + delta.x,
            y: dragStartWindowOrigin.y + delta.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        dragStartScreenPoint = nil
        dragStartWindowOrigin = nil
        NSCursor.pop()
    }
}

private final class OpenBarContentView: NSView {
    private let hosting: NSView
    private let dragStrip = OpenBarDragStrip()

    init<Content: View>(rootView: Content) {
        hosting = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        wantsLayer = true

        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // AppKit drag surface: only the top blank strip is intercepted. The
        // rest of the hosting view remains fully interactive for item drags.
        dragStrip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dragStrip, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            dragStrip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 84),
            dragStrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            dragStrip.topAnchor.constraint(equalTo: topAnchor),
            dragStrip.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
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
            // Window movement is handled only by the dedicated top strip in
            // OpenBarContentView; never let clicks on content drag the window.
            created.isMovableByWindowBackground = false
            created.collectionBehavior = [.managed, .moveToActiveSpace]
            created.isReleasedWhenClosed = false
            created.minSize = NSSize(width: 760, height: 560)
            created.contentView = OpenBarContentView(rootView: content)
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
