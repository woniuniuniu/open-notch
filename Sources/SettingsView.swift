import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

private enum OpenNotchTheme {
    static let blue = Color(red: 0.24, green: 0.63, blue: 0.96)
    static let cyan = Color(red: 0.20, green: 0.78, blue: 0.82)
    static let magenta = Color(red: 0.93, green: 0.23, blue: 0.70)
    static let yellow = Color(red: 0.98, green: 0.77, blue: 0.16)
    static let green = Color(red: 0.25, green: 0.82, blue: 0.49)

    static func panelFill(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.055) : Color.white.opacity(0.46)
    }

    static func hairline(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }

    static func hoverFill(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.075) : Color.black.opacity(0.045)
    }
}

struct SettingsRootView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSettingsMenu = false

    var body: some View {
        ZStack {
            WindowVisualEffect()
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            VStack(spacing: 0) {
                CompactTopBar(showMenu: $showSettingsMenu)
                detail
            }
            .padding(12)

            if showSettingsMenu {
                SettingsQuickMenu(isPresented: $showSettingsMenu)
                    .padding(.top, 54)
                    .padding(.trailing, 17)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                    .zIndex(100)
            }
        }
        .frame(width: 470, height: 650)
        .id(settings.language)
        .animation(reduceMotion ? nil : .snappy(duration: 0.36), value: model.selectedPane)
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            switch model.selectedPane ?? .overview {
            case .overview: OverviewPane()
            case .menuItems: MenuItemsPane()
            case .oneDrive: OneDrivePane()
            case .general: GeneralPane()
            case .about: AboutPane()
            }
        }
        .id(model.selectedPane ?? .overview)
        .transition(
            reduceMotion
                ? .opacity
                : .asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .trailing)),
                    removal: .opacity
                )
        )
    }
}

private struct WindowVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 22
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        view.layer?.shadowColor = NSColor.black.withAlphaComponent(0.35).cgColor
        view.layer?.shadowOpacity = 1
        view.layer?.shadowRadius = 24
        view.layer?.shadowOffset = CGSize(width: 0, height: -8)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct CompactTopBar: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace
    @Binding var showMenu: Bool

    var body: some View {
        HStack(spacing: 10) {
            WindowControlButtons()

            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            HStack(spacing: 2) {
                topTab(L("Overview"), pane: .overview, icon: "sparkles")
                topTab(L("Items"), pane: .menuItems, icon: "menubar.rectangle")
            }
            .padding(3)
            .background(.black.opacity(0.12), in: Capsule())

            Spacer(minLength: 0)

            Button { withAnimation(.easeOut(duration: 0.16)) { showMenu.toggle() } } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 29, height: 29)
            }
            .buttonStyle(.plain)
            .background(.white.opacity(0.10), in: Circle())
        }
        .padding(.horizontal, 5)
        .frame(height: 42)
    }

    @ViewBuilder
    private func topTab(_ title: String, pane: SettingsPane, icon: String) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.82)) {
                model.selectedPane = pane
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 10).frame(height: 27)
            .background {
                if model.selectedPane == pane || (pane == .overview && model.selectedPane == nil) {
                    Capsule().fill(.white.opacity(0.19)).matchedGeometryEffect(id: "tab", in: namespace)
                }
            }
        }
        .buttonStyle(.plain)
    }

}

