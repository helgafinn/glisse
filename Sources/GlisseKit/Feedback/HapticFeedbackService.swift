//
//  HapticFeedbackService.swift
//  GlisseKit
//
//  Haptic ticks tied to *value progress*, not to input frames.
//
//  Firing on every frame at ~125 Hz produces a buzz, not feedback, and it
//  desynchronises from what the user sees. Instead the applied value is quantised
//  into detents and a tick fires when the detent index changes, so a fast sweep
//  gives rapid ticks and a slow one gives sparse ticks — the way a physical
//  detented slider behaves.
//
//  Backend
//  -------
//  Primary is `MTActuator` (private). Fallback is `NSHapticFeedbackManager`.
//
//  That order is not a preference, it is a requirement. Measured on macOS 27.0 /
//  M2 Pro: `NSHapticFeedbackManager.defaultPerformer` produces *nothing* from an
//  LSUIElement accessory app that is never the active application, which is
//  exactly what Glisse is. Its documentation says feedback "in response to
//  user actions in your app", and the system appears to enforce that. MTActuator
//  drives the actuator directly and works from a background process.
//
//  MTActuator also provides genuinely distinct patterns, which is the only way to
//  offer a strength choice at all — the public API has three fixed patterns and
//  no intensity control.
//

import AppKit
import GlissePrivate
import Foundation

/// How pronounced the ticks feel. Selects an actuation pattern *and* a tick
/// density, because the two cannot be varied independently and still feel right:
/// a firmer pulse takes longer to settle, so it needs more room between ticks.
public enum HapticStrength: String, Codable, Sendable, CaseIterable {
    case light
    case medium
    case strong

    public var displayName: String {
        switch self {
        case .light:  return "Light"
        case .medium: return "Medium"
        case .strong: return "Strong"
        }
    }

    /// MTActuator pattern. Verified to return success for all of these on
    /// hardware; the perceived firmness ordering is what the names claim.
    var actuationPattern: GLActuationPattern {
        switch self {
        case .light:  return .weak       // 1
        case .medium: return .medium     // 3
        case .strong: return .strongest  // 6
        }
    }

    /// AppKit fallback pattern, for the case where MTActuator is unavailable.
    var appKitPattern: NSHapticFeedbackManager.FeedbackPattern {
        switch self {
        case .light:  return .levelChange
        case .medium: return .generic
        case .strong: return .alignment
        }
    }

    /// Detents across the full 0...1 range.
    var stepsPerUnit: Int {
        switch self {
        case .light:  return 50   // every 2%
        case .medium: return 34   // every ~3%
        case .strong: return 24   // every ~4%
        }
    }

    /// Hard floor between ticks.
    var minimumInterval: TimeInterval {
        switch self {
        case .light:  return 0.022
        case .medium: return 0.030
        case .strong: return 0.045
        }
    }
}

public final class HapticFeedbackService: @unchecked Sendable {

    private let actuator = GLHapticActuator()

    private let lock = NSLock()
    private var throttle: Throttler
    private var lastStepIndex: Int?
    private var _isEnabled = true
    private var _strength: HapticStrength
    /// Set once MTActuator has been opened for a device.
    private var _actuatorReady = false

