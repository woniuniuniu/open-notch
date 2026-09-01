import Darwin
import Foundation
import OpenBarCore

private var failures = 0
private var checks = 0

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

let firstOneDrive = ItemIdentityResolver.resolve(
    bundleIdentifier: "com.microsoft.OneDrive",
    semanticIdentifier: "Item-0",
    title: "OneDrive - Up to date"
)
let secondOneDrive = ItemIdentityResolver.resolve(
    bundleIdentifier: "com.microsoft.OneDrive",
    semanticIdentifier: "Item-9",
    title: "Syncing 14 files"
)
check(firstOneDrive?.stableID == "bundle:com.microsoft.OneDrive", "OneDrive uses bundle identity")
check(firstOneDrive?.stableID == secondOneDrive?.stableID, "OneDrive identity survives title changes")

let firstWeChatBadge = ItemIdentityResolver.resolve(
    bundleIdentifier: "com.tencent.xinWeChat",
    semanticIdentifier: "",
    title: "94",
    scopeToBundle: true
)
let secondWeChatBadge = ItemIdentityResolver.resolve(
    bundleIdentifier: "com.tencent.xinWeChat",
    semanticIdentifier: "",
    title: "99",
    scopeToBundle: true
)
check(firstWeChatBadge?.stableID == "bundle:com.tencent.xinWeChat", "macOS 27 uses app identity")
check(firstWeChatBadge?.stableID == secondWeChatBadge?.stableID, "dynamic badge titles do not duplicate apps")
let firstSemantic = ItemIdentityResolver.resolve(
    bundleIdentifier: "com.example.first",
    semanticIdentifier: "main",
    title: ""
)
let secondSemantic = ItemIdentityResolver.resolve(
    bundleIdentifier: "com.example.second",
    semanticIdentifier: "main",
    title: ""
)
check(firstSemantic?.stableID != secondSemantic?.stableID, "semantic IDs are bundle-scoped")

var tracker = DriftTracker()
let observation = ReconciliationObservation(
    itemID: "item",
    desired: .shown,
    actual: .hidden,
    guardsAgainstDrift: true
)
let start = Date(timeIntervalSince1970: 100)
check(tracker.observe([observation], now: start).isEmpty, "first drift sample does not repair")
check(
    tracker.observe([observation], now: start.addingTimeInterval(0.5)).isEmpty,
    "samples inside the minimum interval are ignored"
)
check(
    tracker.observe([observation], now: start.addingTimeInterval(1.1))
        == [ReconciliationIntent(itemID: "item", target: .shown)],
    "second separated drift sample creates one repair intent"
)

var disabledTracker = DriftTracker()
let disabledObservation = ReconciliationObservation(
    itemID: "item",
    desired: .shown,
    actual: .hidden,
    guardsAgainstDrift: false
)
check(
    disabledTracker.observe([disabledObservation], requiredObservations: 1).isEmpty,
    "per-item drift guard can be disabled"
)

let proposal = AIPlacementEngine.proposal(for: [
    .init(
        id: "one",
        name: "OneDrive",
        bundleIdentifier: "com.microsoft.OneDrive",
        currentSection: .hidden
    ),
    .init(
        id: "helper",
        name: "Example Updater",
        bundleIdentifier: "com.example.updater",
        currentSection: .shown
    ),
])
check(proposal != nil, "AI placement creates one proposal")
check(
    proposal?.decisions.first { $0.itemID == "one" }?.proposedSection == .shown,
    "AI placement keeps sync status visible"
)
check(
    proposal?.decisions.first { $0.itemID == "helper" }?.proposedSection == .alwaysHidden,
    "AI placement strongly hides background utilities"
)
check(
    proposal?.decisions.sorted { $0.proposedOrder < $1.proposedOrder }.first?.itemID == "one",
    "AI placement puts live status before background utilities"
)

let compactProposal = AIPlacementEngine.proposal(
    for: [
        .init(
            id: "battery",
            name: "Battery",
            bundleIdentifier: "com.apple.menuextra.battery",
            currentSection: .hidden
        ),
        .init(
            id: "sync",
            name: "Dropbox Sync",
            bundleIdentifier: "com.getdropbox.dropbox",
            currentSection: .shown
        ),
        .init(
            id: "wechat",
            name: "WeChat",
            bundleIdentifier: "com.tencent.xinWeChat",
            currentSection: .shown
        ),
    ],
    maxShownItems: 1
)
check(
    compactProposal?.decisions.first { $0.itemID == "battery" }?.proposedSection == .shown,
    "screen capacity never removes essential system status"
)
check(
    compactProposal?.decisions.first { $0.itemID == "sync" }?.proposedSection == .hidden,
    "small screens move lower-priority status on demand"
)
check(
    compactProposal?.decisions.first { $0.itemID == "wechat" }?.proposedSection == .alwaysHidden,
    "ordinary desktop apps do not consume menu bar capacity"
)

var document = PolicyDocument(
    schemaVersion: 0,
    policies: ["": ItemPolicy(), "valid": ItemPolicy(section: .hidden)],
    knownItems: [
        "bad": KnownItem(
            id: "bad",
            bundleIdentifier: "",
            semanticIdentifier: "",
            displayName: "Bad",
            symbolName: "app",
            lastSeen: .now
        ),
    ]
)
document.sanitize()
check(document.policies[""] == nil, "empty policy IDs are removed")
check(document.policies["valid"] != nil, "valid policies survive sanitation")
check(document.knownItems.isEmpty, "known items without bundle IDs are removed")
check(document.schemaVersion == PolicyDocument.currentSchemaVersion, "schema is upgraded")

if failures == 0 {
    print("OpenBarCoreChecks: \(checks) checks passed")
} else {
    fputs("OpenBarCoreChecks: \(failures) checks failed\n", stderr)
    exit(1)
}
