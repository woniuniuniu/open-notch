import AppKit
import OpenBarCore
import SwiftUI

struct HoverNamePopover: NSViewRepresentable {
    let title: String
    @Binding var isPresented: Bool

    func makeNSView(context: Context) -> HoverNamePopoverAnchor {
        HoverNamePopoverAnchor()
    }

    func updateNSView(_ view: HoverNamePopoverAnchor, context: Context) {
        view.title = title
        view.isPresented = isPresented
        view.updatePopover()
    }
}

final class HoverNamePopoverAnchor: NSView {
    var title = ""
    var isPresented = false
    private var popover: NSPopover?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The transparent anchor must never steal clicks or drag gestures from
        // the icon it is attached to.
        nil
    }

    func updatePopover() {
        guard isPresented else {
            popover?.performClose(nil)
            popover = nil
            return
        }
        guard window != nil else {
            DispatchQueue.main.async { [weak self] in self?.updatePopover() }
            return
        }
        guard popover?.isShown != true else { return }

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byClipping
        label.sizeToFit()

        let width = max(56, label.fittingSize.width + 20)
        let height: CGFloat = 30
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        label.frame = NSRect(x: 10, y: 7, width: width - 20, height: 16)
        content.addSubview(label)

        let controller = NSViewController()
        controller.view = content
        let next = NSPopover()
        next.behavior = .transient
        next.animates = true
        next.contentViewController = controller
        next.contentSize = NSSize(width: width, height: height)
        popover = next
        next.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }
}

enum OpenBarTheme {
    static let accent = Color(hex: "#5D9CFF")
    static let ai = accent
    static let shown = accent
    static let hidden = Color.primary.opacity(0.52)
    static let alwaysHidden = Color.primary.opacity(0.36)
    static let warning = Color(hex: "#E2B24D")
    static let success = Color(hex: "#5DD39E")
    static let danger = Color(hex: "#FF6B6B")

    // The window supplies the single glass layer. These colors are deliberately
    // translucent overlays so content still picks up the user's wallpaper.
    static let sidebarBackground = Color.primary.opacity(0.055)
    static let canvas = Color.clear
    static let appBackground = Color.clear
    static let rail = Color.primary.opacity(0.035)
    static let panel = Color.primary.opacity(0.055)
    static let panelHover = Color.primary.opacity(0.10)
    static let control = Color.primary.opacity(0.075)
    static let controlHover = Color.primary.opacity(0.13)
    static let selection = accent.opacity(0.20)
    static let raised = Color.primary.opacity(0.08)
    static let elevated = Color.primary.opacity(0.11)
    static let divider = Color.primary.opacity(0.12)
    static let glassStroke = Color.white.opacity(0.24)
    static let glassHighlight = Color.white.opacity(0.34)
    static let glassShadow = Color.clear
    static let contentWash = Color.primary.opacity(0.025)
    static let contentWashHovered = Color.primary.opacity(0.07)
    static let controlWash = control
    static let muted = Color.primary.opacity(0.56)
    static let label = Color.primary

    static func tint(for section: ItemSection) -> Color {
        switch section {
        case .shown: shown
        case .hidden: hidden
        case .alwaysHidden: alwaysHidden
        }
    }

    static let corner: CGFloat = 9
    static let windowCorner: CGFloat = 14
    static let sidebarWidth: CGFloat = 228
    static let toolbarHeight: CGFloat = 52
    static let rowHeight: CGFloat = 38
    static let iconColumn: CGFloat = 20
    static let laneIconTile: CGFloat = 54
    static let laneIconSize: CGFloat = 32
    static let laneSymbolSize: CGFloat = 24
}

struct OpenBarVisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
    }
}

extension Color {
    init(hex: String) {
        self.init(nsColor: NSColor(openBarHex: hex))
    }

    static func adaptive(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(openBarHex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(openBarHex hex: String) {
        var value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if value.count == 6 { value.append("FF") }
        var int: UInt64 = 0
        Scanner(string: value).scanHexInt64(&int)
        self.init(
            srgbRed: CGFloat((int >> 24) & 0xFF) / 255,
            green: CGFloat((int >> 16) & 0xFF) / 255,
            blue: CGFloat((int >> 8) & 0xFF) / 255,
            alpha: CGFloat(int & 0xFF) / 255
        )
    }
}

final class OpenBarHoverState: ObservableObject {
    @Published var isHovered = false
}

struct Hairline: View {
    var axis: Axis = .horizontal

    var body: some View {
        Rectangle()
            .fill(OpenBarTheme.divider)
            .frame(
                width: axis == .vertical ? 1 : nil,
                height: axis == .horizontal ? 1 : nil
            )
    }
}

struct IconCommandButton: View {
    let systemName: String
    let help: String
    var prominent = false
    let action: () -> Void
    @StateObject private var hover = OpenBarHoverState()

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .foregroundStyle(prominent ? Color.white : (hover.isHovered ? OpenBarTheme.label : OpenBarTheme.muted))
                .background(
                    RoundedRectangle(cornerRadius: OpenBarTheme.corner, style: .continuous)
                        .fill(
                            prominent
                                ? OpenBarTheme.accent
                                : (hover.isHovered ? OpenBarTheme.controlHover : Color.clear)
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovered = $0 }
        .help(help)
    }
}

struct QuietButton: View {
    let title: String
    var systemName: String?
    var prominent = false
    var enabled = true
    let action: () -> Void
    @StateObject private var hover = OpenBarHoverState()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemName {
                    Image(systemName: systemName)
                }
                Text(title)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? Color.white : OpenBarTheme.label)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: OpenBarTheme.corner, style: .continuous)
                    .fill(
                        prominent
                            ? OpenBarTheme.accent.opacity(hover.isHovered ? 1 : 0.92)
                            : (hover.isHovered ? OpenBarTheme.controlHover : OpenBarTheme.control)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hover.isHovered = $0 }
    }
}

struct GhostButton: View {
    let title: String
    let action: () -> Void
    @StateObject private var hover = OpenBarHoverState()

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hover.isHovered ? OpenBarTheme.label : OpenBarTheme.muted)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: OpenBarTheme.corner, style: .continuous)
                        .fill(hover.isHovered ? OpenBarTheme.control : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovered = $0 }
    }
}

struct StatusBadge: View {
    let ready: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ready ? OpenBarTheme.success : OpenBarTheme.danger)
                .frame(width: 6, height: 6)
            Text(ready ? L("Ready") : L("Permission Needed"))
                .font(.system(size: 11))
                .foregroundStyle(OpenBarTheme.muted)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
    }
}

struct SectionRule: View {
    var body: some View { Hairline() }
}

typealias LinearHairline = Hairline
typealias LinearPrimaryButton = QuietButton
typealias LinearGhostButton = GhostButton
typealias GlowButton = QuietButton
