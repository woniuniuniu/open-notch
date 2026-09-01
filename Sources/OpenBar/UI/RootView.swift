import AppKit
import OpenBarCore
import ServiceManagement
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: PolicyStore

    var body: some View {
        ZStack {
            OpenBarVisualEffect(material: .hudWindow)
                // The hosting view still reserves the native titlebar safe
                // area for content, but the single glass surface must paint
                // behind the traffic lights as well.
                .ignoresSafeArea(.all)

            HStack(spacing: 0) {
                Sidebar()
                    .frame(width: OpenBarTheme.sidebarWidth)
                Hairline(axis: .vertical)
                Group {
                    switch model.selectedPage {
                    case .items: MenuBarWorkspaceView()
                    case .activity: ActivityView()
                    case .settings: SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Keep one continuous rounded surface around both the native titlebar
        // and the SwiftUI content. The titlebar remains native; only the
        // surface behind it is unified.
        .clipShape(RoundedRectangle(cornerRadius: OpenBarTheme.windowCorner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OpenBarTheme.windowCorner, style: .continuous)
                .stroke(OpenBarTheme.glassStroke.opacity(0.75), lineWidth: 1)
        }
        .overlay(alignment: .topLeading) {
            WindowTrafficLights()
                .padding(.top, 14)
                .padding(.leading, 14)
        }
        .frame(minWidth: 760, minHeight: 560)
        .id(store.document.preferences.language)
        .sheet(item: Binding(
            get: { model.aiProposal },
            set: { if $0 == nil { model.cancelAIPlacement() } }
        )) { proposal in
            AIPlacementReviewView(proposal: proposal)
                .environmentObject(model)
                .environmentObject(store)
        }
    }
}

private struct WindowTrafficLights: View {
    var body: some View {
        HStack(spacing: 8) {
            WindowTrafficLight(
                color: Color(hex: "#FF5F57"),
                symbol: "xmark",
                label: L("Close window")
            ) {
                closeMainWindow()
            }
            WindowTrafficLight(
                color: Color(hex: "#FEBC2E"),
                symbol: "minus",
                label: L("Minimize window")
            ) {
                minimizeMainWindow()
            }
            WindowTrafficLight(
                color: Color(hex: "#28C840"),
                symbol: "arrow.up.left.and.arrow.down.right",
                label: L("Zoom window")
            ) {
                mainWindow?.zoom(nil)
            }
        }
        .frame(height: 14)
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "OpenBar.Main" }
    }

    private func closeMainWindow() {
        // OPEN BAR is a menu-bar utility. Closing its document window should
        // hide the window while leaving the status item and app process alive.
        mainWindow?.orderOut(nil)
    }

    private func minimizeMainWindow() {
        guard let window = mainWindow else { return }
        window.miniaturize(nil)
        // Accessory apps cannot always create a Dock miniaturized window. In
        // that case retain the expected button feedback by hiding the window;
        // clicking OPEN BAR in the menu bar restores it immediately.
        if !window.isMiniaturized {
            window.orderOut(nil)
        }
    }
}

private struct WindowTrafficLight: View {
    let color: Color
    let symbol: String
    let label: String
    let action: () -> Void
    @StateObject private var hover = OpenBarHoverState()

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color.opacity(hover.isHovered ? 1 : 0.82))
                .overlay {
                    Circle()
                        .stroke(Color.black.opacity(0.18), lineWidth: 0.5)
                }
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Color.black.opacity(hover.isHovered ? 0.64 : 0))
                }
                .frame(width: 13, height: 13)
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct Sidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Open Bar Brand"))
                        .font(.system(size: 22, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Text(L("Menu bar, made calm"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(OpenBarTheme.muted)
                        .lineLimit(1)
                }
                Spacer()
                IconCommandButton(systemName: "sparkles", help: L("AI One-click Placement")) {
                    model.prepareAIPlacement()
                }
                .disabled(model.isAIPlacementLoading || model.managedItems.isEmpty)
            }
            .padding(.horizontal, 18)
            .padding(.top, 48)
            .padding(.bottom, 22)

            Rectangle()
                .fill(OpenBarTheme.glassHighlight.opacity(0.22))
                .frame(height: 1)
                .padding(.horizontal, 18)

            VStack(spacing: 1) {
                ForEach([NavigationPage.items, NavigationPage.settings]) { page in
                    SidebarRow(
                        title: page.title,
                        symbol: page.symbol,
                        selected: model.selectedPage == page
                    ) {
                        model.selectedPage = page
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 16)

            Spacer()

            SidebarFooter()
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
        .background(OpenBarTheme.sidebarBackground)
    }
}

private struct SidebarFooter: View {
    @EnvironmentObject private var model: AppModel

    private var showHiddenBinding: Binding<Bool> {
        Binding(
            get: { model.isExpanded },
            set: { value in
                guard value != model.isExpanded else { return }
                model.toggleExpanded()
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Circle()
                    .fill(model.canManage ? OpenBarTheme.success : OpenBarTheme.danger)
                    .frame(width: 8, height: 8)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.canManage ? L("Ready") : L("Permission Needed"))
                        .font(.system(size: 12, weight: .semibold))
                    Text(model.lastOperationMessage ?? L("Changes apply automatically"))
                        .font(.system(size: 10))
                        .foregroundStyle(OpenBarTheme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: model.isExpanded ? "eye" : "eye.slash")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OpenBarTheme.label)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Show hidden items"))
                            .font(.system(size: 12, weight: .medium))
                        Text(L("Reveal them in the quick bar"))
                            .font(.system(size: 10))
                            .foregroundStyle(OpenBarTheme.muted)
                    }
                    Spacer(minLength: 0)
                    Toggle("", isOn: showHiddenBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(OpenBarTheme.accent)
                }
                .disabled(!model.canManage)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)

                Hairline()

                Button {
                    model.rescan()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: model.isScanning ? "hourglass" : "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(OpenBarTheme.label)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.isScanning ? L("Updating items") : L("Update menu bar items"))
                                .font(.system(size: 12, weight: .medium))
                            Text(L("Read the current menu bar again"))
                                .font(.system(size: 10))
                                .foregroundStyle(OpenBarTheme.muted)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isScanning)
                .opacity(model.isScanning ? 0.55 : 1)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
            }
            .background(
                OpenBarTheme.control.opacity(0.72),
                in: RoundedRectangle(cornerRadius: OpenBarTheme.corner, style: .continuous)
            )
        }
    }
}