private struct SettingsQuickMenu: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool
    @State private var hoveredMenu: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            menuButton(L("OneDrive"), icon: "cloud.fill", pane: .oneDrive)
            menuButton(L("General"), icon: "slider.horizontal.3", pane: .general)
            menuButton(L("About"), icon: "info.circle", pane: .about)
            Divider().padding(.vertical, 3)
            Button { NSApplication.shared.terminate(nil) } label: {
                Text(L("Quit Open Notch"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .frame(width: 164, height: 34, alignment: .leading)
            .contentShape(Rectangle())
            .background(Color.clear)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.16), lineWidth: 1) }
        .shadow(color: .black.opacity(0.24), radius: 20, y: 8)
        .frame(width: 190)
    }

    private func menuButton(_ title: String, icon: String, pane: SettingsPane) -> some View {
        Button { model.selectedPane = pane; isPresented = false } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .frame(width: 164, height: 34, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hoveredMenu = $0 ? pane.id : nil }
        .background(hoveredMenu == pane.id ? Color.primary.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct WindowControlButtons: View {
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            control(color: Color(red: 1, green: 0.37, blue: 0.34), symbol: "xmark") {
                closeSettingsWindow()
            }
            control(color: Color(red: 1, green: 0.74, blue: 0.18), symbol: "minus") {
                NSApp.keyWindow?.miniaturize(nil)
            }
            control(color: Color(red: 0.20, green: 0.78, blue: 0.35), symbol: "arrow.up.left.and.arrow.down.right") {
                NSApp.keyWindow?.zoom(nil)
            }
        }
        .padding(.horizontal, 3)
        .onHover { hovering = $0 }
    }

    private func control(color: Color, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(color).frame(width: 13, height: 13)
                if hovering {
                    Image(systemName: symbol)
                        .font(.system(size: 7, weight: .black))
                        .foregroundStyle(.black.opacity(0.62))
                }
            }
            .frame(width: 17, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func closeSettingsWindow() {
        let window = NSApp.windows.first {
            $0.identifier?.rawValue == "OpenNotch.Settings"
        }
        window?.performClose(self)
    }
}

private struct AppChromeBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle().fill(.clear)
        }
        .ignoresSafeArea()
    }
}

private struct AppSidebar: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var selectionNamespace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 30, height: 30)
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)

                VStack(alignment: .leading, spacing: 1) {
                    Text(L("App Name"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(L("Menu Bar"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 20)

            VStack(spacing: 5) {
                ForEach(SettingsPane.allCases) { pane in
                    Button {
                        model.selectedPane = pane
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: pane.symbolName)
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 19)
                                .foregroundStyle(
                                    model.selectedPane == pane ? OpenNotchTheme.cyan : Color.secondary
                                )

                            Text(pane.title)
                                .font(.system(size: 13, weight: model.selectedPane == pane ? .semibold : .medium))
                                .foregroundStyle(.primary)

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 11)
                        .frame(height: 36)
                        .background {
                            if model.selectedPane == pane {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(OpenNotchTheme.blue.opacity(colorScheme == .dark ? 0.20 : 0.13))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(OpenNotchTheme.blue.opacity(0.28), lineWidth: 1)
                                    }
                                    .matchedGeometryEffect(id: "sidebarSelection", in: selectionNamespace)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            SidebarStatus()
                .padding(12)
        }
        .background(.thinMaterial.opacity(0.42))
    }
}

private struct SidebarStatus: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(model.hasAccessibilityPermission ? OpenNotchTheme.green : OpenNotchTheme.yellow)
                .frame(width: 7, height: 7)
                .shadow(
                    color: (model.hasAccessibilityPermission ? OpenNotchTheme.green : OpenNotchTheme.yellow).opacity(0.5),
                    radius: 5
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(model.hasAccessibilityPermission ? L("Authorized") : L("Not Authorized"))
                    .font(.caption.weight(.semibold))
                Text(L("Accessibility"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .frame(height: 48)
        .background(OpenNotchTheme.panelFill(for: colorScheme))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(OpenNotchTheme.hairline(for: colorScheme), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct PageScaffold<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 22, weight: .bold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 17)
            .padding(.bottom, 14)

            Rectangle()
                .fill(.separator.opacity(0.45))
                .frame(height: 1)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    content
                }
                .padding(18)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct GlassPanel<Content: View>: View {
    let title: String?
    let systemImage: String?
    let accent: Color
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    init(
        title: String? = nil,
        systemImage: String? = nil,
        accent: Color = OpenNotchTheme.blue,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(spacing: 8) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(accent)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 13)
                .frame(height: 42)

                Rectangle()
                    .fill(OpenNotchTheme.hairline(for: colorScheme))
                    .frame(height: 1)
            }

            content
                .padding(13)
        }
        .background(OpenNotchTheme.panelFill(for: colorScheme))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(OpenNotchTheme.hairline(for: colorScheme), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.07), radius: 14, y: 7)
    }
}

