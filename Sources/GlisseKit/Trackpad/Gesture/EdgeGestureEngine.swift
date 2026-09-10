//
//  EdgeGestureEngine.swift
//  GlisseKit
//
//  The heart of Glisse, and deliberately the most boring part of it: a pure
//  state machine over `TrackpadFrame` values.
//
//  No clock, no AppKit, no system calls, no I/O. Feed it frames, get semantic
//  adjustments. That is what makes it possible to unit test false-activation
//  behaviour, which per the spec is the single most important quality metric.
//
//  THE RULE (spec §79). Being near an edge is not enough. A gesture activates
//  only when the finger:
//    1. BEGINS inside the eligible edge strip,
//    2. satisfies the modifier requirement at that moment,
//    3. is not typing-suppressed at that moment,
//    4. then establishes vertical intent without wandering sideways,
//    5. stays the same finger ID throughout,
//    6. drives value changes from frame-to-frame deltas, never absolute Y,
//    7. stops the instant that finger leaves,
//    8. leaves no state behind.
//

import Foundation

// MARK: - Output

/// A semantic adjustment. Deltas are in normalised value units: +0.1 means
/// "raise by 10 percentage points". Clamping against the real current value is
/// the controller's job, not the engine's.
public enum EdgeAction: Sendable, Equatable {
    case volume(delta: Double)
    case brightness(delta: Double)
}

public enum GestureLifecycle: Sendable, Equatable {
    case began(deviceID: String, edge: TrackpadEdge, assignment: EdgeAssignment, touchID: Int32)
    case ended(deviceID: String, edge: TrackpadEdge, assignment: EdgeAssignment, touchID: Int32)
}

public struct EngineOutput: Sendable, Equatable {
    public var actions: [EdgeAction]
    public var lifecycle: [GestureLifecycle]

    public static let empty = EngineOutput(actions: [], lifecycle: [])

    public var isEmpty: Bool { actions.isEmpty && lifecycle.isEmpty }
}

// Small accessors, used by the diagnostics, the self test and the unit tests.
public extension EngineOutput {
    var volumeDeltas: [Double] {
        actions.compactMap { if case .volume(let d) = $0 { return d } else { return nil } }
    }
    var brightnessDeltas: [Double] {
        actions.compactMap { if case .brightness(let d) = $0 { return d } else { return nil } }
    }
    var totalVolumeDelta: Double { volumeDeltas.reduce(0, +) }
    var totalBrightnessDelta: Double { brightnessDeltas.reduce(0, +) }
    var beganCount: Int {
        lifecycle.reduce(0) { count, event in
            if case .began = event { return count + 1 }
            return count
        }
    }
    var endedCount: Int {
        lifecycle.reduce(0) { count, event in
            if case .ended = event { return count + 1 }
            return count
        }
    }
}

/// Live numbers for the diagnostics window. Written on every processed frame.
public struct GestureDiagnostics: Sendable, Equatable {
    public var lastRawDeltaY: Double = 0
    public var lastScaledDelta: Double = 0
    public var lastEmittedDelta: Double = 0
    public var candidateCount: Int = 0
    public var activeCount: Int = 0
    public var rejectedCount: Int = 0
    public var lastRejectReason: String = ""
    public var lastStartX: Double = 0
    public var lastStartY: Double = 0
    public var lastX: Double = 0
    public var lastY: Double = 0
    public var framesProcessed: Int = 0
}

// MARK: - Engine

public final class EdgeGestureEngine {

    /// Per-touch tracking. A touch that was ineligible when it appeared stays
    /// ineligible for its whole life — that is what stops "start in the middle,
    /// slide to the edge" from ever arming the slider.
    private enum Tracked {
        case rejected(reason: String)
        case session(GestureSession)
    }

    private var devices: [String: [Int32: Tracked]] = [:]

    /// Updated by the coordinator whenever settings or gating change.
    public var configuration: GestureConfiguration

    public private(set) var diagnostics = GestureDiagnostics()

    /// Largest value change a single frame may produce. A dropped frame or a
    /// garbage coordinate must not slam the volume from 20% to 100%.
    private let maximumPerFrameDelta: Double = 0.25

    /// Below this, a delta is sensor noise. Accumulated in the session residual
    /// instead of being thrown away, so slow slides still move.
    private let deltaEpsilon: Double = 1e-5

    public init(configuration: GestureConfiguration = GestureConfiguration()) {
        self.configuration = configuration
    }

    // MARK: - Entry point

