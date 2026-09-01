import Foundation

public struct ReconciliationObservation: Equatable, Sendable {
    public let itemID: String
    public let desired: ItemSection
    public let actual: ItemSection
    public let guardsAgainstDrift: Bool

    public init(itemID: String, desired: ItemSection, actual: ItemSection, guardsAgainstDrift: Bool) {
        self.itemID = itemID
        self.desired = desired
        self.actual = actual
        self.guardsAgainstDrift = guardsAgainstDrift
    }
}

public struct ReconciliationIntent: Equatable, Sendable {
    public let itemID: String
    public let target: ItemSection

    public init(itemID: String, target: ItemSection) {
        self.itemID = itemID
        self.target = target
    }
}

/// Converts noisy menu-bar observations into deliberate repair intents.
/// A mismatch must be observed twice with enough time between samples.
public struct DriftTracker: Sendable {
    private struct Evidence: Sendable {
        var count: Int
        var lastObservation: Date
        var lastRepair: Date?
    }

    private var evidence: [String: Evidence] = [:]

    public init() {}

    public mutating func observe(
        _ observations: [ReconciliationObservation],
        now: Date = .now,
        requiredObservations: Int = 2,
        minimumSampleInterval: TimeInterval = 1,
        repairCooldown: TimeInterval = 8
    ) -> [ReconciliationIntent] {
        var activeIDs = Set<String>()
        var intents: [ReconciliationIntent] = []

        for observation in observations where observation.guardsAgainstDrift {
            activeIDs.insert(observation.itemID)
            if observation.actual == observation.desired {
                evidence[observation.itemID] = nil
                continue
            }

            var itemEvidence = evidence[observation.itemID] ?? Evidence(
                count: 0,
                lastObservation: .distantPast,
                lastRepair: nil
            )
            guard now.timeIntervalSince(itemEvidence.lastObservation) >= minimumSampleInterval else {
                continue
            }
            itemEvidence.count += 1
            itemEvidence.lastObservation = now

            let cooledDown = itemEvidence.lastRepair.map {
                now.timeIntervalSince($0) >= repairCooldown
            } ?? true
            if itemEvidence.count >= requiredObservations, cooledDown {
                intents.append(.init(itemID: observation.itemID, target: observation.desired))
                itemEvidence.count = 0
                itemEvidence.lastRepair = now
            }
            evidence[observation.itemID] = itemEvidence
        }

        evidence = evidence.filter { activeIDs.contains($0.key) }
        return intents
    }

    public mutating func reset() {
        evidence.removeAll()
    }
}