private struct StatusGauge: View {
    let visible: Int
    let hidden: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress = 0.0

    private var targetProgress: Double {
        let total = max(visible + hidden, 1)
        return Double(visible) / Double(total)
    }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.08, to: 0.92)
                .stroke(Color.secondary.opacity(0.15), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(90))

            Circle()
                .trim(from: 0.08, to: 0.08 + (0.84 * progress))
                .stroke(OpenNotchTheme.yellow, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(90))

            Circle()
                .trim(from: 0.08, to: 0.08 + (0.84 * min(progress, 0.54)))
                .stroke(OpenNotchTheme.magenta, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(90))
                .padding(12)

            VStack(spacing: 0) {
                Text("\(visible)")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text(L("Visible"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 124, height: 124)
        .onAppear {
            if reduceMotion {
                progress = targetProgress
            } else {
                withAnimation(.spring(response: 0.72, dampingFraction: 0.78)) {
                    progress = targetProgress
                }
            }
        }
        .onChange(of: targetProgress) { _, value in
            withAnimation(reduceMotion ? nil : .spring(response: 0.58, dampingFraction: 0.82)) {
                progress = value
            }
        }
    }
}

private struct MetricLine: View {
    let color: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
        .frame(height: 24)
    }
}

private struct SettingsLine<Control: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let tint: Color
    @ViewBuilder let control: Control

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String,
        tint: Color = OpenNotchTheme.blue,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)
            control
        }
        .frame(minHeight: 38)
    }
}

private struct PermissionBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GlassPanel(
            title: L("Accessibility access required"),
            systemImage: "hand.raised.fill",
            accent: OpenNotchTheme.yellow
        ) {
            HStack(spacing: 9) {
                Text(L("Accessibility access not granted"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("Recheck")) { model.recheckAccessibilityPermission() }
                    .systemGlassButton()
                Button(L("Open System Settings")) { model.requestAccessibilityPermission() }
                    .systemGlassButton(prominent: true)
            }
        }
    }
}

private struct OverviewPane: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        PageScaffold(title: L("Overview"), subtitle: L("Menu bar at a glance")) {
            if !model.canManageMenuBar {
                PermissionBanner()
            }