    /// Consumes one frame and returns the adjustments it implies.
    public func process(_ frame: TrackpadFrame) -> EngineOutput {
        diagnostics.framesProcessed += 1

        var tracked = devices[frame.deviceID] ?? [:]
        var actions: [EdgeAction] = []
        var lifecycle: [GestureLifecycle] = []

        let active = frame.activeTouches
        let presentIDs = Set(active.map(\.id))

        // ------------------------------------------------------------------
        // 1. Retire touches that are gone.
        //
        // Sources are not obliged to deliver a clean `.ended` phase — a finger
        // lifting can simply stop appearing. Disappearance is authoritative.
        // ------------------------------------------------------------------
        for (touchID, entry) in tracked where !presentIDs.contains(touchID) {
            if case .session(let session) = entry, session.state == .active {
                lifecycle.append(.ended(deviceID: frame.deviceID,
                                        edge: session.edge,
                                        assignment: session.assignment,
                                        touchID: session.touchID))
            }
            tracked.removeValue(forKey: touchID)
        }

        // Explicit end/cancel phases retire immediately too.
        for touch in frame.touches where !touch.phase.isActive {
            if let entry = tracked[touch.id] {
                if case .session(let session) = entry, session.state == .active {
                    lifecycle.append(.ended(deviceID: frame.deviceID,
                                            edge: session.edge,
                                            assignment: session.assignment,
                                            touchID: session.touchID))
                }
                tracked.removeValue(forKey: touch.id)
            }
        }

        // ------------------------------------------------------------------
        // 2. Too many fingers: this is scrolling / swiping, not sliding.
        //
        // Ends any active gesture and refuses new ones for as long as the extra
        // contacts are down.
        // ------------------------------------------------------------------
        let tooManyTouches = active.count > configuration.maximumSimultaneousTouches
        if tooManyTouches {
            for (touchID, entry) in tracked {
                if case .session(let session) = entry {
                    if session.state == .active {
                        lifecycle.append(.ended(deviceID: frame.deviceID,
                                                edge: session.edge,
                                                assignment: session.assignment,
                                                touchID: session.touchID))
                    }
                    tracked[touchID] = .rejected(reason: "multi-touch")
                }
            }
            devices[frame.deviceID] = tracked.isEmpty ? nil : tracked
            updateDiagnostics(tracked: tracked, reason: "multi-touch")
            return EngineOutput(actions: actions, lifecycle: lifecycle)
        }

        // Only one gesture per device may ever be active.
        let hasActiveElsewhere: (Int32) -> Bool = { candidateID in
            tracked.contains { key, value in
                guard key != candidateID, case .session(let s) = value else { return false }
                return s.state == .active
            }
        }

        // ------------------------------------------------------------------
        // 3. Per-touch update.
        // ------------------------------------------------------------------
        for touch in active {
            switch tracked[touch.id] {

            case .rejected:
                continue   // sticky for the life of the contact

            case .none:
                // First sight of this contact.
                let outcome = evaluateNewTouch(touch, frame: frame, hasActiveElsewhere: hasActiveElsewhere(touch.id))
                switch outcome {
                case .rejected(let reason):
                    tracked[touch.id] = .rejected(reason: reason)
                    diagnostics.lastRejectReason = reason
                case .candidate(let session):
                    tracked[touch.id] = .session(session)
                    diagnostics.lastStartX = session.startX
                    diagnostics.lastStartY = session.startY
                }

            case .session(var session):
                session.advance(x: touch.x, y: touch.y, timestamp: touch.timestamp)

                switch session.state {
                case .candidate:
                    // Sideways wander disqualifies before activation.
                    if session.peakHorizontalTravel > configuration.horizontalRejectThreshold {
                        tracked[touch.id] = .rejected(reason: "horizontal motion")
                        diagnostics.lastRejectReason = "horizontal motion"
                        continue
                    }

                    // A finger parked on the edge should not stay armed forever.
                    if session.duration > configuration.candidateTimeout,
                       abs(session.verticalTravel) < configuration.verticalActivationThreshold {
                        tracked[touch.id] = .rejected(reason: "candidate timeout")
                        diagnostics.lastRejectReason = "candidate timeout"
                        continue
                    }

                    // Vertical intent established?
                    if abs(session.verticalTravel) >= configuration.verticalActivationThreshold {
                        if hasActiveElsewhere(touch.id) {
                            tracked[touch.id] = .rejected(reason: "another gesture active")
                            diagnostics.lastRejectReason = "another gesture active"
                            continue
                        }
                        session.activate()
                        lifecycle.append(.began(deviceID: frame.deviceID,
                                                edge: session.edge,
                                                assignment: session.assignment,
                                                touchID: session.touchID))
                    }
                    tracked[touch.id] = .session(session)

                case .active:
                    // A hold-modifier released mid-slide ends the gesture: the
                    // user let go of the key, so they are done.
                    if !configuration.modifierSatisfied || !configuration.isEnabled {
                        lifecycle.append(.ended(deviceID: frame.deviceID,
                                                edge: session.edge,
                                                assignment: session.assignment,
                                                touchID: session.touchID))
                        tracked[touch.id] = .rejected(reason: "gating lost")
                        diagnostics.lastRejectReason = "gating lost"
                        continue
                    }

                    if let action = emitAdjustment(&session) {
                        actions.append(action)
                    }
                    tracked[touch.id] = .session(session)

                case .ending:
                    tracked.removeValue(forKey: touch.id)
                }
            }

            diagnostics.lastX = touch.x
            diagnostics.lastY = touch.y
        }

        devices[frame.deviceID] = tracked.isEmpty ? nil : tracked
        updateDiagnostics(tracked: tracked, reason: diagnostics.lastRejectReason)

        return EngineOutput(actions: actions, lifecycle: lifecycle)
    }

