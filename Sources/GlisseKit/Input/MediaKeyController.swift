//
//  MediaKeyController.swift
//  GlisseKit
//
//  Changes volume and brightness by synthesising the machine's own media keys,
//  which makes macOS perform the change *and* draw its own HUD.
//
//  Why this exists
//  ---------------
//  There is no way to ask macOS 26+ to display its OSD. Both private routes are
//  dead: `-[OSDManager showImage:…]` accepts every call and draws nothing, and
//  `com.apple.OSDUIHelper` refuses the XPC connection. Measured, not assumed —
//  and the HUD is not even a listable window any more, so it is drawn inside
//  WindowServer where nothing external can reach it.
//
//  The one thing that still produces the genuine, OS-owned HUD is the event the
//  keyboard itself sends. So instead of setting a value and then trying to show a
//  HUD, Glisse posts the same `NSSystemDefined` subtype-8 event a Mac keyboard
//  posts. macOS changes the value and shows the HUD that matches the user's
//  macOS version, with no imitation involved.
//
//  Resolution
//  ----------
//  A bare media key moves in 1/16 steps, which would feel like a ratchet. Holding
//  Shift+Option asks the system for quarter steps: measured at exactly 1/64
//  (0.015625) for both volume and brightness. Glisse always uses the fine
//  variant, so a full sweep is 64 steps — finer than the 16-segment HUD can even
//  draw, and comparable to the haptic detent spacing.
//
//  Cost
//  ----
//  Posting events requires Accessibility permission, and the keys act on whatever
//  output device and display macOS considers current. When either of those is
//  unacceptable — permission missing, or brightness aimed at a specific/external
//  display — the caller falls back to writing the value directly, which is
//  precise but produces no HUD.
//

import AppKit
import CoreGraphics
import Foundation

public final class MediaKeyController: @unchecked Sendable {

    /// Values from IOKit's `ev_keymap.h` (`NX_KEYTYPE_*`).
    public enum MediaKey: Int32 {
        case soundUp        = 0
        case soundDown      = 1
        case brightnessUp   = 2
        case brightnessDown = 3
        case mute           = 7
    }

    /// One fine step, measured on hardware.
    public static let fineStep = 1.0 / 64.0

    /// Floor between posted events, so a fast slide cannot flood the HID stack.
    private let lock = NSLock()
    private var throttle = Throttler(interval: 0.004)
    private var stepper: MediaKeyStepper

    public init() {
        self.stepper = MediaKeyStepper(step: Self.fineStep,
                                       maximumStepsPerCall: 6)
    }

    public var isAvailable: Bool { AXIsProcessTrusted() }

    // MARK: Stepping

    public enum Axis {
        case volume
        case brightness

        func key(increasing: Bool) -> MediaKey {
            switch self {
            case .volume:     return increasing ? .soundUp : .soundDown
            case .brightness: return increasing ? .brightnessUp : .brightnessDown
            }
        }
    }

    /// Applies a relative change by posting as many fine steps as it represents.
    ///
    /// - Returns: the number of steps actually posted.
    @discardableResult
    public func apply(delta: Double, to axis: Axis) -> Int {
        guard AXIsProcessTrusted() else { return 0 }

        lock.lock()
        let outcome = stepper.consume(delta: delta)
        lock.unlock()

        guard outcome.steps > 0 else { return 0 }

        let key = axis.key(increasing: outcome.increasing)
        for _ in 0..<outcome.steps {
            post(key)
        }
        return outcome.steps
    }

    /// Clears carried-over movement. Call when a gesture starts or ends so one
    /// gesture cannot leak a step into the next.
    public func resetAccumulator() {
        lock.lock()
        stepper.reset()
        throttle.reset()
        lock.unlock()
    }

    /// Toggles mute through the system, so the native mute HUD appears.
    public func toggleMute() {
        guard AXIsProcessTrusted() else { return }
        post(.mute)
    }

    // MARK: Event construction

