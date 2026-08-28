import AppKit
import Foundation

enum ItemDisposition: String, CaseIterable, Codable, Identifiable {
    case visible
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .visible: L("Visible")
        case .hidden: L("Hidden")
        }
    }
}

struct MenuBarItem: Identifiable, Equatable {
    let id: String
    let windowID: CGWindowID
    let hostPID: pid_t
    let hostBundleIdentifier: String
    let semanticBundleIdentifier: String
    let semanticIdentifier: String
    let rawTitle: String
    let displayName: String
    let symbolName: String
    let frame: CGRect
    let isProtected: Bool

    var isOneDrive: Bool {
        semanticBundleIdentifier == "com.microsoft.OneDrive"
    }

    var isOpenNotchControl: Bool {
        semanticIdentifier.contains("OpenNotch.Toggle") || rawTitle.contains("OpenNotch.Toggle")
    }

    var isAnonymousControlCenterItem: Bool {
        semanticBundleIdentifier == "com.apple.controlcenter" && semanticIdentifier.isEmpty
    }

    var hasUnknownHostIdentity: Bool {
        semanticBundleIdentifier.hasPrefix("unknown.")
    }

    var detail: String {
        if isOneDrive {
            return rawTitle.split(separator: "\n").dropFirst().joined(separator: " ")
        }
        if !semanticIdentifier.isEmpty {
            return semanticIdentifier
        }
        return semanticBundleIdentifier
    }
}

struct KnownMenuBarItem: Codable, Equatable, Identifiable {
    let id: String
    var displayName: String
    var detail: String
    var symbolName: String
    var semanticBundleIdentifier: String
    var lastSeen: Date
}

struct PersistedWindowBinding: Codable, Equatable {
    let stableID: String
    let displayName: String
    let symbolName: String
    let semanticBundleIdentifier: String
    let semanticIdentifier: String
    let rawTitle: String
    let isProtected: Bool
}

struct GuardianEvent: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let message: String
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case overview
    case menuItems
    case oneDrive
    case general
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: L("Overview")
        case .menuItems: L("Menu Bar Items")
        case .oneDrive: "OneDrive"
        case .general: L("General")
        case .about: L("About")
        }
    }

    var symbolName: String {
        switch self {
        case .overview: "rectangle.topthird.inset.filled"
        case .menuItems: "menubar.rectangle"
        case .oneDrive: "cloud.fill"
        case .general: "gearshape"
        case .about: "info.circle"
        }
    }
}
