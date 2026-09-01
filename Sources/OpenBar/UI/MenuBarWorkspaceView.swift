import AppKit
import OpenBarCore
import SwiftUI
import UniformTypeIdentifiers

struct MenuBarWorkspaceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Hairline()

            if !model.canManage {
                WorkspacePermissionStrip()
                Hairline()
            }

            VStack(spacing: 0) {
                ForEach(Array(ItemSection.allCases.enumerated()), id: \.element) { index, section in
                    ItemLane(
                        section: section,
                        items: laneItems(section)
                    )
                    if index < ItemSection.allCases.count - 1 {
                        Hairline()
                    }
                }
                Spacer(minLength: 0)
            }

            if let message = model.lastOperationMessage {
                Hairline()
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(OpenBarTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .frame(height: 32)
            }
        }
        .background(Color.clear)
    }

    private var workspaceHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Your menu bar"))
                    .font(.system(size: 18, weight: .semibold))
                Text(LF("%d current items", model.currentItemCount))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(OpenBarTheme.muted)
            }
            Spacer()
            searchField
            QuietButton(
                title: model.isAIPlacementLoading ? L("AI is planning") : L("Arrange with AI"),
                systemName: model.isAIPlacementLoading ? nil : "sparkles",
                prominent: true,
                enabled: !model.isAIPlacementLoading && !model.managedItems.isEmpty
            ) {
                model.prepareAIPlacement()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(OpenBarTheme.muted)
            TextField(L("Search menu bar items"), text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(OpenBarTheme.muted)
                }
                .buttonStyle(.plain)
                .help(L("Clear Search"))
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 220, height: 32)
        .background(
            RoundedRectangle(cornerRadius: OpenBarTheme.corner, style: .continuous)
                .fill(OpenBarTheme.control)
        )
        .overlay {
            RoundedRectangle(cornerRadius: OpenBarTheme.corner, style: .continuous)
                .stroke(OpenBarTheme.glassStroke.opacity(0.45), lineWidth: 1)
        }
    }

    private func laneItems(_ section: ItemSection) -> [ManagedMenuBarItem] {
        let items = model.items(in: section)
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.localizedDisplayName.localizedCaseInsensitiveContains(query)
                || $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }
    }
}

private struct ItemLane: View {
    @EnvironmentObject private var model: AppModel
    let section: ItemSection
    let items: [ManagedMenuBarItem]
    @StateObject private var interaction = LaneInteraction()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(OpenBarTheme.tint(for: section))
                    .frame(width: 7, height: 7)
                Text(section.localizedTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OpenBarTheme.label)
                Text(section.localizedSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(OpenBarTheme.muted)
                    .lineLimit(1)
                Spacer()
                Text("\(items.count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(OpenBarTheme.muted)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(OpenBarTheme.control, in: Capsule())
            }

            if items.isEmpty {
                Text(L("Drop items here"))
                    .font(.system(size: 12))
                    .foregroundStyle(OpenBarTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 48, maximum: 64), spacing: 10)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(items) { item in
                        LaneIcon(item: item, section: section)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        .background(
            interaction.dropTargeted
                ? OpenBarTheme.selection
                : (interaction.hovered ? OpenBarTheme.contentWashHovered : OpenBarTheme.contentWash)
        )
        .overlay {
            Rectangle()
                .stroke(interaction.dropTargeted ? OpenBarTheme.accent.opacity(0.70) : Color.clear, lineWidth: 1)
        }
        .onDrop(of: [UTType.text], isTargeted: $interaction.dropTargeted) { providers, _ in
            guard model.canManage, let provider = providers.first else { return false }
            provider.loadObject(ofClass: NSString.self) { object, _ in
                let rawID: String?
                if let value = object as? NSString {
                    rawID = value as String
                } else {
                    rawID = object as? String
                }
                guard let rawID else { return }
                DispatchQueue.main.async {
                    guard let item = model.managedItem(id: rawID),
                          model.store.section(for: item.id) != section
                    else { return }
                    model.moveItem(id: item.id, to: section)
                }
            }
            return true
        }
        .onHover { interaction.hovered = $0 }
        .animation(.easeOut(duration: 0.18), value: interaction.hovered)
        .animation(.easeOut(duration: 0.18), value: interaction.dropTargeted)
    }
}

private struct LaneIcon: View {
    @EnvironmentObject private var model: AppModel
    let item: ManagedMenuBarItem
    let section: ItemSection
    @StateObject private var hover = OpenBarHoverState()

    var body: some View {
        icon
            .frame(width: OpenBarTheme.laneIconTile, height: OpenBarTheme.laneIconTile)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(hover.isHovered ? OpenBarTheme.controlHover : Color.clear)
            )
            .scaleEffect(hover.isHovered ? 1.08 : 1)
            .background {
                HoverNamePopover(
                    title: item.localizedDisplayName,
                    isPresented: $hover.isHovered
                )
            }
            .onHover { hover.isHovered = $0 }
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: hover.isHovered)
            .onDrag {
                let provider = NSItemProvider(object: NSString(string: item.id))
                provider.suggestedName = item.localizedDisplayName
                return provider
            } preview: {
                HStack(spacing: 6) {
                    icon
                    Text(item.localizedDisplayName)
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(OpenBarTheme.glassStroke, lineWidth: 1)
                }
            }
            .contextMenu {
                ForEach(ItemSection.allCases) { target in
                    Button(target.localizedTitle) { model.moveItem(id: item.id, to: target) }
                        .disabled(target == section || !model.canManage)
                }
            }
            .help(item.localizedDisplayName)
            .zIndex(hover.isHovered ? 10 : 0)
    }

    @ViewBuilder
    private var icon: some View {
        if let image = ApplicationIconResolver.shared.icon(for: item) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: OpenBarTheme.laneIconSize, height: OpenBarTheme.laneIconSize)
        } else {
            Image(systemName: ApplicationIconResolver.shared.symbolName(for: item))
                .font(.system(size: OpenBarTheme.laneSymbolSize, weight: .medium))
                .foregroundStyle(OpenBarTheme.label.opacity(0.78))
                .frame(width: OpenBarTheme.laneIconSize, height: OpenBarTheme.laneIconSize)
        }
    }
}

private final class LaneInteraction: ObservableObject {
    @Published var hovered = false
    @Published var dropTargeted = false
}

private struct WorkspacePermissionStrip: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Text(L("Accessibility permission required"))
                .font(.system(size: 12, weight: .medium))
            Text(L("OPEN BAR uses Accessibility only to identify and arrange menu bar items."))
                .font(.system(size: 12))
                .foregroundStyle(OpenBarTheme.muted)
                .lineLimit(1)
            Spacer()
            GhostButton(title: L("Open System Settings")) { model.requestAccessibilityPermission() }
            QuietButton(title: L("Recheck"), prominent: true) { model.recheckAccessibilityPermission() }
        }
        .padding(.horizontal, 24)
        .frame(minHeight: 40)
        .background(OpenBarTheme.danger.opacity(0.06))
    }
}
