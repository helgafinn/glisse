//
//  GestureSession.swift
//  GlisseKit
//
//  Per-device, per-finger gesture state. Pure value semantics: no clock, no
//  system calls, no AppKit. This is what makes the engine unit-testable.
//

import Foundation

/// The state machine from the spec: IDLE -> CANDIDATE -> ACTIVE -> ENDING -> IDLE.
///
/// `idle` is represented by the absence of a session rather than a case, so an
/// idle device holds nothing at all.
public enum GestureState: String, Sendable, Equatable {
    case candidate
    case active
    case ending
}

/// One tracked finger.
public struct GestureSession: Sendable, Equatable {
    public let touchID: Int32
    public let edge: TrackpadEdge
    public let assignment: EdgeAssignment

    public private(set) var state: GestureState

    public let startX: Double
    public let startY: Double
    public let startTimestamp: TimeInterval

    public private(set) var currentX: Double
    public private(set) var currentY: Double
    /// Y at the previous frame. Deltas are computed against this, never against
    /// startY, so the control is relative and drift-free.
    public private(set) var lastY: Double
    public private(set) var lastTimestamp: TimeInterval

    /// Largest |x - startX| seen while still a candidate.
    public private(set) var peakHorizontalTravel: Double

    /// Sub-threshold vertical movement carried between frames. Without this,
    /// a slow slide that produces deltas below the write resolution would be
    /// silently discarded and the gesture would feel dead.
    public private(set) var residual: Double

    init(touchID: Int32,
         edge: TrackpadEdge,
         assignment: EdgeAssignment,
         x: Double,
         y: Double,
         timestamp: TimeInterval) {
        self.touchID = touchID
        self.edge = edge
        self.assignment = assignment
        self.state = .candidate
        self.startX = x
        self.startY = y
        self.startTimestamp = timestamp
        self.currentX = x
        self.currentY = y
        self.lastY = y
        self.lastTimestamp = timestamp
        self.peakHorizontalTravel = 0
        self.residual = 0
    }

    // MARK: Mutation

    mutating func advance(x: Double, y: Double, timestamp: TimeInterval) {
        currentX = x
        currentY = y
        lastTimestamp = timestamp
        peakHorizontalTravel = max(peakHorizontalTravel, abs(x - startX))
    }

    /// Consumes the accumulated vertical movement since `lastY`.
    mutating func consumeVerticalDelta() -> Double {
        let delta = currentY - lastY
        lastY = currentY
        return delta
    }

    mutating func activate() {
        state = .active
        // Activation consumes the movement that proved intent, so the first
        // adjustment starts from where the finger is now rather than jumping by
        // the whole activation threshold.
        lastY = currentY
    }

    mutating func beginEnding() {
        state = .ending
    }

    mutating func addResidual(_ value: Double) {
        residual = sanitized(residual + value)
    }

    mutating func takeResidual() -> Double {
        let value = residual
        residual = 0
        return value
    }

    /// Total vertical travel since the gesture started.
    public var verticalTravel: Double { currentY - startY }

    public var duration: TimeInterval { lastTimestamp - startTimestamp }
}
