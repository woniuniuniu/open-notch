import AppKit
import ServiceManagement
import SwiftUI

struct SettingsRootView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedPane) {
                Section("Open Notch") {
                    ForEach(SettingsPane.allCases) { pane in
                        Label(pane.title, systemImage: pane.symbolName)
                            .tag(pane)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 184, ideal: 204, max: 232)
            .safeAreaInset(edge: .bottom) {
                SidebarStatus()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        } detail: {
            switch model.selectedPane ?? .overview {
            case .overview: OverviewPane()
            case .menuItems: MenuItemsPane()
            case .oneDrive: OneDrivePane()
            case .general: GeneralPane()
            case .about: AboutPane()
            }
        }
        .frame(minWidth: 820, minHeight: 540)
        .id(settings.language)
    }
}

private struct SidebarStatus: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Label(
            model.hasAccessibilityPermission ? L("Accessibility access granted") : L("Accessibility access required"),
            systemImage: model.hasAccessibilityPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(model.hasAccessibilityPermission ? Color.secondary : Color.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NativePage<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 14)

            Divider()

            Form {
                content
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PermissionBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GroupBox {
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(L("Recheck")) { model.recheckAccessibilityPermission() }
                    .systemGlassButton()
                Button(L("Open System Settings")) { model.requestAccessibilityPermission() }
                    .systemGlassButton(prominent: true)
            }
        } label: {
            Label(L("Accessibility access required"), systemImage: "hand.raised.fill")
                .fontWeight(.medium)
        }
    }
}

private struct OverviewPane: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        NativePage(title: L("Overview"), subtitle: "Open Notch") {
            if !model.hasAccessibilityPermission {
                PermissionBanner()
            }

            Section(L("Menu Bar")) {
                LabeledContent(L("Keep Visible"), value: "\(model.visibleItems.count)")
                LabeledContent(L("Set to Hidden"), value: "\(model.hiddenItems.count)")
                LabeledContent(L("Current Status"), value: settings.isExpanded ? L("Hidden section expanded") : L("Hidden section collapsed"))
                HStack {
                    Label(L("Hidden Section"), systemImage: settings.isExpanded ? "eye" : "eye.slash")
                    Spacer()
                    Button(settings.isExpanded ? L("Collapse") : L("Expand")) { model.toggleExpanded() }
                        .systemGlassButton()
                }
            }

            Section("OneDrive") {
                LabeledContent(L("Identification"), value: model.oneDriveItem == nil ? L("Not Found") : L("Identified"))
                LabeledContent(L("Pinning"), value: settings.oneDriveGuardianEnabled ? L("On") : L("Off"))
                HStack {
                    Label("OneDrive", systemImage: "cloud.fill")
                    Spacer()
                    Button(L("Reset Now")) { model.repairOneDriveNow() }
                        .systemGlassButton()
                        .disabled(model.oneDriveItem == nil || !model.hasAccessibilityPermission)
                }
            }

