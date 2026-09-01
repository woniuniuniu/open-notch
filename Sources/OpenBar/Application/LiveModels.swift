import AppKit
import Foundation
import OpenBarCore

struct LiveMenuBarItem: Identifiable, Equatable {
    let id: String
    let windowID: CGWindowID
    let hostPID: pid_t
    let hostBundleIdentifier: String
    let bundleIdentifier: String
    let semanticIdentifier: String
    let rawTitle: String
    let displayName: String
    let symbolName: String
    let frame: CGRect
    let isProtected: Bool
    let actualSection: ItemSection?

    var knownItem: KnownItem {
        KnownItem(
            id: id,
            bundleIdentifier: bundleIdentifier,
            semanticIdentifier: semanticIdentifier,
            displayName: displayName,
            symbolName: symbolName,
            lastSeen: .now
        )
    }
}

struct ManagedMenuBarItem: Identifiable, Equatable {
    let id: String
    let bundleIdentifier: String
    let semanticIdentifier: String
    let displayName: String
    let symbolName: String
    let isRunning: Bool
    let liveItem: LiveMenuBarItem?
}

enum NavigationPage: String, CaseIterable, Identifiable {
    case items
    case activity
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .items: L("Menu Bar")
        case .activity: L("Activity")
        case .settings: L("Settings")
        }
    }

    var symbol: String {
        switch self {
        case .items: "menubar.rectangle"
        case .activity: "waveform.path.ecg"
        case .settings: "gearshape"
        }
    }
}

enum ApplyReason {
    case user(itemID: String)
    case expansion
    case guardian
    case startup
    case aiPlacement
}

struct BackendApplyResult {
    let accepted: Bool
    let message: String
}
