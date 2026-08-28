import AppKit
import SwiftUI

struct HiddenItemsShelfView: View {
    let items: [MenuBarItem]
    let onActivate: (MenuBarItem) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if items.isEmpty {
                Text(L("No hidden items"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(items) { item in
                            Button { onActivate(item) } label: {
                                ShelfItemIcon(item: item)
                                    .frame(width: 28, height: 28)
                                    .padding(5)
                                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help(item.displayName)
                        }
                    }
                    .padding(.horizontal, 7)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.20), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 16, y: 6)
    }
}

struct MoreCapsuleView: View {
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            Text(L("More"))
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().stroke(.white.opacity(0.20), lineWidth: 1) }
        .shadow(color: .black.opacity(0.24), radius: 14, y: 5)
    }
}

private struct ShelfItemIcon: View {
    let item: MenuBarItem

    var body: some View {
        Group {
            if let icon = applicationIcon {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: item.symbolName)
                    .resizable().scaledToFit().padding(4)
                    .foregroundStyle(.primary)
            }
        }
    }

    private var applicationIcon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: item.semanticBundleIdentifier
        ) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 32, height: 32)
        return image
    }
}