private struct SidebarRow: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @StateObject private var hover = OpenBarHoverState()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected || hover.isHovered ? OpenBarTheme.label : OpenBarTheme.muted)
                    .frame(width: OpenBarTheme.iconColumn)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(OpenBarTheme.label)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: OpenBarTheme.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: OpenBarTheme.corner, style: .continuous)
                    .fill(selected ? OpenBarTheme.selection : (hover.isHovered ? OpenBarTheme.control : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovered = $0 }
    }
}

private struct AIPlacementReviewView: View {
    @EnvironmentObject private var model: AppModel
    let proposal: AIPlacementProposal

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("AI One-click Placement"))
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: 48)
            Hairline()
            if let note = model.aiPlacementNote {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(OpenBarTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }
            VStack(spacing: 16) {
                VisualMenuBarPreview(title: L("Before"), proposal: proposal, after: false)
                VisualMenuBarPreview(title: L("After"), proposal: proposal, after: true)
            }
            .padding(20)
            Hairline()
            HStack {
                Text(L("Nothing changes until you confirm."))
                    .font(.system(size: 12))
                    .foregroundStyle(OpenBarTheme.muted)
                Spacer()
                GhostButton(title: L("Cancel")) { model.cancelAIPlacement() }
                QuietButton(
                    title: L("Apply Placement"),
                    prominent: true,
                    enabled: model.canManage
                ) {
                    model.applyAIPlacement()
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
        }
        .frame(width: 720, height: 380)
        .background(OpenBarTheme.canvas)
    }
}

private struct VisualMenuBarPreview: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let proposal: AIPlacementProposal
    let after: Bool

    private var shown: [AIPlacementDecision] {
        proposal.decisions
            .sorted { $0.currentOrder < $1.currentOrder }
            .filter {
                (after ? $0.proposedSection : $0.currentSection) == .shown
                    && model.managedItem(id: $0.itemID)?.isRunning == true
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OpenBarTheme.muted)
                Spacer()
                Text(LF("%d visible", shown.count))
                    .font(.system(size: 11))
                    .foregroundStyle(OpenBarTheme.muted)
            }
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                ForEach(shown) { decision in
                    AIPreviewIcon(decision: decision, after: after)
                }
                Text(Date.now, format: .dateTime.hour().minute())
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(OpenBarTheme.label)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: OpenBarTheme.corner, style: .continuous)
                    .fill(OpenBarTheme.control)
            )
            .overlay {
                RoundedRectangle(cornerRadius: OpenBarTheme.corner, style: .continuous)
                    .stroke(after ? OpenBarTheme.accent.opacity(0.35) : OpenBarTheme.divider, lineWidth: 1)
            }
        }
    }
}