            if let event = model.guardianEvents.first {
                Section(L("Recent Activity")) {
                    LabeledContent(event.message) {
                        Text(event.date, style: .time)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(L("Overview"))
    }
}

private struct MenuItemsPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if !model.hasAccessibilityPermission {
                VStack(alignment: .leading, spacing: 14) {
                    PermissionBanner()
                    Spacer()
                }
                .padding(20)
            } else if model.filteredItems.isEmpty {
                ContentUnavailableView(L("No manageable items"), systemImage: "menubar.rectangle")
            } else {
                List(model.filteredItems) { item in
                    MenuItemRow(item: item)
                        .padding(.vertical, 6)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(L("Menu Bar Items"))
        .searchable(text: $model.searchText, placement: .toolbar, prompt: L("Search items"))
        .toolbar {
            ToolbarItem {
                if model.isScanning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        model.refresh(reason: L("Manual scan"), reconcile: false)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help(L("Rescan"))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(LF("%d manageable items", model.filteredItems.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

private struct MenuItemRow: View {
    @EnvironmentObject private var model: AppModel
    let item: MenuBarItem

    var body: some View {
        HStack(spacing: 11) {
            MenuItemIcon(item: item)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if item.isOneDrive {
                        Text(L("Always Pinned"))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(item.detail.isEmpty ? item.semanticBundleIdentifier : item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Picker(L("Position"), selection: Binding(
                get: { model.disposition(for: item) },
                set: { model.setDisposition($0, for: item) }
            )) {
                ForEach(ItemDisposition.allCases) { disposition in
                    Text(disposition.title).tag(disposition)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 132)
            .disabled(item.isOneDrive && SettingsStore.shared.oneDriveGuardianEnabled)
        }
        .accessibilityElement(children: .contain)
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
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct OneDrivePane: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        NativePage(title: "OneDrive", subtitle: L("Dynamic menu bar item guardian")) {
            if !model.hasAccessibilityPermission {
                PermissionBanner()
            }

            Section(L("Status")) {
                HStack {
                    Label(model.oneDriveItem == nil ? L("OneDrive item not found") : L("OneDrive pinned"), systemImage: "cloud.fill")
                    Spacer()
                    Button(L("Reset Now")) { model.repairOneDriveNow() }
                        .systemGlassButton()
                        .disabled(model.oneDriveItem == nil || !model.hasAccessibilityPermission)
                }
                if let oneDrive = model.oneDriveItem {
                    LabeledContent(L("Current Window"), value: "#\(oneDrive.windowID)")
                    LabeledContent(L("Host Process"), value: oneDrive.hostBundleIdentifier)
                }
            }

            Section(L("Guardian")) {
                Toggle(L("Keep OneDrive pinned"), isOn: Binding(
                    get: { settings.oneDriveGuardianEnabled },
                    set: { _ in model.toggleGuardian() }
                ))
                LabeledContent(L("Automatic reset count"), value: "\(settings.repairCount)")
            }

            if !model.guardianEvents.isEmpty {
                Section(L("Recent Events")) {
                    ForEach(model.guardianEvents) { event in
                        LabeledContent(event.message) {
                            Text(event.date, style: .time)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("OneDrive")
    }
}

private struct GeneralPane: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        NativePage(title: L("General")) {
            Section(L("Interface")) {
                Picker(L("Language"), selection: Binding(
                    get: { settings.language },
                    set: { model.setLanguage($0) }
                )) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.nativeName).tag(language)
                    }
                }

                Picker(L("Appearance"), selection: Binding(
                    get: { settings.appearanceMode },
                    set: { model.setAppearance($0) }
                )) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section(L("Operation")) {
                Toggle(L("Open at Login"), isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Toggle(L("Automatically restore menu bar layout"), isOn: Binding(
                    get: { settings.continuousMonitorEnabled },
                    set: { model.setContinuousMonitor($0) }
                ))
            }

            Section(L("Permission")) {
                LabeledContent(L("Accessibility")) {
                    Label(
                        model.hasAccessibilityPermission ? L("Authorized") : L("Not Authorized"),
                        systemImage: model.hasAccessibilityPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(model.hasAccessibilityPermission ? Color.green : Color.orange)
                }
                HStack {
                    Spacer()
                    Button(L("Recheck")) { model.recheckAccessibilityPermission() }
                        .systemGlassButton()
                    Button(L("Open System Settings")) { model.requestAccessibilityPermission() }
                        .systemGlassButton(prominent: true)
                }
            }
        }
        .navigationTitle(L("General"))
    }
}

private struct AboutPane: View {
    var body: some View {
        NativePage(title: L("About")) {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Open Notch")
                            .font(.title3.weight(.semibold))
                        Text(L("Open-source menu bar manager"))
                            .foregroundStyle(.secondary)
                        Text(LF("Version %@ (%@)", Bundle.main.shortVersion, Bundle.main.buildVersion))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section(L("Project")) {
                LabeledContent(L("Bundle Identifier"), value: "com.openbartender.OpenNotch")
                LabeledContent(L("Minimum System"), value: "macOS 14")
                LabeledContent(L("License"), value: "GNU GPL v3")
            }

            Section(L("Legal")) {
                Text(L("This program comes with absolutely no warranty. You may redistribute it under GNU GPL v3."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(L("View License")) { openBundledDocument(resource: "LICENSE", extension: nil) }
                        .systemGlassButton()
                    Button(L("View Notices")) { openBundledDocument(resource: "NOTICE", extension: "md") }
                        .systemGlassButton()
                }
            }
        }
        .navigationTitle(L("About"))
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