    public func post(_ key: MediaKey) {
        lock.lock()
        let allowed = throttle.allow(now: MonotonicClock.now())
        lock.unlock()
        // The throttle protects the HID stack; skipping a step is invisible
        // because the next frame will ask for it again.
        guard allowed else { return }

        postRaw(key, down: true, fine: true)
        postRaw(key, down: false, fine: true)
    }

    private func postRaw(_ key: MediaKey, down: Bool, fine: Bool) {
        // Layout of an NSSystemDefined subtype-8 media key event:
        //   modifierFlags low bits carry the key state (0xA00 down, 0xB00 up)
        //   data1 = (keyCode << 16) | (state << 8)
        //   data2 = -1
        // Shift+Option in the flags is what macOS reads as "quarter steps".
        var flags: UInt = down ? 0xA00 : 0xB00
        if fine {
            flags |= UInt(NSEvent.ModifierFlags.shift.rawValue)
            flags |= UInt(NSEvent.ModifierFlags.option.rawValue)
        }
        let data1 = Int((key.rawValue << 16) | ((down ? 0xA : 0xB) << 8))

        guard let event = NSEvent.otherEvent(with: .systemDefined,
                                            location: .zero,
                                            modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                                            timestamp: 0,
                                            windowNumber: 0,
                                            context: nil,
                                            subtype: 8,
                                            data1: data1,
                                            data2: -1),
              let cgEvent = event.cgEvent else {
            Log.hud.error("could not build media key event for \(key.rawValue, privacy: .public)")
            return
        }
        cgEvent.post(tap: .cghidEventTap)
    }

    // MARK: Diagnostics

    public func diagnosticsDescription() -> String {
        """
        Media keys (native HUD trigger)
          accessibility    : \(AXIsProcessTrusted() ? "granted" : "NOT granted — cannot post events")
          fine step        : 1/64 (\(String(format: "%.6f", Self.fineStep)))
          max steps / frame: 6
        """
    }
}


// MARK: - Step accumulation

/// Turns a stream of continuous deltas into discrete key presses.
///
/// Pure and separate from event posting so the arithmetic can be tested: getting
/// it wrong produces either a slider that will not move slowly, or one that keeps
/// firing after the finger has stopped.
struct MediaKeyStepper {

    struct Outcome: Equatable {
        let steps: Int
        let increasing: Bool
    }

    /// Size of one key press, in normalised units.
    let step: Double
    /// Cap per call. A frantic sweep would otherwise ask for dozens at once; the
    /// system coalesces them badly and the HUD falls behind the finger.
    let maximumStepsPerCall: Int

    /// Sub-step movement carried between frames, so a slow slide still advances
    /// rather than being discarded.
    private(set) var residual: Double = 0

    init(step: Double, maximumStepsPerCall: Int) {
        self.step = step > 0 ? step : 1.0 / 64.0
        self.maximumStepsPerCall = max(1, maximumStepsPerCall)
    }

    mutating func consume(delta: Double) -> Outcome {
        guard delta.isFinite else { return Outcome(steps: 0, increasing: true) }

        // A reversal discards what was banked in the other direction; otherwise a
        // small movement back would be swallowed by leftover forward credit.
        if residual != 0, (residual > 0) != (delta > 0), delta != 0 {
            residual = 0
        }
        residual += delta

        let magnitude = abs(residual)
        var steps = Int((magnitude / step).rounded(.down))
        let increasing = residual > 0

        if steps <= 0 {
            return Outcome(steps: 0, increasing: increasing)
        }

        if steps > maximumStepsPerCall {
            // Drop the overflow instead of banking it: banking would keep firing
            // after the finger stopped.
            steps = maximumStepsPerCall
            residual = 0
        } else {
            let consumed = Double(steps) * step
            residual += increasing ? -consumed : consumed
        }

        return Outcome(steps: steps, increasing: increasing)
    }

    mutating func reset() {
        residual = 0
    }
}