private struct AIPreviewIcon: View {
    @EnvironmentObject private var model: AppModel
    let decision: AIPlacementDecision
    let after: Bool

    private var item: ManagedMenuBarItem? { model.managedItem(id: decision.itemID) }
    private var changed: Bool { decision.currentSection != decision.proposedSection }

    var body: some View {
        Group {
            if let item, let image = ApplicationIconResolver.shared.icon(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 11))
                    .foregroundStyle(OpenBarTheme.muted)
            }
        }
        .frame(width: 16, height: 16)
        .padding(2)
        .background(
            after && changed ? OpenBarTheme.selection : Color.clear,
            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
        )
        .help((item?.localizedDisplayName ?? decision.itemID) + "\n" + L(decision.rationaleKey))
    }
}

private struct ActivityView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Activity"))
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                GhostButton(title: L("Export Diagnostics")) { model.exportDiagnostics() }
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .padding(.bottom, 12)
            Hairline()
            if model.activity.isEmpty {
                Text(L("No Activity"))
                    .font(.system(size: 13))
                    .foregroundStyle(OpenBarTheme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(model.activity) { entry in
                            HStack(spacing: 10) {
                                Text(entry.message)
                                    .font(.system(size: 13))
                                    .lineLimit(2)
                                Spacer()
                                Text(entry.date, style: .time)
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(OpenBarTheme.muted)
                            }
                            .padding(.horizontal, 24)
                            .frame(minHeight: 40)
                            Hairline()
                        }
                    }
                }
            }
        }
        .background(OpenBarTheme.canvas)
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: PolicyStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Settings"))
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 32)
            .padding(.bottom, 16)
            Hairline()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 28) {
                            behaviorBlock
                                .frame(minWidth: 280, maxWidth: .infinity, alignment: .topLeading)
                            appearanceBlock
                                .frame(minWidth: 280, maxWidth: .infinity, alignment: .topLeading)
                        }
                        VStack(alignment: .leading, spacing: 26) {
                            behaviorBlock
                            appearanceBlock
                        }
                    }

                    settingsBlock(L("AI")) { AISettingsView() }

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 28) {
                            systemBlock
                                .frame(minWidth: 280, maxWidth: .infinity, alignment: .topLeading)
                            dataBlock
                                .frame(minWidth: 280, maxWidth: .infinity, alignment: .topLeading)
                        }
                        VStack(alignment: .leading, spacing: 26) {
                            systemBlock
                            dataBlock
                        }
                    }
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(OpenBarTheme.canvas)
    }

    private var behaviorBlock: some View {
        settingsBlock(L("Behavior")) {
            SettingsToggleRow(
                title: L("Layout guardian"),
                subtitle: L("Repair confirmed layout drift in the background"),
                isOn: Binding(
                    get: { store.document.preferences.guardianEnabled },
                    set: { model.setGuardianEnabled($0) }
                )
            )
            SettingsToggleRow(
                title: L("Launch at login"),
                subtitle: L("Restore your menu bar after signing in"),
                isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { model.setLaunchAtLogin($0) }
                )
            )
            SettingsToggleRow(
                title: L("Show in Dock"),
                subtitle: L("Keep OPEN BAR alongside regular applications"),
                isOn: Binding(
                    get: { store.document.preferences.showInDock },
                    set: { model.setShowInDock($0) }
                )
            )
        }
    }

    private var appearanceBlock: some View {
        settingsBlock(L("Appearance")) {
            SettingsChoiceRow(title: L("Language")) {
                ForEach(AppLanguage.allCases) { language in
                    SettingsChip(
                        title: language.localizedTitle,
                        selected: store.document.preferences.language == language
                    ) { model.setLanguage(language) }
                }
            }
            SettingsChoiceRow(title: L("Appearance")) {
                ForEach(AppearancePreference.allCases) { appearance in
                    SettingsChip(
                        title: appearance.localizedTitle,
                        selected: store.document.preferences.appearance == appearance
                    ) { model.setAppearance(appearance) }
                }
            }
        }
    }

    private var systemBlock: some View {
        settingsBlock(L("System")) {
            SettingsValueRow(title: L("Backend"), value: model.backendName)
            SettingsValueRow(
                title: L("Accessibility"),
                value: model.hasAccessibilityPermission ? L("Granted") : L("Missing")
            )
            SettingsValueRow(
                title: L("macOS"),
                value: ProcessInfo.processInfo.operatingSystemVersionString
            )
            SettingsValueRow(
                title: L("Version"),
                value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
            )
        }
    }

    private var dataBlock: some View {
        settingsBlock(L("Data")) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Policy file")).font(.system(size: 13, weight: .medium))
                    Text(L("A readable, versioned record of every menu bar choice"))
                        .font(.system(size: 11))
                        .foregroundStyle(OpenBarTheme.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                GhostButton(title: L("Show in Finder")) { model.revealPolicyFile() }
            }
            .frame(minHeight: 48)

            Hairline()

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Activity log")).font(.system(size: 13, weight: .medium))
                    Text(L("Detailed events for troubleshooting"))
                        .font(.system(size: 11))
                        .foregroundStyle(OpenBarTheme.muted)
                }
                Spacer(minLength: 8)
                GhostButton(title: L("Open Activity")) { model.selectedPage = .activity }
            }
            .frame(minHeight: 48)
        }
    }

    private func settingsBlock<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OpenBarTheme.muted)
            Hairline()
            VStack(alignment: .leading, spacing: 0) { content() }
        }
    }
}

