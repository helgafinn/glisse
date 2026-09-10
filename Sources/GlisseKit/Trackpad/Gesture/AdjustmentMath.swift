//
//  AdjustmentMath.swift
//  GlisseKit
//
//  Pure arithmetic shared by the gesture pipeline. Extracted from the
//  controllers so the parts that decide *what value to write* can be tested
//  without a trackpad, an audio device or a monitor.
//

import Foundation

// MARK: - Relative adjustment

public enum ValueAdjustment {

    public struct Result: Equatable {
        public let value: Double
        /// True when the delta pushed against 0 or 1 and produced no change.
        public let hitLimit: Bool
    }

    /// Applies a relative delta to a current value.
    ///
    /// This is the whole of Glisse's control model: never map absolute finger
    /// position onto absolute system value, only accumulate deltas onto whatever
    /// the system was already at.
    public static func apply(current: Double, delta: Double) -> Result {
        let base = clamp01(current)
        guard delta.isFinite, delta != 0 else {
            return Result(value: base, hitLimit: false)
        }
        let next = clamp01(base + delta)
        return Result(value: next, hitLimit: next == base)
    }
}

// MARK: - Mute coupling

/// What to do about mute after a volume write (spec §26).
public enum MuteAction: Equatable {
    case none
    case mute
    case unmute
}

public enum MuteCoupling {

    /// Volume at or below this counts as silent.
    public static let silenceThreshold = 0.0005

    /// Keeps the system in a state a user would predict:
    ///   * sliding all the way down mutes, so the speaker icon matches reality,
    ///   * sliding up from silence unmutes, so sound actually returns,
    ///   * "volume > 0 but still muted" is never left behind.
    public static func decide(targetVolume: Double,
                              currentlyMuted: Bool,
                              startedMuted: Bool) -> MuteAction {
        if targetVolume <= silenceThreshold {
            return currentlyMuted ? .none : .mute
        }
        if currentlyMuted || startedMuted {
            return .unmute
        }
        return .none
    }
}

// MARK: - DDC scaling

public enum DDCScaling {

    /// Converts 0...1 into the monitor's own units.
    ///
    /// The maximum is whatever the monitor reported for VCP 0x10. Assuming 100
    /// is the classic DDC bug: plenty of panels use 255, some use 20, and writing
    /// 100 to a 20-max monitor either clips or is rejected outright.
    public static func native(normalized: Double, maximum: UInt16) -> UInt16 {
        guard maximum > 0 else { return 0 }
        let scaled = (clamp01(normalized) * Double(maximum)).rounded()
        return UInt16(clamp(Int(scaled), 0, Int(maximum)))
    }

    public static func normalized(native: UInt16, maximum: UInt16) -> Double {
        guard maximum > 0 else { return 0 }
        return clamp01(Double(min(native, maximum)) / Double(maximum))
    }
}

// MARK: - Chiclets

public enum HUDScaling {
    /// Filled segments for a metered HUD. Rounds half up so nudging off zero
    /// lights the first segment, matching the system's behaviour.
    public static func filledChiclets(level: Double, total: Int) -> Int {
        guard total > 0 else { return 0 }
        let filled = (clamp01(level) * Double(total)).rounded()
        return clamp(Int(filled), 0, total)
    }
}
