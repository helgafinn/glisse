//
//  AxisOrientationVerifier.swift
//  GlisseKit
//
//  Confirms the vertical coordinate contract against the machine, instead of
//  trusting it.
//
//  The spec is emphatic that raw Y orientation must not be assumed. The trouble
//  is that verifying it normally needs a human to slide a finger upward and
//  report what happened. This does it passively instead:
//
//    While a single finger is dragging the pointer around, macOS is already
//    telling us which way "up" is — the cursor moves up the screen. So correlate
//    the touch's dY against the cursor's dY. If they agree, touch +y points at
//    the top of the trackpad (the documented NSTouch convention, origin
//    lower-left) and the contract in TrackpadTouch.swift holds.
//
//  Costs nothing after it reaches a verdict: sampling stops for good, so there is
//  no per-frame cursor query in steady state.
//

import CoreGraphics
import Foundation

public enum AxisVerdict: String, Sendable, Equatable {
    /// +y is towards the top of the trackpad, as documented. Nothing to do.
    case matchesContract
    /// +y is towards the bottom. The engine's `invertVertical` should be on.
    case inverted
    /// Not enough evidence yet.
    case undetermined
}

public final class AxisOrientationVerifier: @unchecked Sendable {

    private let lock = NSLock()

    private var previousTouchY: Double?
    private var previousCursorY: Double?
    private var previousTouchID: Int32?

    /// Positive when touch dY and screen-up agree.
    private var agreement = 0.0
    private var samples = 0
    private var verdict: AxisVerdict = .undetermined

    /// Enough correlated samples to be confident; a couple of seconds of ordinary
    /// pointer use.
    private let requiredSamples = 120
    /// Movement below this is noise and carries no directional information.
    private let minimumTouchDelta = 0.004
    private let minimumCursorDelta = 1.0

    public init() {}

    public var currentVerdict: AxisVerdict {
        lock.lock(); defer { lock.unlock() }
        return verdict
    }

    public var isComplete: Bool {
        currentVerdict != .undetermined
    }

    /// Feed every frame until `isComplete`. Only single-touch frames away from
    /// the edges are used, because those are the ones driving the pointer.
    public func observe(frame: TrackpadFrame) {
        lock.lock()
        guard verdict == .undetermined else { lock.unlock(); return }
        lock.unlock()

        let active = frame.activeTouches
        guard active.count == 1, let touch = active.first else {
            reset()
            return
        }
        // Edge contacts may be driving a slider with the cursor frozen, which
        // would poison the correlation.
        guard touch.x > 0.15, touch.x < 0.85 else {
            reset()
            return
        }
        guard let cursor = CGEvent(source: nil)?.location else { return }

        lock.lock()
        defer { lock.unlock() }

        if previousTouchID != touch.id {
            previousTouchID = touch.id
            previousTouchY = touch.y
            previousCursorY = cursor.y
            return
        }

        guard let lastTouchY = previousTouchY, let lastCursorY = previousCursorY else {
            previousTouchY = touch.y
            previousCursorY = cursor.y
            return
        }

        let touchDelta = touch.y - lastTouchY
        // CGEvent locations use a top-left origin, so screen "up" is decreasing y.
        let screenUpDelta = -(cursor.y - lastCursorY)

        previousTouchY = touch.y
        previousCursorY = cursor.y

        guard abs(touchDelta) >= minimumTouchDelta,
              abs(screenUpDelta) >= minimumCursorDelta else { return }

        agreement += (touchDelta > 0) == (screenUpDelta > 0) ? 1 : -1
        samples += 1

        guard samples >= requiredSamples else { return }

        // Require a clear majority, not a coin flip.
        let ratio = agreement / Double(samples)
        if ratio > 0.6 {
            verdict = .matchesContract
        } else if ratio < -0.6 {
            verdict = .inverted
        } else {
            // Ambiguous: start over rather than record a bad verdict. Happens if
            // pointer acceleration or a scroll gesture polluted the window.
            agreement = 0
            samples = 0
        }
    }

    private func reset() {
        lock.lock()
        previousTouchID = nil
        previousTouchY = nil
        previousCursorY = nil
        lock.unlock()
    }

    /// Clears the verdict. Used when the touch source changes, since a different
    /// source may use a different convention.
    public func invalidate() {
        lock.lock()
        verdict = .undetermined
        agreement = 0
        samples = 0
        previousTouchID = nil
        previousTouchY = nil
        previousCursorY = nil
        lock.unlock()
    }

    public func diagnosticsDescription() -> String {
        lock.lock()
        let current = verdict
        let count = samples
        let score = agreement
        lock.unlock()

        var text = "Vertical axis verification\n"
        text += "  verdict          : \(current.rawValue)\n"
        switch current {
        case .matchesContract:
            text += "  meaning          : finger up = value up (no action needed)\n"
        case .inverted:
            text += "  meaning          : raw Y is flipped on this device — turn on\n"
            text += "                     Settings > Advanced > Invert vertical direction\n"
        case .undetermined:
            text += "  samples          : \(count) of 120 (move the pointer around to gather more)\n"
            text += "  agreement score  : \(String(format: "%+.0f", score))\n"
        }
        return text
    }
}
