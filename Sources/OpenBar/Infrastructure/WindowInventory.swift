import AppKit
import CoreGraphics
import Foundation

struct RawStatusWindow {
    let windowID: CGWindowID
    let hostPID: pid_t
    let hostName: String
    let hostBundleIdentifier: String
    let title: String
    let frame: CGRect
}

enum WindowInventory {
    static func statusWindows(excluding: Set<CGWindowID>) -> [RawStatusWindow] {
        let level = Int(CGWindowLevelForKey(.statusWindow))
        let descriptions = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)
            as? [[String: Any]] ?? []
        return descriptions.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == level,
                  let rawID = info[kCGWindowNumber as String] as? NSNumber,
                  !excluding.contains(CGWindowID(rawID.uint32Value)),
                  let rawPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { return nil }
            let frame = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0
            )
            guard frame.width > 0, frame.height > 0, AccessibilityInventory.isMenuBarPosition(frame.origin, height: frame.height) else { return nil }
            let pid = rawPID.int32Value
            let app = NSRunningApplication(processIdentifier: pid)
            return RawStatusWindow(
                windowID: CGWindowID(rawID.uint32Value),
                hostPID: pid,
                hostName: app?.localizedName ?? (info[kCGWindowOwnerName as String] as? String ?? ""),
                hostBundleIdentifier: app?.bundleIdentifier ?? "unknown.\(pid)",
                title: info[kCGWindowName as String] as? String ?? "",
                frame: frame
            )
        }
        .sorted { $0.frame.minX < $1.frame.minX }
    }
}
