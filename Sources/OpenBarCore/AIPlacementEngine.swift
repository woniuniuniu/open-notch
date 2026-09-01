import Foundation

public struct AIPlacementItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let bundleIdentifier: String
    public let currentSection: ItemSection

    public init(id: String, name: String, bundleIdentifier: String, currentSection: ItemSection) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.currentSection = currentSection
    }
}

public struct AIPlacementDecision: Identifiable, Equatable, Sendable {
    public var id: String { itemID }
    public let itemID: String
    public let currentSection: ItemSection
    public let currentOrder: Int
    public let proposedSection: ItemSection
    public let proposedOrder: Int
    public let rationaleKey: String

    public init(
        itemID: String,
        currentSection: ItemSection,
        currentOrder: Int,
        proposedSection: ItemSection,
        proposedOrder: Int,
        rationaleKey: String
    ) {
        self.itemID = itemID
        self.currentSection = currentSection
        self.currentOrder = currentOrder
        self.proposedSection = proposedSection
        self.proposedOrder = proposedOrder
        self.rationaleKey = rationaleKey
    }
}

public struct AIPlacementProposal: Identifiable, Equatable, Sendable {
    public let id: String
    public let decisions: [AIPlacementDecision]

    public init(id: String = UUID().uuidString, decisions: [AIPlacementDecision]) {
        self.id = id
        self.decisions = decisions
    }
}

public enum AIPlacementEngine {
    private struct ClassifiedItem {
        let item: AIPlacementItem
        let section: ItemSection
        let priority: Int
        let rationaleKey: String
    }

    public static func proposal(
        for items: [AIPlacementItem],
        maxShownItems: Int? = nil
    ) -> AIPlacementProposal? {
        guard !items.isEmpty else { return nil }

        let currentOrders = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
        var classified = items.map(classify).sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.item.name.localizedStandardCompare($1.item.name) == .orderedAscending
        }
        if let maxShownItems {
            let essentialCount = classified.filter { $0.section == .shown && $0.priority == 0 }.count
            var remaining = max(0, maxShownItems - essentialCount)
            classified = classified.map { result in
                guard result.section == .shown, result.priority > 0 else { return result }
                guard remaining > 0 else {
                    return ClassifiedItem(
                        item: result.item,
                        section: .hidden,
                        priority: 2,
                        rationaleKey: "Limited by this screen's menu bar capacity"
                    )
                }
                remaining -= 1
                return result
            }
            classified.sort {
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                return $0.item.name.localizedStandardCompare($1.item.name) == .orderedAscending
            }
        }
        let decisions = classified.enumerated().map { index, result in
            AIPlacementDecision(
                itemID: result.item.id,
                currentSection: result.item.currentSection,
                currentOrder: currentOrders[result.item.id] ?? index,
                proposedSection: result.section,
                proposedOrder: index,
                rationaleKey: result.rationaleKey
            )
        }
        return AIPlacementProposal(decisions: decisions)
    }

    private static func classify(_ item: AIPlacementItem) -> ClassifiedItem {
        let value = (item.name + " " + item.bundleIdentifier).lowercased()
        if containsAny(value, [
            "battery", "wifi", "wi-fi", "clock", "controlcenter", "control center",
            "bluetooth", "sound", "audio", "vpn", "surge", "keyboard", "input method",
            "screen mirroring", "focus", "privacy", "security",
        ]) {
            return .init(
                item: item,
                section: .shown,
                priority: 0,
                rationaleKey: "Essential system status"
            )
        }
        if containsAny(value, ["onedrive", "dropbox", "icloud", "sync"]) {
            return .init(
                item: item,
                section: .shown,
                priority: 1,
                rationaleKey: "Live sync status"
            )
        }
        if containsAny(value, [
            "updater", "helper", "launcher", "cleaner", "telemetry", "monitor",
            "setapp", "daemon",
        ]) {
            return .init(
                item: item,
                section: .alwaysHidden,
                priority: 3,
                rationaleKey: "Background utility"
            )
        }
        if containsAny(value, [
            "wechat", "weixin", "chatgpt", "safari", "chrome", "firefox", "edge",
            "mail", "outlook", "word", "excel", "powerpoint", "notion", "slack",
            "teams", "zoom", "discord",
        ]) {
            return .init(
                item: item,
                section: .alwaysHidden,
                priority: 4,
                rationaleKey: "Routine app with no frequent menu bar action"
            )
        }
        if containsAny(value, [
            "clipboard", "paste", "screenshot", "capture", "window", "download",
            "remote", "shelf", "calendar", "weather",
        ]) {
            return .init(
                item: item,
                section: .hidden,
                priority: 2,
                rationaleKey: "Useful occasionally, available on demand"
            )
        }
        return .init(
            item: item,
            section: .hidden,
            priority: 2,
            rationaleKey: "Available on demand"
        )
    }

    private static func containsAny(_ value: String, _ tokens: [String]) -> Bool {
        tokens.contains { value.contains($0) }
    }
}
