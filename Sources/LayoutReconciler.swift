import Foundation

struct LayoutMoveIntent {
    let item: MenuBarItem
    let disposition: ItemDisposition
}

struct LayoutReconciler {
    private struct Evidence {
        var count: Int
        var lastObservation: Date
    }

    private var evidenceByItemID = [String: Evidence]()

    mutating func observe(
        items: [MenuBarItem],
        boundary: CGRect,
        desiredPositions: [String: ItemDisposition],
        now: Date = .now,
        minimumObservations: Int = 2,
        minimumInterval: TimeInterval = 1
    ) -> LayoutMoveIntent? {
        var activeItemIDs = Set<String>()
        var firstIntent: LayoutMoveIntent?

        for item in items where !item.isProtected {
            guard let disposition = desiredPositions[item.id] else { continue }
            activeItemIDs.insert(item.id)

            if Self.isInSection(item.frame, disposition: disposition, boundary: boundary) {
                evidenceByItemID[item.id] = nil
                continue
            }

            var evidence = evidenceByItemID[item.id] ?? Evidence(count: 0, lastObservation: .distantPast)
            if now.timeIntervalSince(evidence.lastObservation) >= minimumInterval {
                evidence.count += 1
                evidence.lastObservation = now
                evidenceByItemID[item.id] = evidence
            }

            if evidence.count >= minimumObservations, firstIntent == nil {
                firstIntent = LayoutMoveIntent(item: item, disposition: disposition)
            }
        }

        evidenceByItemID = evidenceByItemID.filter { activeItemIDs.contains($0.key) }
        return firstIntent
    }

    mutating func reset(_ itemID: String) {
        evidenceByItemID[itemID] = nil
    }

    mutating func resetAll() {
        evidenceByItemID.removeAll()
    }

    static func isInSection(_ frame: CGRect, disposition: ItemDisposition, boundary: CGRect) -> Bool {
        switch disposition {
        case .visible: frame.minX >= boundary.maxX - 2
        case .hidden: frame.maxX <= boundary.minX + 2
        }
    }
}
