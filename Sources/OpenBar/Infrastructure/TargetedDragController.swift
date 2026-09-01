import CoreGraphics
import Foundation
import OpenBarCore

/// Sends a short Command-drag only to the status item's owning process.
/// It never posts into the global HID stream and therefore never moves the
/// user's visible pointer.
enum TargetedDragController {
    enum Result { case moved, userBusy, failed }

    private static let privateWindowIDField = CGEventField(rawValue: 0x33)!

    static func move(_ item: LiveMenuBarItem, to section: ItemSection, boundary: RawStatusWindow) -> Result {
        guard AccessibilityInventory.isTrusted(), !item.isProtected else { return .failed }
        guard userIsIdle(quietFor: 0.3) else { return .userBusy }
        guard let source = CGEventSource(stateID: .hidSystemState) else { return .failed }
        source.localEventsSuppressionInterval = 0

        let start = CGPoint(x: item.frame.midX, y: item.frame.midY)
        let destination = CGPoint(
            x: section == .shown ? boundary.frame.maxX + 6 : boundary.frame.minX - 6,
            y: boundary.frame.midY
        )
        guard let down = event(.leftMouseDown, at: start, windowID: item.windowID, source: source),
              let drag = event(.leftMouseDragged, at: destination, windowID: boundary.windowID, source: source),
              let up = event(.leftMouseUp, at: destination, windowID: boundary.windowID, source: source)
        else { return .failed }

        down.postToPid(item.hostPID)
        Thread.sleep(forTimeInterval: 0.045)
        guard userIsIdle(quietFor: 0.08) else {
            up.postToPid(item.hostPID)
            return .userBusy
        }
        drag.postToPid(item.hostPID)
        Thread.sleep(forTimeInterval: 0.045)
        up.postToPid(item.hostPID)
        return .moved
    }

    private static func event(
        _ type: CGEventType,
        at point: CGPoint,
        windowID: CGWindowID,
        targetPID: pid_t? = nil,
        source: CGEventSource
    ) -> CGEvent? {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return nil }
        event.flags = .maskCommand
        if let targetPID {
            event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(targetPID))
        }
        event.setIntegerValueField(.eventSourceUserData, value: Int64.random(in: 1...Int64.max))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
        event.setIntegerValueField(
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
            value: Int64(windowID)
        )
        event.setIntegerValueField(privateWindowIDField, value: Int64(windowID))
        return event
    }

    private static func userIsIdle(quietFor duration: TimeInterval) -> Bool {
        let buttonDown = [CGMouseButton.left, .right, .center].contains {
            CGEventSource.buttonState(.combinedSessionState, button: $0)
        }
        let mouseMovedRecently = CGEventSource.secondsSinceLastEventType(
            .hidSystemState,
            eventType: .mouseMoved
        ) < duration
        let modifiers = CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
        return !buttonDown && !mouseMovedRecently && modifiers.isEmpty
    }
}
