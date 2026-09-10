//
//  TypingSuppressionService.swift
//  GlisseKit
//
//  Blocks *new* edge gestures for a short window after a keystroke, so resting
//  or brushing a hand against the trackpad while typing does not change the
//  volume.
//
//  Two deliberate design choices:
//
//  1. Only key-down of a real key extends the window. Modifier changes do not,
//     because holding Command while reading would otherwise suppress gestures
//     indefinitely — which feels like the app randomly broke.
//
//  2. An already-active gesture is never interrupted. If the user is
//     mid-adjustment and happens to hit a key, the slide continues. Killing it
//     would be more surprising than the accidental keystroke.
//
//  Pure and clock-injected, so the behaviour is unit-testable.
//

import Foundation

public final class TypingSuppressionService: @unchecked Sendable {

    private let lock = NSLock()
    private var lastKeyDown: TimeInterval = -.greatestFiniteMagnitude
    private var observedKeyCount = 0

    /// How long after a keystroke new gestures stay blocked.
    public var suppressionDuration: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _duration }
        set { lock.lock(); _duration = max(0, newValue); lock.unlock() }
    }
    private var _duration: TimeInterval

    public var isEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isEnabled }
        set { lock.lock(); _isEnabled = newValue; lock.unlock() }
    }
    private var _isEnabled: Bool

    public init(suppressionDuration: TimeInterval = 0.5, isEnabled: Bool = true) {
        self._duration = max(0, suppressionDuration)
        self._isEnabled = isEnabled
    }

    /// Called from the keyboard monitor.
    public func noteKeyDown(at timestamp: TimeInterval) {
        lock.lock()
        lastKeyDown = timestamp
        observedKeyCount += 1
        lock.unlock()
    }

    /// How many key-downs have been observed, and how long ago the last one was.
    ///
    /// Exposed because "pause while typing does nothing" has two very different
    /// causes — the tap not delivering keys at all, or the suppression window not
    /// being consulted — and without a count they are indistinguishable.
    public var activity: (keyCount: Int, secondsSinceLastKey: TimeInterval?) {
        lock.lock()
        defer { lock.unlock() }
        guard observedKeyCount > 0 else { return (0, nil) }
        return (observedKeyCount, MonotonicClock.now() - lastKeyDown)
    }

    /// True while new gestures should be refused.
    public func isSuppressed(now: TimeInterval = MonotonicClock.now()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard _isEnabled else { return false }
        guard _duration > 0 else { return false }
        return now - lastKeyDown < _duration
    }

    /// Clears the window. Used on wake, where the stored timestamp predates the
    /// sleep and the monotonic clock has effectively jumped.
    public func reset() {
        lock.lock()
        lastKeyDown = -.greatestFiniteMagnitude
        lock.unlock()
    }

    /// Seconds until suppression lifts; 0 when not suppressed. Diagnostics only.
    public func remaining(now: TimeInterval = MonotonicClock.now()) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard _isEnabled, _duration > 0 else { return 0 }
        return max(0, _duration - (now - lastKeyDown))
    }
}
