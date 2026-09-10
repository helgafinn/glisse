//
//  MiddleClickSynthesizer.swift
//  GlisseKit
//
//  Posts a single synthetic middle click at the current pointer location.
//
//  Requires Accessibility, because posting events does. Guards against the two
//  ways this feature goes wrong in practice: duplicate clicks from a bouncy
//  release, and a down without a matching up (which leaves apps in a stuck
//  drag).
//

import AppKit
import CoreGraphics
import Foundation

public final class MiddleClickSynthesizer {

    /// Ignore requests closer together than this. The recognizer has its own
    /// re-arm window; this is a second, independent guard.
    private let minimumInterval: TimeInterval = 0.20
    private var lastClick: TimeInterval = -.greatestFiniteMagnitude
    private let lock = NSLock()

    public private(set) var isAvailable: Bool = false

    public init() {
        refreshAvailability()
    }

    public func refreshAvailability() {
        isAvailable = AXIsProcessTrusted()
    }

    @discardableResult
    public func performMiddleClick() -> Bool {
        guard AXIsProcessTrusted() else {
            Log.input.warning("middle click requested without Accessibility permission")
            return false
        }

        lock.lock()
        let now = MonotonicClock.now()
        guard now - lastClick >= minimumInterval else {
            lock.unlock()
            Log.diagnostic(Log.input, "middle click suppressed (too soon)")
            return false
        }
        lastClick = now
        lock.unlock()

        let location = cursorLocationInCGSpace()
        // A private event source keeps the synthetic click from being fed back
        // into taps that filter on source state.
        let source = CGEventSource(stateID: .privateState)

        guard let down = CGEvent(mouseEventSource: source,
                                 mouseType: .otherMouseDown,
                                 mouseCursorPosition: location,
                                 mouseButton: .center),
              let up = CGEvent(mouseEventSource: source,
                               mouseType: .otherMouseUp,
                               mouseCursorPosition: location,
                               mouseButton: .center)
        else {
            Log.input.error("failed to build middle-click events")
            return false
        }

        // Some apps look at the click count.
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)

        down.post(tap: .cghidEventTap)
        // Post the up unconditionally and immediately after: never leave a
        // button logically held.
        up.post(tap: .cghidEventTap)

        Log.input.info("synthesised middle click")
        return true
    }

    private func cursorLocationInCGSpace() -> CGPoint {
        // CGEvent's own idea of the cursor is already in CG (top-left) space and
        // avoids a manual flip.
        if let event = CGEvent(source: nil) {
            return event.location
        }
        let location = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: location.x, y: primaryHeight - location.y)
    }
}