            HStack(alignment: .center, spacing: 22) {
                StatusGauge(visible: model.visibleItems.count, hidden: model.hiddenItems.count)

                VStack(spacing: 4) {
                    MetricLine(color: OpenNotchTheme.yellow, title: L("Keep Visible"), value: "\(model.visibleItems.count)")
                    MetricLine(color: OpenNotchTheme.magenta, title: L("Set to Hidden"), value: "\(model.hiddenItems.count)")
                    MetricLine(
                        color: OpenNotchTheme.cyan,
                        title: L("Current Status"),
                        value: settings.isExpanded ? L("Expanded") : L("Collapsed")
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)

            GlassPanel(title: L("Menu Bar"), systemImage: "menubar.rectangle", accent: OpenNotchTheme.cyan) {
                SettingsLine(
                    L("Hidden Section"),
                    subtitle: settings.isExpanded ? L("Hidden section expanded") : L("Hidden section collapsed"),
                    systemImage: settings.isExpanded ? "eye" : "eye.slash",
                    tint: OpenNotchTheme.cyan
                ) {
                    Button(settings.isExpanded ? L("Collapse") : L("Expand")) {
                        model.toggleExpanded()
                    }
                    .systemGlassButton(prominent: true)
                }
            }

            GlassPanel(title: "OneDrive", systemImage: "cloud.fill", accent: OpenNotchTheme.magenta) {
                SettingsLine(
                    model.oneDriveItem == nil ? L("OneDrive item not found") : L("OneDrive pinned"),
                    subtitle: settings.oneDriveGuardianEnabled ? L("Keep OneDrive pinned") : L("Off"),
                    systemImage: model.oneDriveItem == nil ? "cloud.slash" : "checkmark.shield.fill",
                    tint: model.oneDriveItem == nil ? OpenNotchTheme.yellow : OpenNotchTheme.green
                ) {
                    Button(L("Reset Now")) { model.repairOneDriveNow() }
                        .systemGlassButton()
                        .disabled(model.oneDriveItem == nil || !model.canManageMenuBar)
                }
            }

            if let event = model.guardianEvents.first {
                GlassPanel(title: L("Recent Activity"), systemImage: "bolt.fill", accent: OpenNotchTheme.yellow) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(OpenNotchTheme.yellow)
                            .frame(width: 7, height: 7)
                        Text(event.message)
                            .font(.caption)
                            .lineLimit(2)
                        Spacer()
                        Text(event.date, style: .time)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct MenuItemsPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        PageScaffold(title: L("Menu Bar Items"), subtitle: LF("%d manageable items", model.filteredItems.count)) {
            AIOrganizerSection()

            if !model.canManageMenuBar {
                PermissionBanner()
            } else {
                HStack(spacing: 9) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField(L("Filter scanned items"), text: $model.searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(.thinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.separator.opacity(0.55), lineWidth: 1)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Button {
                        model.refresh(reason: L("Manual scan"), reconcile: false)
                    } label: {
                        if model.isScanning {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .frame(width: 34, height: 34)
                    .systemGlassButton()
                    .help(L("Rescan"))
                }

                if model.items.filter({ !$0.isProtected }).isEmpty {
                    GlassPanel {
                        VStack(spacing: 10) {
                            ContentUnavailableView(L("No manageable items"), systemImage: "menubar.rectangle")
                            Button(L("Scan Now")) {
                                model.searchText = ""
                                model.refresh(reason: L("Manual scan"), reconcile: false)
                            }
                            .systemGlassButton(prominent: true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 180)
                    }
                } else if model.filteredItems.isEmpty {
                    GlassPanel {
                        VStack(spacing: 10) {
                            ContentUnavailableView(L("No matching items"), systemImage: "magnifyingglass")
                            Button(L("Clear Search")) { model.searchText = "" }
                                .systemGlassButton()
                        }
                        .frame(maxWidth: .infinity, minHeight: 180)
                    }
                } else {
                    GlassPanel(title: L("Manual Management"), systemImage: "slider.horizontal.3", accent: OpenNotchTheme.blue) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.filteredItems.enumerated()), id: \.element.id) { index, item in
                                MenuItemRow(item: item)
                                if index < model.filteredItems.count - 1 {
                                    Divider()
                                        .opacity(0.55)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct MenuItemRow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var settings = SettingsStore.shared
    @State private var isHovering = false
    @State private var isDropTargeted = false
    let item: MenuBarItem

    var body: some View {
        HStack(spacing: 11) {
            if MenuBarAgentBridge.isAvailable {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                    .help(L("Drag to reorder"))
                    .accessibilityLabel(L("Drag to reorder"))
            }

            MenuItemIcon(item: item)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if item.isOneDrive {
                        Text(L("Always Pinned"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(OpenNotchTheme.magenta)
                    }
                }
                Text(secondaryText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(item.semanticBundleIdentifier)
            }

            Spacer(minLength: 12)

            VisibilityControl(selection: Binding(
                get: { model.disposition(for: item) },
                set: { model.setDisposition($0, for: item) }
            ))
            .disabled(item.isOneDrive && SettingsStore.shared.oneDriveGuardianEnabled)
        }
        .padding(.horizontal, 7)
        .frame(height: 52)
        .background((isHovering || isDropTargeted) ? OpenNotchTheme.hoverFill(for: colorScheme) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { isHovering = $0 }
        .onDrag {
            NSItemProvider(object: item.id as NSString)
        } preview: {
            Label(item.displayName, systemImage: item.symbolName)
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .onDrop(of: [UTType.text], isTargeted: $isDropTargeted) { providers in
            guard MenuBarAgentBridge.isAvailable, let provider = providers.first else { return false }
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let sourceID = object as? String else { return }
                Task { @MainActor in
                    model.reorderMenuBarItem(sourceID: sourceID, targetID: item.id)
                }
            }
            return true
        }
        .accessibilityElement(children: .contain)
    }

    private var secondaryText: String {
        settings.aiDescription(for: item.id, language: settings.language)
            ?? (item.detail.isEmpty ? item.semanticBundleIdentifier : item.detail)
    }
}

private struct VisibilityControl: View {
    @Binding var selection: ItemDisposition
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionNamespace

    var body: some View {
        HStack(spacing: 3) {
            option(.visible, symbol: "eye.fill", tint: OpenNotchTheme.cyan)
            option(.hidden, symbol: "eye.slash.fill", tint: Color.gray)
        }
        .padding(3)
        .background(.black.opacity(0.13), in: Capsule())
        .overlay { Capsule().stroke(.white.opacity(0.08), lineWidth: 1) }
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Position"))
    }

    private func option(_ disposition: ItemDisposition, symbol: String, tint: Color) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.78)) {
                selection = disposition
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selection == disposition ? Color.white : Color.secondary)
                .frame(width: 32, height: 25)
                .background {
                    if selection == disposition {
                        Capsule()
                            .fill(tint.gradient)
                            .matchedGeometryEffect(id: "visibilitySelection", in: selectionNamespace)
                            .shadow(color: tint.opacity(0.35), radius: 6, y: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(disposition.title)
        .accessibilityLabel(disposition.title)
        .accessibilityAddTraits(selection == disposition ? .isSelected : [])
    }
}

private struct MenuItemIcon: View {
    let item: MenuBarItem

    var body: some View {
        Group {
            if let applicationIcon = ApplicationIconResolver.shared.icon(for: item) {
                Image(nsImage: applicationIcon)
                    .resizable()
                    .scaledToFit()
            } else if item.symbolName == "app.dashed" {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .opacity(0.65)
            } else {
                Image(systemName: item.symbolName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct OneDrivePane: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        PageScaffold(title: "OneDrive", subtitle: L("Dynamic menu bar item guardian")) {
            if !model.canManageMenuBar {
                PermissionBanner()
            }

            VStack(spacing: 8) {
                Image(systemName: model.oneDriveItem == nil ? "cloud.slash.fill" : "cloud.fill")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(model.oneDriveItem == nil ? OpenNotchTheme.yellow : OpenNotchTheme.cyan)
                    .shadow(color: OpenNotchTheme.cyan.opacity(0.25), radius: 14)
                Text(model.oneDriveItem == nil ? L("OneDrive item not found") : L("OneDrive pinned"))
                    .font(.title3.weight(.bold))
                Text(settings.oneDriveGuardianEnabled ? L("Keep OneDrive pinned") : L("Off"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)

            GlassPanel(title: L("Status"), systemImage: "waveform.path.ecg", accent: OpenNotchTheme.cyan) {
                VStack(spacing: 0) {
                    SettingsLine(
                        L("Identification"),
                        subtitle: model.oneDriveItem == nil ? L("Not Found") : L("Identified"),
                        systemImage: "scope",
                        tint: model.oneDriveItem == nil ? OpenNotchTheme.yellow : OpenNotchTheme.green
                    ) {
                        Button(L("Reset Now")) { model.repairOneDriveNow() }
                            .systemGlassButton(prominent: true)
                            .disabled(model.oneDriveItem == nil || !model.canManageMenuBar)
                    }

                    if let oneDrive = model.oneDriveItem {
                        Divider().opacity(0.55)
                        SettingsLine(L("Current Window"), systemImage: "macwindow") {
                            Text("#\(oneDrive.windowID)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Divider().opacity(0.55)
                        SettingsLine(L("Host Process"), systemImage: "shippingbox") {
                            Text(oneDrive.hostBundleIdentifier)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            GlassPanel(title: L("Guardian"), systemImage: "shield.fill", accent: OpenNotchTheme.magenta) {
                VStack(spacing: 0) {
                    SettingsLine(L("Keep OneDrive pinned"), systemImage: "pin.fill", tint: OpenNotchTheme.magenta) {
                        Toggle("", isOn: Binding(
                            get: { settings.oneDriveGuardianEnabled },
                            set: { _ in model.toggleGuardian() }
                        ))
                        .labelsHidden()
                    }
                    Divider().opacity(0.55)
                    SettingsLine(L("Automatic reset count"), systemImage: "arrow.triangle.2.circlepath") {
                        Text("\(settings.repairCount)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }
            }

            if !model.guardianEvents.isEmpty {
                GlassPanel(title: L("Recent Events"), systemImage: "clock.fill", accent: OpenNotchTheme.yellow) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.guardianEvents.enumerated()), id: \.element.id) { index, event in
                            HStack(spacing: 9) {
                                Circle()
                                    .fill(index == 0 ? OpenNotchTheme.yellow : Color.secondary.opacity(0.35))
                                    .frame(width: 6, height: 6)
                                Text(event.message)
                                    .font(.caption)
                                    .lineLimit(2)
                                Spacer()
                                Text(event.date, style: .time)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 34)
                            if index < model.guardianEvents.count - 1 {
                                Divider().opacity(0.45)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct AIOrganizerSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GlassPanel(title: L("AI Organize"), systemImage: "sparkles.rectangle.stack.fill", accent: OpenNotchTheme.cyan) {
            VStack(alignment: .leading, spacing: 12) {
                if model.isRequestingAIRecommendation {
                    AIRequestProgressView(phase: model.aiRequestPhase)
                } else if let recommendation = model.aiRecommendation {
                    HStack(spacing: 7) {
                        ForEach(recommendation.plans) { plan in
                            Button {
                                model.selectedAIPlanID = plan.id
                            } label: {
                                HStack(spacing: 5) {
                                    Text(plan.title).lineLimit(1)
                                    if plan.id == recommendation.recommendedPlanID {
                                        Image(systemName: "checkmark.seal.fill")
                                    }
                                }
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 9)
                                .frame(height: 28)
                                .background(
                                    model.selectedAIPlanID == plan.id ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.055),
                                    in: Capsule()
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if let plan = recommendation.plans.first(where: { $0.id == model.selectedAIPlanID }) {
                        Text(plan.summary)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        AIBeforeAfterPreview(plan: plan)
                        HStack(spacing: 8) {
                            Text(model.aiAvailabilityMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if model.canRequestAIRecommendation {
                                Button {
                                    model.requestAIRecommendation()
                                } label: {
                                    Label(L("Regenerate"), systemImage: "arrow.clockwise")
                                }
                                .systemGlassButton()
                            }
                            if model.canUndoAIRecommendation && !model.isApplyingAIRecommendation {
                                Button(L("Undo")) { model.undoAIRecommendation() }
                                    .systemGlassButton()
                            }
                            Button(L("Apply Selected Layout")) { model.applyAIRecommendation(plan) }
                                .systemGlassButton(prominent: true)
                                .disabled(!model.canApplyAIRecommendation || model.isApplyingAIRecommendation)
                        }
                    }
                } else {
                    Text(L("AI reviews the latest scan and prepares two layouts. View the Before and After comparison, then apply only when you are ready."))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Text(model.aiAvailabilityMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            model.requestAIRecommendation()
                        } label: {
                            if model.isRequestingAIRecommendation {
                                ProgressView().controlSize(.small)
                            } else {
                                Label(L("Click to Generate Plan"), systemImage: "sparkles")
                            }
                        }
                        .systemGlassButton(prominent: true)
                        .disabled(!model.canRequestAIRecommendation || model.isRequestingAIRecommendation)
                    }
                }

                if let message = model.aiRecommendationMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct AIRequestProgressView: View {
    let phase: AIRequestPhase?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                Text(phase?.title ?? L("AI is analyzing the menu bar"))
                    .font(.system(size: 13, weight: .semibold))
            }
            ProgressView()
                .progressViewStyle(.linear)
            Text(L("The latest scan is fixed while the AI result is being generated. Nothing will change until you apply it."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct AIBeforeAfterPreview: View {
    @EnvironmentObject private var model: AppModel
    let plan: AIRecommendationPlan

    private var decisions: [(MenuBarItem, AIRecommendationItem)] {
        plan.items.compactMap { decision in
            guard let item = model.item(forAIRecommendationID: decision.id) else { return nil }
            return (item, decision)
        }
    }

    var body: some View {
        let changes = decisions.filter { model.aiBeforeDisposition(for: $0.0) != $0.1.disposition }
        return VStack(alignment: .leading, spacing: 8) {
            menuBarPreview(title: L("Before"), useProposedState: false)
            Image(systemName: "arrow.down")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            menuBarPreview(title: L("After"), useProposedState: true)
            Text(LF("%d items will change", changes.count))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func menuBarPreview(title: String, useProposedState: Bool) -> some View {
        let visibleItems = decisions.filter { item, decision in
            (useProposedState ? decision.disposition : model.aiBeforeDisposition(for: item)) == .visible
        }.map(\.0)

        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(visibleItems.count) / \(decisions.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(visibleItems) { item in
                        MenuItemIcon(item: item)
                            .frame(width: 24, height: 24)
                            .help(item.displayName)
                    }
                }
                .frame(minWidth: 0, minHeight: 28, alignment: .leading)
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct GeneralPane: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        PageScaffold(title: L("General"), subtitle: L("Interface and behavior")) {
            GlassPanel(title: L("Interface"), systemImage: "slider.horizontal.3", accent: OpenNotchTheme.cyan) {
                VStack(spacing: 0) {
                    SettingsLine(L("Language"), systemImage: "character.bubble") {
                        Picker("", selection: Binding(
                            get: { settings.language },
                            set: { model.setLanguage($0) }
                        )) {
                            ForEach(AppLanguage.allCases) { language in
                                Text(language.nativeName).tag(language)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 210)
                    }
                    Divider().opacity(0.55)
                    SettingsLine(L("Appearance"), systemImage: "circle.lefthalf.filled", tint: OpenNotchTheme.magenta) {
                        Picker("", selection: Binding(
                            get: { settings.appearanceMode },
                            set: { model.setAppearance($0) }
                        )) {
                            ForEach(AppearanceMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                    }
                }
            }

            GlassPanel(title: L("Operation"), systemImage: "bolt.fill", accent: OpenNotchTheme.yellow) {
                VStack(spacing: 0) {
                    SettingsLine(
                        L("Show in Dock"),
                        subtitle: settings.showInDock ? L("Dock and menu bar") : L("Menu bar only"),
                        systemImage: "dock.rectangle"
                    ) {
                        Toggle("", isOn: Binding(
                            get: { settings.showInDock },
                            set: { model.setDockVisibility($0) }
                        ))
                        .labelsHidden()
                    }
                    Divider().opacity(0.55)
                    SettingsLine(L("Open at Login"), systemImage: "power") {
                        Toggle("", isOn: Binding(
                            get: { model.launchAtLogin },
                            set: { model.setLaunchAtLogin($0) }
                        ))
                        .labelsHidden()
                    }
                    Divider().opacity(0.55)
                    SettingsLine(
                        L("Automatically restore menu bar layout"),
                        systemImage: "arrow.triangle.2.circlepath",
                        tint: OpenNotchTheme.green
                    ) {
                        Toggle("", isOn: Binding(
                            get: { settings.continuousMonitorEnabled },
                            set: { model.setContinuousMonitor($0) }
                        ))
                        .labelsHidden()
                    }
                }
            }

            GlassPanel(title: L("Permission"), systemImage: "hand.raised.fill", accent: OpenNotchTheme.magenta) {
                SettingsLine(
                    L("Accessibility"),
                    subtitle: model.hasAccessibilityPermission ? L("Authorized") : L("Not Authorized"),
                    systemImage: model.hasAccessibilityPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    tint: model.hasAccessibilityPermission ? OpenNotchTheme.green : OpenNotchTheme.yellow
                ) {
                    HStack(spacing: 8) {
                        Button(L("Recheck")) { model.recheckAccessibilityPermission() }
                            .systemGlassButton()
                        Button(L("Open System Settings")) { model.requestAccessibilityPermission() }
                            .systemGlassButton(prominent: true)
                    }
                }
            }
        }
    }
}

private struct AboutPane: View {
    var body: some View {
        PageScaffold(title: L("About"), subtitle: L("App Name")) {
            HStack(spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .shadow(color: OpenNotchTheme.blue.opacity(0.26), radius: 18, y: 8)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("App Name"))
                        .font(.title2.weight(.bold))
                    Text(L("Open-source menu bar manager"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(LF("Version %@ (%@)", Bundle.main.shortVersion, Bundle.main.buildVersion))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(OpenNotchTheme.cyan)
                }
            }
            .padding(.vertical, 12)

            GlassPanel(title: L("Project"), systemImage: "hammer.fill", accent: OpenNotchTheme.cyan) {
                VStack(spacing: 0) {
                    SettingsLine(L("Bundle Identifier"), systemImage: "number") {
                        Text("com.openbartender.OpenNotch")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Divider().opacity(0.55)
                    SettingsLine(L("Minimum System"), systemImage: "macbook") {
                        Text("macOS 14")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Divider().opacity(0.55)
                    SettingsLine(L("License"), systemImage: "doc.text") {
                        Text("GNU GPL v3")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            GlassPanel(title: L("Legal"), systemImage: "checkmark.seal.fill", accent: OpenNotchTheme.green) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("This program comes with absolutely no warranty. You may redistribute it under GNU GPL v3."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button(L("View License")) { openBundledDocument(resource: "LICENSE", extension: nil) }
                            .systemGlassButton()
                        Button(L("View Notices")) { openBundledDocument(resource: "NOTICE", extension: "md") }
                            .systemGlassButton()
                    }
                }
            }

            GlassPanel(title: L("Privacy"), systemImage: "lock.shield.fill", accent: OpenNotchTheme.green) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("AI privacy details"))
                        .font(.caption.weight(.semibold))
                    Text(L("Only app names, bundle identifiers, and current visible or hidden states are sent. Screenshots, paths, usernames, and Accessibility data never leave your Mac."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("AI requests are processed by the Open Notch service and DeepSeek. Each installation can request one new recommendation every 24 hours."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            GlassPanel(title: L("Diagnostics"), systemImage: "ladybug.fill", accent: OpenNotchTheme.yellow) {
                SettingsLine(
                    L("Debug report"),
                    subtitle: L("Save compatibility details and recent activity to Desktop"),
                    systemImage: "doc.badge.gearshape",
                    tint: OpenNotchTheme.yellow
                ) {
                    Button(L("Export Debug Log")) { AppModel.shared.exportDebugReport() }
                        .systemGlassButton(prominent: true)
                }
            }

            GlassPanel(title: L("Credits"), systemImage: "heart.fill", accent: OpenNotchTheme.magenta) {
                VStack(spacing: 0) {
                    SettingsLine(L("Developer"), systemImage: "hammer.fill", tint: OpenNotchTheme.cyan) {
                        Text(L("Xiaohongshu @Snail's Tech Notes"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Divider().opacity(0.55)
                    SettingsLine(L("Chinese localization contributor"), systemImage: "character.cursor.ibeam", tint: OpenNotchTheme.magenta) {
                        Text("小红书@李山迎 Joshua")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func openBundledDocument(resource: String, extension fileExtension: String?) {
        guard let url = Bundle.main.url(forResource: resource, withExtension: fileExtension) else { return }
        NSWorkspace.shared.open(url)
    }
}

private extension Bundle {
    var shortVersion: String { object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L("Unknown") }
    var buildVersion: String { object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? L("Unknown") }
}

private extension View {
    @ViewBuilder
    func systemGlassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}
