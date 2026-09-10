//
//  KeyboardMonitor.swift
//  GlisseKit
//
//  One listen-only CGEventTap for keyboard activity, feeding typing suppression
//  and modifier-toggle detection.
//
//  Requires Accessibility. Without it Glisse still works — edge gestures come
//  from MultitouchSupport, which needs no permission — but typing suppression
//  and toggle-mode modifiers are unavailable, and the menu says so rather than
//  pretending.
//
//  The tap is `.listenOnly`, so it can never swallow or alter a keystroke. If
//  macOS disables it (timeout, or the user revoking permission mid-session) it
//  is re-armed, and if that fails the monitor reports itself stopped.
//

import AppKit
import Foundation

public final class KeyboardMonitor {

    /// Non-modifier key went down. Carries the monotonic timestamp.
    public var onKeyDown: ((TimeInterval) -> Void)?
    /// Modifier state changed. Carries the new flags.
    public var onFlagsChanged: ((NSEvent.ModifierFlags) -> Void)?
    /// Called when the tap dies and could not be revived.
    public var onTapInvalidated: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    public private(set) var isRunning = false

    public init() {}

    deinit {
        stop()
    }

    public func start() throws {
        guard !isRunning else { return }
        guard AXIsProcessTrusted() else {
            throw PermissionError.accessibilityNotGranted
        }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw PermissionError.eventTapDenied
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        Log.input.info("keyboard monitor started")
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        isRunning = false
    }

    public func restart() {
        stop()
        try? start()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout:
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                Log.input.warning("keyboard tap disabled by timeout; re-enabled")
            }

        case .tapDisabledByUserInput:
            // Usually means permission was revoked. Do not spin trying to revive.
            Log.input.warning("keyboard tap disabled by user input; stopping")
            stop()
            onTapInvalidated?()

        case .keyDown:
            // Auto-repeat still counts as typing.
            onKeyDown?(MonotonicClock.now())

        case .flagsChanged:
            let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            onFlagsChanged?(flags)

        default:
            break
        }
    }
}