    public var isEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isEnabled }
        set { lock.lock(); _isEnabled = newValue; lock.unlock() }
    }

    /// Changing this mid-gesture is safe: the detent index is rebased so a change
    /// in density cannot fire a spurious tick.
    public var strength: HapticStrength {
        get { lock.lock(); defer { lock.unlock() }; return _strength }
        set {
            lock.lock()
            guard newValue != _strength else { lock.unlock(); return }
            _strength = newValue
            throttle.interval = newValue.minimumInterval
            lastStepIndex = nil
            lock.unlock()
        }
    }

    public init(strength: HapticStrength = .medium) {
        self._strength = strength
        self.throttle = Throttler(interval: strength.minimumInterval)
    }

    // MARK: Backend setup

    /// Opens the actuator for a trackpad. Call when devices are enumerated, and
    /// again after wake — a retained actuator can stop responding across sleep.
    ///
    /// - Parameter deviceID: value from `MTDeviceGetDeviceID`; 0 means unknown.
    @discardableResult
    public func prepare(deviceID: UInt64) -> Bool {
        guard deviceID != 0 else {
            lock.lock(); _actuatorReady = false; lock.unlock()
            return false
        }
        let ok = actuator.prepare(forDeviceID: deviceID)
        lock.lock(); _actuatorReady = ok; lock.unlock()

        if ok {
            Log.haptics.info("MTActuator opened for device 0x\(String(deviceID, radix: 16), privacy: .public)")
        } else {
            Log.haptics.warning("""
                MTActuator unavailable for device 0x\(String(deviceID, radix: 16), privacy: .public); \
                falling back to NSHapticFeedbackManager (which may be silent for a background app)
                """)
        }
        return ok
    }

    public func invalidateBackend() {
        actuator.invalidate()
        lock.lock(); _actuatorReady = false; lock.unlock()
    }

    public var isUsingActuator: Bool {
        lock.lock(); defer { lock.unlock() }
        return _actuatorReady && actuator.isReady
    }

    // MARK: Gesture lifecycle

    /// Call when a gesture starts so the first tick is measured from the starting
    /// value rather than from wherever the previous gesture ended.
    public func beginGesture(atValue value: Double) {
        lock.lock()
        lastStepIndex = value.quantized(steps: _strength.stepsPerUnit)
        throttle.reset()
        lock.unlock()
    }

    public func endGesture() {
        lock.lock()
        lastStepIndex = nil
        lock.unlock()
    }

    /// Call with the value that was actually applied.
    public func valueChanged(to value: Double) {
        lock.lock()
        guard _isEnabled else {
            lastStepIndex = value.quantized(steps: _strength.stepsPerUnit)
            lock.unlock()
            return
        }

        let current = _strength
        let step = value.quantized(steps: current.stepsPerUnit)
        let previous = lastStepIndex
        lastStepIndex = step

        var shouldTick = false
        if let previous, previous != step {
            shouldTick = throttle.allow(now: MonotonicClock.now())
        }
        lock.unlock()

        guard shouldTick else { return }
        fire(current)
    }

    /// Distinct feel for hitting an end stop, so 0 and 100 are recognisable
    /// without looking.
    public func hitLimit() {
        lock.lock()
        guard _isEnabled, throttle.allow(now: MonotonicClock.now()) else {
            lock.unlock()
            return
        }
        let current = _strength
        lock.unlock()

        // The end stop is always the firmest available tap. At `.strong` the
        // ticks already use that pattern, so a second tap keeps the end stop
        // distinguishable from an ordinary detent.
        fireLimit()
        if current == .strong {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.055) { [weak self] in
                self?.fireLimit()
            }
        }
    }

    /// One tap at the current strength, ignoring the detent logic. Used when the
    /// user picks a strength, so the choice can be felt immediately.
    public func demoTick() {
        fire(strength)
    }

    // MARK: Emission

    private func fire(_ strength: HapticStrength) {
        if actuator.actuate(strength.actuationPattern) { return }
        performAppKit(strength.appKitPattern)
    }

    private func fireLimit() {
        if actuator.actuate(.strongest) { return }
        performAppKit(.alignment)
    }

    private func performAppKit(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        // AppKit, so keep the call on the main queue.
        DispatchQueue.main.async {
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        }
    }

    // MARK: Diagnostics

    public func diagnosticsDescription() -> String {
        var text = actuator.diagnosticsDescription()
        lock.lock()
        let enabled = _isEnabled
        let current = _strength
        lock.unlock()
        text += "  enabled          : \(enabled)\n"
        text += "  strength         : \(current.displayName)"
        text += " (pattern \(current.actuationPattern.rawValue), "
        text += "\(current.stepsPerUnit) detents, \(Int(current.minimumInterval * 1000)) ms floor)\n"
        text += "  backend in use   : \(isUsingActuator ? "MTActuator" : "NSHapticFeedbackManager (may be silent)")\n"
        return text
    }
}