    // MARK: - New touch evaluation

    private enum NewTouchOutcome {
        case rejected(reason: String)
        case candidate(GestureSession)
    }

    private func evaluateNewTouch(_ touch: TrackpadTouch,
                                  frame: TrackpadFrame,
                                  hasActiveElsewhere: Bool) -> NewTouchOutcome {
        guard configuration.isEnabled else {
            return .rejected(reason: "disabled")
        }
        // Gating is evaluated once, at birth. Deciding again later would let a
        // gesture spring to life mid-contact, which is exactly the surprising
        // behaviour the spec warns against.
        guard configuration.modifierSatisfied else {
            return .rejected(reason: "modifier not satisfied")
        }
        guard !configuration.typingSuppressed else {
            return .rejected(reason: "typing suppression")
        }
        guard !hasActiveElsewhere else {
            return .rejected(reason: "another gesture active")
        }
        guard let edge = configuration.edge(forStartX: touch.x) else {
            return .rejected(reason: "not an edge")
        }
        let assignment = configuration.assignment(for: edge)
        guard assignment != .none else {
            return .rejected(reason: "edge unassigned")
        }
        if configuration.bottomQuarterOnly {
            // y = 0 is the physical bottom of the trackpad (see the coordinate
            // contract in TrackpadTouch.swift), so the bottom region is
            // 0 ... bottomRegionHeight.
            guard touch.y <= configuration.bottomRegionHeight else {
                return .rejected(reason: "outside bottom region")
            }
        }

        return .candidate(GestureSession(touchID: touch.id,
                                         edge: edge,
                                         assignment: assignment,
                                         x: touch.x,
                                         y: touch.y,
                                         timestamp: touch.timestamp))
    }

    // MARK: - Adjustment

    private func emitAdjustment(_ session: inout GestureSession) -> EdgeAction? {
        var rawDelta = session.consumeVerticalDelta()
        diagnostics.lastRawDeltaY = rawDelta

        if configuration.invertVertical {
            rawDelta = -rawDelta
        }

        // Carry forward anything too small to act on last frame.
        rawDelta += session.takeResidual()

        guard rawDelta.isFinite else {
            diagnostics.lastScaledDelta = 0
            diagnostics.lastEmittedDelta = 0
            return nil
        }

        var scaled = rawDelta * configuration.sensitivity
        diagnostics.lastScaledDelta = scaled

        if abs(scaled) < deltaEpsilon {
            session.addResidual(rawDelta)
            diagnostics.lastEmittedDelta = 0
            return nil
        }

        scaled = clamp(scaled, -maximumPerFrameDelta, maximumPerFrameDelta)
        diagnostics.lastEmittedDelta = scaled

        switch session.assignment {
        case .volume:     return .volume(delta: scaled)
        case .brightness: return .brightness(delta: scaled)
        case .none:       return nil
        }
    }

    // MARK: - State management

    /// Clears everything. Used on wake, on disable and when a touch source is
    /// swapped, so no session survives across a discontinuity.
    public func reset() {
        devices.removeAll()
        diagnostics.candidateCount = 0
        diagnostics.activeCount = 0
        diagnostics.rejectedCount = 0
    }

    /// Clears one device, e.g. a Magic Trackpad that just disconnected.
    public func reset(deviceID: String) {
        devices.removeValue(forKey: deviceID)
    }

    /// Ends any in-flight gesture and reports the lifecycle events so callers
    /// can release cursor freeze and hide the HUD. Used when the app is
    /// disabled, loses permission or is about to sleep.
    public func cancelAll() -> [GestureLifecycle] {
        var events: [GestureLifecycle] = []
        for (deviceID, tracked) in devices {
            for (_, entry) in tracked {
                if case .session(let session) = entry, session.state == .active {
                    events.append(.ended(deviceID: deviceID,
                                         edge: session.edge,
                                         assignment: session.assignment,
                                         touchID: session.touchID))
                }
            }
        }
        devices.removeAll()
        return events
    }

    /// True while any device has an active slider gesture.
    public var hasActiveGesture: Bool {
        devices.values.contains { tracked in
            tracked.values.contains { entry in
                if case .session(let s) = entry { return s.state == .active }
                return false
            }
        }
    }

    private func updateDiagnostics(tracked: [Int32: Tracked], reason: String) {
        var candidates = 0
        var actives = 0
        var rejects = 0
        for entry in tracked.values {
            switch entry {
            case .rejected: rejects += 1
            case .session(let s): s.state == .active ? (actives += 1) : (candidates += 1)
            }
        }
        diagnostics.candidateCount = candidates
        diagnostics.activeCount = actives
        diagnostics.rejectedCount = rejects
        diagnostics.lastRejectReason = reason
    }
}
