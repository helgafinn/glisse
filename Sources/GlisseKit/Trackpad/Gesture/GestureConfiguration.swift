//
//  GestureConfiguration.swift
//  GlisseKit
//
//  Everything the gesture engine needs, as a value type. Derived from
//  AppSettings plus a couple of runtime facts (is a modifier held, is typing
//  active) so the engine itself has no dependencies and no clock of its own.
//

import Foundation

public struct GestureConfiguration: Sendable, Equatable {

    // MARK: Eligibility

    /// Normalised width of each edge strip. A touch qualifies when it *begins*
    /// at x <= edgeWidth (left) or x >= 1 - edgeWidth (right).
    public var edgeWidth: Double

    /// Restrict activation to the lower part of the edge.
    public var bottomQuarterOnly: Bool
    /// Height of the "bottom quarter" region, measured from y = 0 upwards.
    public var bottomRegionHeight: Double

    // MARK: Intent

    /// Vertical travel required before a candidate becomes active. Guards
    /// against a resting finger's sensor noise turning into a volume change.
    public var verticalActivationThreshold: Double

    /// Horizontal travel that disqualifies a candidate before activation.
    /// A finger heading sideways is navigating, not sliding.
    public var horizontalRejectThreshold: Double

    /// A candidate that has not established vertical intent within this long is
    /// abandoned. Stops a finger parked on the edge from arming indefinitely and
    /// then jumping when it eventually moves.
    public var candidateTimeout: TimeInterval

    // MARK: Output

    /// Multiplies normalised vertical travel into value change.
    /// 1.0 means a full-height swipe changes the value by 1.0 (0% to 100%).
    public var sensitivity: Double

    /// Set when the raw source's Y axis points down instead of up.
    public var invertVertical: Bool

    // MARK: Mapping

    public var leftAssignment: EdgeAssignment
    public var rightAssignment: EdgeAssignment

    // MARK: Gating (evaluated by the caller, passed in)

    /// False when a required modifier is not satisfied, or the toggle is off.
    public var modifierSatisfied: Bool

    /// True while typing suppression is in force. Blocks *new* activations only.
    public var typingSuppressed: Bool

    /// Master switch.
    public var isEnabled: Bool

    // MARK: Multi-touch policy

    /// Maximum simultaneous contacts on the device for an edge gesture to be
    /// eligible. Two or more fingers means scrolling / swiping, not sliding.
    public var maximumSimultaneousTouches: Int

    public init(edgeWidth: Double = 0.08,
                bottomQuarterOnly: Bool = false,
                bottomRegionHeight: Double = 0.25,
                verticalActivationThreshold: Double = 0.011,
                horizontalRejectThreshold: Double = 0.045,
                candidateTimeout: TimeInterval = 1.2,
                sensitivity: Double = 1.4,
                invertVertical: Bool = false,
                leftAssignment: EdgeAssignment = .brightness,
                rightAssignment: EdgeAssignment = .volume,
                modifierSatisfied: Bool = true,
                typingSuppressed: Bool = false,
                isEnabled: Bool = true,
                maximumSimultaneousTouches: Int = 1) {
        self.edgeWidth = edgeWidth
        self.bottomQuarterOnly = bottomQuarterOnly
        self.bottomRegionHeight = bottomRegionHeight
        self.verticalActivationThreshold = verticalActivationThreshold
        self.horizontalRejectThreshold = horizontalRejectThreshold
        self.candidateTimeout = candidateTimeout
        self.sensitivity = sensitivity
        self.invertVertical = invertVertical
        self.leftAssignment = leftAssignment
        self.rightAssignment = rightAssignment
        self.modifierSatisfied = modifierSatisfied
        self.typingSuppressed = typingSuppressed
        self.isEnabled = isEnabled
        self.maximumSimultaneousTouches = maximumSimultaneousTouches
    }

    // MARK: Derived

    public var leftEdgeMaxX: Double { edgeWidth }
    public var rightEdgeMinX: Double { 1.0 - edgeWidth }

    /// Which edge a starting x belongs to, or nil.
    public func edge(forStartX x: Double) -> TrackpadEdge? {
        if x <= leftEdgeMaxX { return .left }
        if x >= rightEdgeMinX { return .right }
        return nil
    }

    public func assignment(for edge: TrackpadEdge) -> EdgeAssignment {
        edge == .left ? leftAssignment : rightAssignment
    }

    /// Builds the engine configuration from persisted settings plus live gating.
    public static func from(settings: AppSettings,
                            modifierSatisfied: Bool,
                            typingSuppressed: Bool) -> GestureConfiguration {
        GestureConfiguration(
            edgeWidth: settings.edgeWidth,
            bottomQuarterOnly: settings.bottomQuarterOnly,
            bottomRegionHeight: 0.25,
            verticalActivationThreshold: settings.verticalActivationThreshold,
            horizontalRejectThreshold: settings.horizontalRejectThreshold,
            candidateTimeout: 1.2,
            sensitivity: settings.activeSensitivity,
            invertVertical: settings.invertVerticalAxis,
            leftAssignment: settings.assignment(for: .left),
            rightAssignment: settings.assignment(for: .right),
            modifierSatisfied: modifierSatisfied,
            typingSuppressed: typingSuppressed,
            isEnabled: settings.isEnabled,
            maximumSimultaneousTouches: 1
        )
    }
}
