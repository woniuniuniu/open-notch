import AppKit
import OpenBarCore
import SwiftUI

struct QuickBarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: PolicyStore

    private var hiddenItems: [ManagedMenuBarItem] {
        // A hidden policy can outlive its app. Keep that policy in the main
        // workspace, but never put an offline historical record in the live
        // quick bar or claim it is available right now.
        model.quickBarItems.filter {
            $0.isRunning && store.section(for: $0.id) == .hidden && $0.id != StatusBarController.toggleID
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                if hiddenItems.isEmpty {
                    Text(L("No hidden items available")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(hiddenItems) { item in
                    QuickBarItem(item: item)
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 40)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct QuickBarItem: View {
    @EnvironmentObject private var model: AppModel
    let item: ManagedMenuBarItem
    @StateObject private var hover = OpenBarHoverState()

    var body: some View {
        Button { model.activateItem(item) } label: {
        Group {
            if let image = ApplicationIconResolver.shared.icon(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: ApplicationIconResolver.shared.symbolName(for: item))
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .frame(width: 18, height: 18)
        .frame(width: 28, height: 28)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(hover.isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .background {
            HoverNamePopover(
                title: item.localizedDisplayName,
                isPresented: $hover.isHovered
            )
        }
        .onHover { hover.isHovered = $0 }
        .help(item.localizedDisplayName)
        .zIndex(hover.isHovered ? 10 : 0)
        }.buttonStyle(.plain)
    }
}