private struct AISettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: PolicyStore
    @StateObject private var state = AISettingsState()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsValueRow(title: L("Provider"), value: "DeepSeek")
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L("API Key")).font(.system(size: 13))
                    Spacer()
                    if model.hasAIAPIKey {
                        Text(L("Saved in Keychain"))
                            .font(.system(size: 11))
                            .foregroundStyle(OpenBarTheme.muted)
                    }
                }
                SecureField(
                    model.hasAIAPIKey ? L("Enter a new key to replace the saved key") : "sk-…",
                    text: $state.apiKey
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12).monospaced())
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(OpenBarTheme.control, in: RoundedRectangle(cornerRadius: OpenBarTheme.corner, style: .continuous))
            }
            labeledField(L("Model"), text: $state.modelName, placeholder: "deepseek-chat")
            labeledField(L("Base URL"), text: $state.baseURL, placeholder: "https://api.deepseek.com")
            HStack {
                Text(state.savedMessage ?? L("Your key stays in macOS Keychain and is sent only to your provider."))
                    .font(.system(size: 11))
                    .foregroundStyle(OpenBarTheme.muted)
                    .lineLimit(2)
                Spacer()
                if model.hasAIAPIKey {
                    GhostButton(title: L("Remove Key")) {
                        model.clearAIAPIKey()
                        state.apiKey = ""
                        state.savedMessage = L("API key removed")
                    }
                }
                QuietButton(title: L("Save AI Settings"), prominent: true) { save() }
            }
        }
        .onAppear {
            state.modelName = store.document.preferences.aiModel
            state.baseURL = store.document.preferences.aiBaseURL
        }
    }

    private func labeledField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13))
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12).monospaced())
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(OpenBarTheme.control, in: RoundedRectangle(cornerRadius: OpenBarTheme.corner, style: .continuous))
        }
    }

    private func save() {
        model.setAIProvider(.deepSeek)
        model.setAIModel(state.modelName)
        model.setAIBaseURL(state.baseURL)
        state.modelName = store.document.preferences.aiModel
        state.baseURL = store.document.preferences.aiBaseURL
        if state.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.savedMessage = L("AI settings saved")
        } else if model.saveAIAPIKey(state.apiKey) {
            state.apiKey = ""
            state.savedMessage = L("API key saved securely")
        } else {
            state.savedMessage = model.lastOperationMessage
        }
    }
}

private final class AISettingsState: ObservableObject {
    @Published var apiKey = ""
    @Published var modelName = "deepseek-chat"
    @Published var baseURL = "https://api.deepseek.com"
    @Published var savedMessage: String?
}

private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(OpenBarTheme.muted)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(OpenBarTheme.accent)
        }
        .padding(.vertical, 8)
    }
}

private struct SettingsChoiceRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13))
            HStack(spacing: 6) { content }
        }
        .padding(.vertical, 8)
    }
}

private struct SettingsChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @StateObject private var hover = OpenBarHoverState()

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? OpenBarTheme.accent : OpenBarTheme.label)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: OpenBarTheme.corner, style: .continuous)
                        .fill(selected ? OpenBarTheme.selection : (hover.isHovered ? OpenBarTheme.controlHover : OpenBarTheme.control))
                )
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovered = $0 }
    }
}

private struct SettingsValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            Text(value).font(.system(size: 12)).foregroundStyle(OpenBarTheme.muted).lineLimit(1)
        }
        .padding(.vertical, 8)
    }
}
