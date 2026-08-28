import AppKit

@MainActor
final class HiddenItemsBarView: NSView {
    private final class ActionTarget: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func invoke() { action() }
    }

    private final class HoverButton: NSButton {
        private var tracking: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let next = NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(next)
            tracking = next
        }

        override func mouseEntered(with event: NSEvent) {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
        }

        override func mouseExited(with event: NSEvent) {
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        override func mouseDown(with event: NSEvent) {
            animator().alphaValue = 0.65
            super.mouseDown(with: event)
            animator().alphaValue = 1
        }
    }

    private var actionTargets = [ActionTarget]()

    init(
        frame: NSRect,
        items: [MenuBarItem],
        activate: @escaping (MenuBarItem) -> Void,
        manage: @escaping () -> Void
    ) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        let glassFrame = bounds.insetBy(dx: 3, dy: 3)
        let glass = NSVisualEffectView(frame: glassFrame)
        glass.autoresizingMask = [.width, .height]
        glass.material = .menu
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.alphaValue = 0.84
        glass.wantsLayer = true
        glass.layer?.cornerRadius = glassFrame.height / 2
        glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 0.75
        glass.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        addSubview(glass)

        let manageSize: CGFloat = 24
        let manageFrame = NSRect(
            x: glass.bounds.maxX - manageSize - 5,
            y: (glass.bounds.height - manageSize) / 2,
            width: manageSize,
            height: manageSize
        )
        let manageButton = makeButton(
            frame: manageFrame,
            image: NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: L("Manage Items")),
            label: L("Manage Items"),
            action: manage
        )
        manageButton.autoresizingMask = [.minXMargin]
        glass.addSubview(manageButton)

        let separator = NSView(frame: NSRect(
            x: manageFrame.minX - 7,
            y: 8,
            width: 1,
            height: glass.bounds.height - 16
        ))
        separator.autoresizingMask = [.minXMargin]
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.13).cgColor
        glass.addSubview(separator)

        let scrollFrame = NSRect(
            x: 5,
            y: 2,
            width: max(1, separator.frame.minX - 9),
            height: glass.bounds.height - 4
        )
        let scroll = NSScrollView(frame: scrollFrame)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .automatic
        scroll.verticalScrollElasticity = .none
        glass.addSubview(scroll)

        let itemWidth: CGFloat = 30
        let documentWidth = max(scrollFrame.width, CGFloat(items.count) * itemWidth)
        let document = NSView(frame: NSRect(x: 0, y: 0, width: documentWidth, height: scrollFrame.height))
        document.wantsLayer = true
        document.layer?.backgroundColor = NSColor.clear.cgColor
        scroll.documentView = document

        if items.isEmpty {
            let empty = NSTextField(labelWithString: L("No hidden items"))
            empty.textColor = .secondaryLabelColor
            empty.font = .systemFont(ofSize: 12, weight: .medium)
            empty.sizeToFit()
            empty.frame.origin = NSPoint(x: 8, y: (document.bounds.height - empty.frame.height) / 2)
            document.addSubview(empty)
        } else {
            for (index, item) in items.enumerated() {
                let icon = ApplicationIconResolver.shared.statusBarSymbol(for: item)
                    ?? NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: item.displayName)
                let button = makeButton(
                    frame: NSRect(x: CGFloat(index) * itemWidth + 1, y: 1, width: 28, height: 28),
                    image: icon,
                    label: item.displayName,
                    action: { activate(item) }
                )
                document.addSubview(button)
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    private func makeButton(
        frame: NSRect,
        image: NSImage?,
        label: String,
        action: @escaping () -> Void
    ) -> NSButton {
        let button = HoverButton(frame: frame)
        button.isBordered = false
        button.image = image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.wantsLayer = true
        button.layer?.cornerRadius = min(frame.width, frame.height) / 2
        let target = ActionTarget(action)
        actionTargets.append(target)
        button.target = target
        button.action = #selector(ActionTarget.invoke)
        return button
    }
}
