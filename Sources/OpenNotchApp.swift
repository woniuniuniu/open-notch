import AppKit
import SwiftUI

private final class SettingsHostingView<Content: View>: NSHostingView<Content> {
    @available(macOS 27.0, *)
    override var cornerConfiguration: NSViewCornerConfiguration? {
        .uniformCorners(radius: .containerConcentric(16))
    }

    override func layout() {
        super.layout()
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        if #available(macOS 27.0, *), let radii = effectiveCornerRadii {
            // The configuration is uniform; using the resolved system value
            // for the layer mask guarantees identical top and bottom corners.
            layer?.cornerRadius = radii.topLeft
        } else {
            layer?.cornerRadius = 16
        }
    }
}

@main
enum OpenNotchApplication {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(SettingsStore.shared.showInDock ? .regular : .accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateOtherInstances()
        SettingsStore.shared.applyAppearance()
        AppModel.shared.start { [weak self] in self?.showSettings() }
        showSettings()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func terminateOtherInstances() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleIdentifier && $0.processIdentifier != ownPID
        }
        for application in others {
            Diagnostics.shared.append("Terminating duplicate instance; pid=\(application.processIdentifier)")
            application.terminate()
        }
    }

    private func showSettings() {
        if settingsWindow == nil {
            let view = SettingsRootView().environmentObject(AppModel.shared)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 470, height: 650),
                // A titled window adds a second system mask to the two upper
                // corners. The app already supplies its own traffic lights and
                // chrome, so a borderless resizable window lets one uniform
                // four-corner mask define the entire settings window.
                styleMask: [.borderless, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = L("App Name")
            window.identifier = NSUserInterfaceItemIdentifier("OpenNotch.Settings")
            window.tabbingMode = .disallowed
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace]
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = true
            window.isMovableByWindowBackground = true
            window.minSize = NSSize(width: 470, height: 650)
            // Let macOS 27 own the standard window radius. A fixed CALayer
            // radius cannot follow the system's style-dependent window shape.
            // The new concentric configuration adapts the hosted content to
            // the effective system window corners.
            window.contentView = SettingsHostingView(rootView: view)
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.center()
            settingsWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
