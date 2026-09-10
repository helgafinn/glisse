//
//  Clamp.swift
//  GlisseKit
//
//  Small numeric helpers used everywhere. Kept in one place because "clamp to
//  0...1" and "is this value finite" are the two guards that stop a bad frame
//  from turning into a NaN written to Core Audio.
//

import Foundation

@inlinable
public func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
    min(max(value, lower), upper)
}

/// Clamps into 0...1, treating infinities as the corresponding bound and NaN as
/// zero.
///
/// Infinity is deliberately clamped rather than zeroed: `+inf` means "past the
/// top", and collapsing it to 0 would turn a garbage-high coordinate into a
/// jump to the opposite edge.
@inlinable
public func clamp01(_ value: Double) -> Double {
    if value.isNaN { return 0 }
    return min(max(value, 0), 1)
}

/// Returns `fallback` for NaN / infinity. Every value crossing a system API
/// boundary goes through this.
@inlinable
public func sanitized(_ value: Double, fallback: Double = 0) -> Double {
    value.isFinite ? value : fallback
}

extension Double {
    /// Equality with a tolerance, used for write de-duplication.
    @inlinable
    public func isNearly(_ other: Double, tolerance: Double) -> Bool {
        guard isFinite, other.isFinite else { return false }
        return abs(self - other) <= tolerance
    }

    /// 0...1 mapped onto integer steps, used for haptic tick accounting and
    /// HUD chiclets.
    @inlinable
    public func quantized(steps: Int) -> Int {
        guard steps > 0, isFinite else { return 0 }
        return Int((clamp01(self) * Double(steps)).rounded())
    }
}
