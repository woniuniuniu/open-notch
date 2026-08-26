import AppKit
import CoreGraphics
import Foundation

/// Executes one explicit menu bar move request. Inventory scans and layout
/// reconciliation never call Core Graphics event posting APIs themselves.
enum MenuBarMoveEngine {
    enum Result {
        case moved
        case deferredForUserInput
        case failed

        var succeeded: Bool {
            if case .moved = self { return true }
            return false
        }
    }

    /// Keeps WindowServer's synthetic menu bar event coordinates invisible
    /// and restores the pointer exactly where the user left it. Menu bar
    /// reordering has no public API and still requires a targeted mouse event,
    /// but that event must never take ownership of the user's visible cursor.
    private final class CursorShield {
        let originalLocation: CGPoint
        let displayID: CGDirectDisplayID
        private var cursorWasHidden = false
        private let lock = NSLock()
        private var latestPhysicalLocation: CGPoint
        private var receivedPhysicalInput = false
        private var eventTap: CFMachPort?
        private var runLoopSource: CFRunLoopSource?
        private let runLoop: CFRunLoop

        init?() {
            guard let originalLocation = CGEvent(source: nil)?.location else { return nil }
            self.originalLocation = originalLocation
            latestPhysicalLocation = originalLocation
            displayID = Self.display(containing: originalLocation) ?? CGMainDisplayID()
            guard let currentRunLoop = CFRunLoopGetCurrent() else { return nil }
            runLoop = currentRunLoop

            let types: [CGEventType] = [
                .mouseMoved, .leftMouseDown, .leftMouseUp,
                .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            ]
            let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
            let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
            eventTap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: { _, _, event, refcon in
                    guard let refcon else { return Unmanaged.passUnretained(event) }
                    let shield = Unmanaged<CursorShield>.fromOpaque(refcon).takeUnretainedValue()
                    // Open Notch tags every synthetic event with nonzero user
                    // data. Only untagged HID events are genuine user input;
                    // otherwise our own move would cancel itself immediately.
                    if event.getIntegerValueField(.eventSourceUserData) == 0 {
                        shield.recordPhysicalInput(at: event.location)
                    }
                    return Unmanaged.passUnretained(event)
                },
                userInfo: opaqueSelf
            )
            if let eventTap {
                runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
                if let runLoopSource {
                    CFRunLoopAddSource(runLoop, runLoopSource, .commonModes)
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                }
            }
            cursorWasHidden = CGDisplayHideCursor(displayID) == .success
        }

        var userInteracted: Bool {
            lock.lock()
            defer { lock.unlock() }
            return receivedPhysicalInput
        }

        func finish() {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
            if let runLoopSource { CFRunLoopRemoveSource(runLoop, runLoopSource, .commonModes) }
            if let eventTap { CFMachPortInvalidate(eventTap) }

            lock.lock()
            let restoreLocation = latestPhysicalLocation
            lock.unlock()
            // A real HID event updates latestPhysicalLocation, while our
            // synthetic session events do not. If the user moved or clicked
            // during a background operation, restore to their newest physical
            // position instead of yanking them back to an older location.
            CGWarpMouseCursorPosition(restoreLocation)
            if cursorWasHidden {
                CGDisplayShowCursor(displayID)
            }
        }

        private func recordPhysicalInput(at location: CGPoint) {
            lock.lock()
            latestPhysicalLocation = location
            receivedPhysicalInput = true
            lock.unlock()
        }

