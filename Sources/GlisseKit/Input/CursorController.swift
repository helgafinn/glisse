//
//  CursorController.swift
//  GlisseKit
//
//  Holds the pointer still while an edge slide is in progress.
//
//  Mechanism: `CGAssociateMouseAndMouseCursorPosition(false)` detaches the
//  visible cursor from device movement. Public CoreGraphics API, and exactly the
//  semantics wanted — the finger keeps producing touch data while the pointer
//  does not drift off whatever the user was pointing at.
//
//  Threading: deliberately AppKit-free so it can be driven straight from the
//  gesture queue. The cursor position is read via `CGEvent(source: nil)?.location`,
//  which is already in CoreGraphics' top-left space, avoiding both a main-thread
//  hop and a manual coordinate flip.
//
//  The obvious danger is leaving the pointer detached — it would look like a
//  frozen Mac. Every exit path is covered:
//    * gesture end, cancel, or a vanished touch
//    * a watchdog that force-releases when the gesture heartbeat stops
//    * app termination (delegate hook + atexit)
//    * app deactivation, screen lock, sleep
//    * permission loss / touch source failure
//  The watchdog exists only while frozen, so idle cost is zero.
//

import CoreGraphics
import Foundation

public final class CursorController: @unchecked Sendable {

    private let lock = NSLock()
    private var _isFrozen = false
    private var anchor: CGPoint = .zero
    private var lastHeartbeat: TimeInterval = 0

    private var watchdog: DispatchSourceTimer?
    private let watchdogQueue = DispatchQueue(label: "xyz.glisse.cursor-watchdog", qos: .utility)

    /// If no heartbeat arrives for this long while frozen, release. Long enough
    /// not to fire mid-slide, short enough that a stall is invisible.
    private let watchdogTimeout: TimeInterval = 1.0

    private static let atexitOnce: Void = {
        atexit {
            // Last-resort protection if the process dies while detached.
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }()

    public init() {
        _ = Self.atexitOnce
    }

    deinit {
        forceRelease(reason: "deinit")
    }

    public var isFrozen: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isFrozen
    }

    // MARK: Freeze / release

    public func freeze() {
        lock.lock()
        if _isFrozen {
            lastHeartbeat = MonotonicClock.now()
            lock.unlock()
            return
        }
        let point = Self.currentCursorLocation()
        anchor = point
        _isFrozen = true
        lastHeartbeat = MonotonicClock.now()
        lock.unlock()

        // Detach first, then pin, so no intermediate movement leaks through.
        CGAssociateMouseAndMouseCursorPosition(0)
        CGWarpMouseCursorPosition(point)
        startWatchdog()
        Log.diagnostic(Log.input, "cursor frozen at \(point.x), \(point.y)")
    }

    /// Called on every processed frame of an active gesture.
    public func heartbeat() {
        lock.lock()
        guard _isFrozen else { lock.unlock(); return }
        lastHeartbeat = MonotonicClock.now()
        let point = anchor
        lock.unlock()
        // Cheap re-pin: some devices can still nudge the pointer while detached.
        CGWarpMouseCursorPosition(point)
    }

    public func release() {
        lock.lock()
        guard _isFrozen else { lock.unlock(); return }
        _isFrozen = false
        let point = anchor
        lock.unlock()

        stopWatchdog()
        CGAssociateMouseAndMouseCursorPosition(1)
        CGWarpMouseCursorPosition(point)
        Log.diagnostic(Log.input, "cursor released")
    }

    /// Unconditional release, safe from any teardown path and any thread.
    public func forceRelease(reason: String) {
        guard isFrozen else { return }
        Log.input.warning("force-releasing cursor: \(reason, privacy: .public)")
        release()
    }

    // MARK: Watchdog

    private func startWatchdog() {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + watchdogTimeout, repeating: watchdogTimeout / 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let frozen = self._isFrozen
            let stale = MonotonicClock.now() - self.lastHeartbeat > self.watchdogTimeout
            self.lock.unlock()
            if frozen, stale {
                self.forceRelease(reason: "watchdog: no gesture heartbeat")
            }
        }
        lock.lock(); watchdog = timer; lock.unlock()
        timer.resume()
    }

    private func stopWatchdog() {
        lock.lock()
        let timer = watchdog
        watchdog = nil
        lock.unlock()
        timer?.cancel()
    }

    // MARK: Helpers

    private static func currentCursorLocation() -> CGPoint {
        // Already in CG (top-left origin) space, and callable off the main thread.
        if let event = CGEvent(source: nil) {
            return event.location
        }
        // Fall back to the main display centre rather than guessing (0,0), which
        // would visibly teleport the pointer.
        let bounds = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }
}
