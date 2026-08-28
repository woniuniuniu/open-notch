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
        private var syntheticGestureInProgress = false
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
                    if event.getIntegerValueField(.eventSourceUserData) == 0,
                       !shield.isSyntheticGestureInProgress
                    {
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

        var isSyntheticGestureInProgress: Bool {
            lock.lock()
            defer { lock.unlock() }
            return syntheticGestureInProgress
        }

        func setSyntheticGestureInProgress(_ active: Bool) {
            lock.lock()
            syntheticGestureInProgress = active
            lock.unlock()
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

    /// Stops tagged reorder events before they can reach an ordinary app
    /// window. WindowServer still observes the HID event, while the owning
    /// status-item process receives an explicit process-scoped copy.
    private final class ReorderEventShield {
        let token: Int64
        let targetPID: pid_t
        let allowedRect: CGRect
        private var tap: CFMachPort?
        private var source: CFRunLoopSource?
        private let runLoop: CFRunLoop

        init?(targetPID: pid_t, allowedRect: CGRect) {
            guard targetPID > 0, let runLoop = CFRunLoopGetCurrent() else { return nil }
            self.targetPID = targetPID
            self.allowedRect = allowedRect
            self.runLoop = runLoop
            token = Int64.random(in: 1...Int64.max)
            let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
            let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
            let context = Unmanaged.passUnretained(self).toOpaque()
            tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, _, event, context in
                    guard let context else { return Unmanaged.passUnretained(event) }
                    let shield = Unmanaged<ReorderEventShield>.fromOpaque(context).takeUnretainedValue()
                    guard event.getIntegerValueField(.eventSourceUserData) == shield.token else {
                        return Unmanaged.passUnretained(event)
                    }
                    // WindowServer must perform its own menu-bar hit testing.
                    // Allow the event only while its coordinates remain inside
                    // the narrow corridor joining the two real status items.
                    return shield.allowedRect.contains(event.location)
                        ? Unmanaged.passUnretained(event)
                        : nil
                },
                userInfo: context
            )
            guard let tap else { return nil }
            source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            guard let source else { return nil }
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }

        func finish() {
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
            if let tap { CFMachPortInvalidate(tap) }
        }
    }

    /// Reorders one status item using events that are intercepted from the
    /// shared session stream and delivered only to the owning process.
    /// No event is allowed to reach the foreground application.
    static func reorderShielded(
        _ item: MenuBarItem,
        adjacentTo target: MenuBarItem,
        placeAfterTarget: Bool
    ) -> Result {
        guard AccessibilityResolver.isTrusted(), item.hostPID > 0,
              item.frame.width > 0, target.frame.width > 0,
              waitForUserInputToSettle(timeout: 0.8),
              let cursorShield = CursorShield(),
              let eventShield = ReorderEventShield(
                targetPID: item.hostPID,
                allowedRect: item.frame.union(target.frame).insetBy(dx: -8, dy: -3)
              ),
              let source = CGEventSource(stateID: .hidSystemState)
        else { return .failed }
        defer {
            eventShield.finish()
            cursorShield.finish()
        }
        cursorShield.setSyntheticGestureInProgress(true)
        defer { cursorShield.setSyntheticGestureInProgress(false) }

        let start = CGPoint(x: item.frame.midX, y: item.frame.midY)
        let inset = max(4, target.frame.width * 0.25)
        let end = CGPoint(
            x: placeAfterTarget ? target.frame.maxX - inset : target.frame.minX + inset,
            y: target.frame.midY
        )
        guard let moved = reorderEvent(.mouseMoved, at: start, item: item, source: source, token: eventShield.token),
              let down = reorderEvent(.leftMouseDown, at: start, item: item, source: source, token: eventShield.token),
              let up = reorderEvent(.leftMouseUp, at: end, item: item, source: source, token: eventShield.token),
              let cleanup = reorderEvent(.leftMouseUp, at: start, item: item, source: source, token: eventShield.token)
        else { return .failed }

        moved.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.025)
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        var completed = false
        defer { if !completed { cleanup.postToPid(item.hostPID) } }
        for step in 1...18 {
            guard !cursorShield.userInteracted else { return .deferredForUserInput }
            let progress = CGFloat(step) / 18
            let point = CGPoint(
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress
            )
            guard let dragged = reorderEvent(
                .leftMouseDragged,
                at: point,
                item: item,
                source: source,
                token: eventShield.token
            ) else { return .failed }
            dragged.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.014)
        }
        up.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.12)
        completed = true
        return cursorShield.userInteracted ? .deferredForUserInput : .moved
    }

    private static func reorderEvent(
        _ type: CGEventType,
        at point: CGPoint,
        item: MenuBarItem,
        source: CGEventSource,
        token: Int64
    ) -> CGEvent? {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return nil }
        event.flags = .maskCommand
        event.setIntegerValueField(.eventSourceUserData, value: token)
        return event
    }

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