        private static func display(containing point: CGPoint) -> CGDirectDisplayID? {
            var count: UInt32 = 0
            guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
            guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }
            return displays.prefix(Int(count)).first { CGDisplayBounds($0).contains(point) }
        }
    }

    private static let windowIDField = CGEventField(rawValue: 0x33)!
    private static let permitAllEvents: CGEventFilterMask = [
        .permitLocalMouseEvents,
        .permitLocalKeyboardEvents,
        .permitSystemDefinedEvents,
    ]

    static func move(
        _ item: MenuBarItem,
        to disposition: ItemDisposition,
        boundary: RawStatusWindow,
        excluding excludedWindowIDs: Set<CGWindowID>
    ) -> Result {
        guard AccessibilityResolver.isTrusted(), !item.isProtected else { return .failed }
        guard waitForUserInputToSettle() else { return .deferredForUserInput }
        guard let cursorShield = CursorShield() else { return .failed }
        defer { cursorShield.finish() }

        var currentItem = item
        for attempt in 0..<3 {
            guard !cursorShield.userInteracted else { return .deferredForUserInput }
            guard userInputIsIdle(quietFor: attempt == 0 ? 0.18 : 0.08) else {
                return .deferredForUserInput
            }
            guard let currentBoundary = MenuBarDiscovery.statusWindow(id: boundary.windowID) else {
                return .failed
            }

            if positionReached(currentItem, disposition: disposition, boundary: currentBoundary) {
                return .moved
            }

            _ = routeDrag(currentItem, disposition: disposition, boundary: currentBoundary)
            guard !cursorShield.userInteracted else { return .deferredForUserInput }
            Thread.sleep(forTimeInterval: 0.14)

            if positionReached(currentItem, disposition: disposition, boundary: currentBoundary) {
                return .moved
            }

            guard attempt < 2 else { break }
            Thread.sleep(forTimeInterval: 0.12)
            if let refreshed = refreshedItem(currentItem, excluding: excludedWindowIDs) {
                currentItem = refreshed
            }
        }
        return .failed
    }

    private static func routeDrag(
        _ item: MenuBarItem,
        disposition: ItemDisposition,
        boundary: RawStatusWindow
    ) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        source.setLocalEventsFilterDuringSuppressionState(
            permitAllEvents,
            state: .eventSuppressionStateRemoteMouseDrag
        )
        source.setLocalEventsFilterDuringSuppressionState(
            permitAllEvents,
            state: .eventSuppressionStateSuppressionInterval
        )
        source.localEventsSuppressionInterval = 0

        let destination = CGPoint(
            x: disposition == .visible ? boundary.frame.maxX : boundary.frame.minX,
            y: boundary.frame.midY
        )
        let fallback = CGPoint(x: item.frame.midX, y: item.frame.midY)

        guard
            let down = event(
                .leftMouseDown,
                at: destination,
                windowID: item.windowID,
                targetPID: item.hostPID,
                source: source
            ),
            let up = event(
                .leftMouseUp,
                at: destination,
                windowID: boundary.windowID,
                targetPID: item.hostPID,
                source: source
            ),
            let fallbackUp = event(
                .leftMouseUp,
                at: fallback,
                windowID: item.windowID,
                targetPID: item.hostPID,
                source: source
            )
        else { return false }

        guard TargetedEventRouter.route(down, through: item.hostPID) else {
            releaseMouseButton(fallbackUp, targetPID: item.hostPID)
            return false
        }

        Thread.sleep(forTimeInterval: 0.06)
        guard TargetedEventRouter.route(up, through: item.hostPID) else {
            releaseMouseButton(fallbackUp, targetPID: item.hostPID)
            return false
        }
        return true
    }

    private static func releaseMouseButton(_ event: CGEvent, targetPID: pid_t) {
        // Never release through the global session stream. A targeted release
        // is sufficient for cleanup and cannot move or click the user's cursor.
        event.postToPid(targetPID)
    }

    private static func waitForUserInputToSettle(timeout: TimeInterval = 1.5) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if userInputIsIdle(quietFor: 0.28) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private static func userInputIsIdle(quietFor quietDuration: TimeInterval) -> Bool {
        let buttonDown = [CGMouseButton.left, .right, .center].contains {
            CGEventSource.buttonState(.combinedSessionState, button: $0)
        }
        let recentPhysicalMove = CGEventSource.secondsSinceLastEventType(
            .hidSystemState,
            eventType: .mouseMoved
        ) < quietDuration
        let modifiersDown = !CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
            .isEmpty
        return !buttonDown && !recentPhysicalMove && !modifiersDown
    }

    private static func refreshedItem(
        _ item: MenuBarItem,
        excluding excludedWindowIDs: Set<CGWindowID>
    ) -> MenuBarItem? {
        MenuBarDiscovery.scan(excluding: excludedWindowIDs, previousItems: [item])
            .first { $0.id == item.id }
    }

    private static func positionReached(
        _ item: MenuBarItem,
        disposition: ItemDisposition,
        boundary: RawStatusWindow
    ) -> Bool {
        guard let currentWindow = MenuBarDiscovery.statusWindow(id: item.windowID) else { return false }
        return LayoutReconciler.isInSection(
            currentWindow.frame,
            disposition: disposition,
            boundary: boundary.frame
        )
    }

    private static func event(
        _ type: CGEventType,
        at point: CGPoint,
        windowID: CGWindowID,
        targetPID: pid_t,
        source: CGEventSource
    ) -> CGEvent? {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return nil }

        event.flags = .maskCommand
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(targetPID))
        event.setIntegerValueField(.eventSourceUserData, value: Int64.random(in: 1...Int64.max))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
        event.setIntegerValueField(windowIDField, value: Int64(windowID))
        return event
    }

}
