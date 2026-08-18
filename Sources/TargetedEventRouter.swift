// Event-routing mechanism derived from Ice's MenuBarItemManager.swift.
// Copyright (C) 2024-2025 Jordan Baird. Modified for Open Notch in 2026.
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Foundation

/// Delivers one tagged event through the target process and the session event
/// stream. Recent macOS releases ignore a directly posted Command-drag for
/// hosted status items, so both hops must be observed before the move proceeds.
enum TargetedEventRouter {
    fileprivate final class Context {
        let event: CGEvent
        let targetPID: pid_t
        let triggerUserData: Int64
        let runLoop: CFRunLoop
        var completed = false

        init(event: CGEvent, targetPID: pid_t, triggerUserData: Int64, runLoop: CFRunLoop) {
            self.event = event
            self.targetPID = targetPID
            self.triggerUserData = triggerUserData
            self.runLoop = runLoop
        }
    }

    static func route(_ event: CGEvent, through targetPID: pid_t, timeout: TimeInterval = 0.25) -> Bool {
        guard let runLoop = CFRunLoopGetCurrent(), let trigger = CGEvent(source: nil) else { return false }

        let triggerUserData = Int64.random(in: 1...Int64.max)
        trigger.setIntegerValueField(.eventSourceUserData, value: triggerUserData)

        let context = Context(
            event: event,
            targetPID: targetPID,
            triggerUserData: triggerUserData,
            runLoop: runLoop
        )
        let opaqueContext = Unmanaged.passUnretained(context).toOpaque()
        let triggerMask = CGEventMask(1) << CGEventType.null.rawValue
        let eventMask = CGEventMask(1) << event.type.rawValue

        guard
            let processTap = CGEvent.tapCreateForPid(
                pid: targetPID,
                place: .tailAppendEventTap,
                options: .defaultTap,
                eventsOfInterest: triggerMask,
                callback: targetedProcessTapCallback,
                userInfo: opaqueContext
            ),
            let sessionTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .tailAppendEventTap,
                options: .listenOnly,
                eventsOfInterest: eventMask,
                callback: targetedSessionTapCallback,
                userInfo: opaqueContext
            ),
            let processSource = CFMachPortCreateRunLoopSource(nil, processTap, 0),
            let sessionSource = CFMachPortCreateRunLoopSource(nil, sessionTap, 0)
        else { return false }

        CFRunLoopAddSource(runLoop, processSource, .commonModes)
        CFRunLoopAddSource(runLoop, sessionSource, .commonModes)
        defer {
            CGEvent.tapEnable(tap: processTap, enable: false)
            CGEvent.tapEnable(tap: sessionTap, enable: false)
            CFRunLoopRemoveSource(runLoop, processSource, .commonModes)
            CFRunLoopRemoveSource(runLoop, sessionSource, .commonModes)
            CFMachPortInvalidate(processTap)
            CFMachPortInvalidate(sessionTap)
        }

        CGEvent.tapEnable(tap: processTap, enable: true)
        CGEvent.tapEnable(tap: sessionTap, enable: true)
        trigger.postToPid(targetPID)

        let deadline = Date.now.addingTimeInterval(timeout)
        while !context.completed, Date.now < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.025, true)
        }
        return context.completed
    }

    private static let identityFields: [CGEventField] = [
        .eventSourceUserData,
        .mouseEventWindowUnderMousePointer,
        .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
        CGEventField(rawValue: 0x33)!,
    ]

    fileprivate static func handleProcessEvent(_ event: CGEvent, context: Context) -> Unmanaged<CGEvent>? {
        guard event.getIntegerValueField(.eventSourceUserData) == context.triggerUserData else {
            return Unmanaged.passUnretained(event)
        }
        context.event.post(tap: .cgSessionEventTap)
        return nil
    }

    fileprivate static func handleSessionEvent(_ event: CGEvent, context: Context) -> Unmanaged<CGEvent>? {
        guard identityFields.allSatisfy({
            event.getIntegerValueField($0) == context.event.getIntegerValueField($0)
        }) else {
            return Unmanaged.passUnretained(event)
        }

        context.event.postToPid(context.targetPID)
        context.completed = true
        CFRunLoopStop(context.runLoop)
        return Unmanaged.passUnretained(event)
    }
}

private func targetedProcessTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return nil }
    let context = Unmanaged<TargetedEventRouter.Context>.fromOpaque(refcon).takeUnretainedValue()
    return TargetedEventRouter.handleProcessEvent(event, context: context)
}

private func targetedSessionTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<TargetedEventRouter.Context>.fromOpaque(refcon).takeUnretainedValue()
    return TargetedEventRouter.handleSessionEvent(event, context: context)
}
