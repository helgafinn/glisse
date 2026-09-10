//
//  Throttler.swift
//  GlisseKit
//
//  Rate limiting for things that must not run at trackpad-frame frequency:
//  the HUD, haptic ticks and DDC writes.
//
//  Deliberately timer-free. Everything here is "may I act now?" evaluated on
//  an event that already happened, so an idle Glisse schedules nothing and
//  wakes the CPU zero times.
//

import Foundation

/// Leading-edge rate limiter. `allow()` returns true at most once per interval.
public struct Throttler {
    private var lastFire: TimeInterval = -.greatestFiniteMagnitude
    public var interval: TimeInterval

    public init(interval: TimeInterval) {
        self.interval = interval
    }

    /// - Parameter now: monotonic timestamp; caller supplies it so this stays
    ///   pure and testable.
    public mutating func allow(now: TimeInterval) -> Bool {
        guard now - lastFire >= interval else { return false }
        lastFire = now
        return true
    }

    public mutating func reset() {
        lastFire = -.greatestFiniteMagnitude
    }
}

/// Trailing-edge coalescer: collapses a burst of writes into one, executed
/// after the burst goes quiet. Used for DDC, where a slow monitor must not be
/// flooded but must still land on the final value.
///
/// Unlike `Throttler` this does schedule work, so it only exists while a
/// gesture is in flight.
public final class Coalescer {
    private let queue: DispatchQueue
    private let interval: TimeInterval
    private var pending: DispatchWorkItem?
    private var latest: (() -> Void)?
    private let lock = NSLock()

    public init(interval: TimeInterval, queue: DispatchQueue) {
        self.interval = interval
        self.queue = queue
    }

    /// Replaces any not-yet-executed action with this one.
    public func submit(_ action: @escaping () -> Void) {
        lock.lock()
        latest = action
        pending?.cancel()

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let work = self.latest
            self.latest = nil
            self.pending = nil
            self.lock.unlock()
            work?()
        }
        pending = item
        lock.unlock()

        queue.asyncAfter(deadline: .now() + interval, execute: item)
    }

    /// Runs any pending action immediately (gesture ended: land the final value).
    public func flush() {
        lock.lock()
        let work = latest
        latest = nil
        pending?.cancel()
        pending = nil
        lock.unlock()
        if let work { queue.async(execute: work) }
    }

    public func cancel() {
        lock.lock()
        latest = nil
        pending?.cancel()
        pending = nil
        lock.unlock()
    }
}

/// Monotonic clock. `Date()` is wall-clock and jumps across sleep/wake, which
/// would corrupt every timing decision in the gesture engine.
public enum MonotonicClock {
    public static func now() -> TimeInterval {
        // ProcessInfo.systemUptime is mach_absolute_time based and does not
        // move backwards. It *pauses* during sleep, which is exactly what is
        // wanted: a gesture cannot span a sleep.
        ProcessInfo.processInfo.systemUptime
    }
}
