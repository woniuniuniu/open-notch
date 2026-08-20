// WindowServer menu bar enumeration adapted from Ice and Thaw.
// Copyright (Ice) 2023-2025 Jordan Baird
// Copyright (Thaw) 2026 Toni Forster
// Licensed under GNU GPL v3.

import CoreGraphics
import Foundation

private typealias CGSConnectionID = Int32

@_silgen_name("CGSMainConnectionID")
private func cgsMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSGetWindowCount")
private func cgsGetWindowCount(
    _ connection: CGSConnectionID,
    _ targetConnection: CGSConnectionID,
    _ count: inout Int32
) -> CGError

@_silgen_name("CGSGetProcessMenuBarWindowList")
private func cgsGetProcessMenuBarWindowList(
    _ connection: CGSConnectionID,
    _ targetConnection: CGSConnectionID,
    _ count: Int32,
    _ list: UnsafeMutablePointer<CGWindowID>,
    _ outCount: inout Int32
) -> CGError

@_silgen_name("CGSGetWindowLevel")
private func cgsGetWindowLevel(
    _ connection: CGSConnectionID,
    _ windowID: CGWindowID,
    _ level: inout CGWindowLevel
) -> CGError

enum WindowServerBridge {
    static var usesIndividualWindowEnumeration: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    static var enumerationName: String {
        usesIndividualWindowEnumeration ? "WindowServer CGS (experimental macOS 27)" : "CoreGraphics public inventory"
    }

    static func individualMenuBarWindowIDs() -> [CGWindowID] {
        var count: Int32 = 0
        let connection = cgsMainConnectionID()
        guard cgsGetWindowCount(connection, 0, &count) == .success, count > 0 else { return [] }

        var windowIDs = [CGWindowID](repeating: 0, count: Int(count))
        guard cgsGetProcessMenuBarWindowList(connection, 0, count, &windowIDs, &count) == .success else {
            return []
        }

        return Array(windowIDs.prefix(Int(count))).filter { windowID in
            var level: CGWindowLevel = 0
            guard cgsGetWindowLevel(connection, windowID, &level) == .success else { return false }
            return level != CGWindowLevelForKey(.mainMenuWindow)
        }
    }

    static func descriptions(for windowIDs: [CGWindowID]) -> [[String: Any]] {
        guard !windowIDs.isEmpty else { return [] }
        let pointers: [UnsafeRawPointer?] = windowIDs.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let descriptions = CGWindowListCreateDescriptionFromArray(pointers as CFArray) else { return [] }
        return descriptions as? [[String: Any]] ?? []
    }
}
