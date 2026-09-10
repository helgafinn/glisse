//
//  ThreeFingerTapRecognizer.swift
//  GlisseKit
//
//  Recognises an intentional three-finger *tap* and nothing else.
//
//  Pure, like the gesture engine: frames in, at most one `middleClick` out.
//  The hard part is not detecting three fingers, it is refusing every
//  three-finger swipe, Mission Control gesture and lazy drag — macOS uses
//  three-finger movement for its own things and stealing those would be worse
//  than not having the feature.
//

import Foundation

public struct ThreeFingerTapConfiguration: Sendable, Equatable {
    /// Longest a tap may last, first touch down to last touch up.
    public var maximumDuration: TimeInterval
    /// All three fingers must land within this window of each other.
    public var simultaneityWindow: TimeInterval
    /// Per-finger normalised travel budget.
    public var maximumMovement: Double
    /// Exact contact count.
    public var requiredFingerCount: Int
    /// Ignore taps that arrive within this long of the previous one. Stops a
    /// bouncy release producing a double middle click.
    public var rearmInterval: TimeInterval

    public init(maximumDuration: TimeInterval = 0.25,
                simultaneityWindow: TimeInterval = 0.09,
                maximumMovement: Double = 0.035,
                requiredFingerCount: Int = 3,
                rearmInterval: TimeInterval = 0.30) {
        self.maximumDuration = maximumDuration
        self.simultaneityWindow = simultaneityWindow
        self.maximumMovement = maximumMovement
        self.requiredFingerCount = requiredFingerCount
        self.rearmInterval = rearmInterval
    }

    public static let `default` = ThreeFingerTapConfiguration()
}

public enum TapRecognition: Sendable, Equatable {
    case middleClick
}

public final class ThreeFingerTapRecognizer {

    private struct Contact {
        let startX: Double
        let startY: Double
        let startTime: TimeInterval
        var travel: Double
    }

    private struct DeviceState {
        var contacts: [Int32: Contact] = [:]
        var peakContactCount: Int = 0
        var firstDownTime: TimeInterval = 0
        /// Latest touch-down in this gesture. Recorded as contacts arrive
        /// because contacts are removed on lift, and simultaneity has to be
        /// judged after the last finger is already gone.
        var lastDownTime: TimeInterval = 0
        var lastUpTime: TimeInterval = 0
        var invalidated: Bool = false
        var invalidReason: String = ""
    }

    private var states: [String: DeviceState] = [:]
    private var lastEmitTime: TimeInterval = -.greatestFiniteMagnitude

    public var configuration: ThreeFingerTapConfiguration
    public private(set) var lastRejectReason: String = ""

    public init(configuration: ThreeFingerTapConfiguration = .default) {
        self.configuration = configuration
    }

    /// - Parameters:
    ///   - frame: the frame to consider.
    ///   - sliderGestureActive: true while an edge slider is running. A tap is
    ///     never recognised then — mixing the two would be indefensible.
    public func process(_ frame: TrackpadFrame, sliderGestureActive: Bool) -> [TapRecognition] {
        var state = states[frame.deviceID] ?? DeviceState()
        let active = frame.activeTouches

        if sliderGestureActive {
            state.invalidated = true
            state.invalidReason = "slider active"
        }

        // New contacts.
        for touch in active where state.contacts[touch.id] == nil {
            if state.contacts.isEmpty && state.peakContactCount == 0 {
                state.firstDownTime = touch.timestamp
            }
            state.lastDownTime = max(state.lastDownTime, touch.timestamp)
            state.contacts[touch.id] = Contact(startX: touch.x,
                                               startY: touch.y,
                                               startTime: touch.timestamp,
                                               travel: 0)
            state.peakContactCount = max(state.peakContactCount, state.contacts.count)

            if state.peakContactCount > configuration.requiredFingerCount {
                state.invalidated = true
                state.invalidReason = "too many fingers"
            }
        }

        // Movement budget.
        for touch in active {
            guard var contact = state.contacts[touch.id] else { continue }
            let dx = touch.x - contact.startX
            let dy = touch.y - contact.startY
            contact.travel = max(contact.travel, (dx * dx + dy * dy).squareRoot())
            state.contacts[touch.id] = contact

            if contact.travel > configuration.maximumMovement {
                state.invalidated = true
                state.invalidReason = "moved too far"
            }
        }

        // Duration budget, checked while fingers are still down so a long hold
        // is rejected as soon as it exceeds the limit.
        if let earliest = state.contacts.values.map(\.startTime).min() {
            if frame.timestamp - earliest > configuration.maximumDuration {
                state.invalidated = true
                if state.invalidReason.isEmpty { state.invalidReason = "held too long" }
            }
        }

        // Retire lifted contacts.
        let presentIDs = Set(active.map(\.id))
        for (id, _) in state.contacts where !presentIDs.contains(id) {
            state.contacts.removeValue(forKey: id)
            state.lastUpTime = frame.timestamp
        }
        for touch in frame.touches where !touch.phase.isActive {
            if state.contacts.removeValue(forKey: touch.id) != nil {
                state.lastUpTime = max(state.lastUpTime, touch.timestamp)
            }
            if touch.phase == .cancelled {
                state.invalidated = true
                if state.invalidReason.isEmpty { state.invalidReason = "cancelled" }
            }
        }

        // Nothing down: the gesture is complete, decide.
        guard state.contacts.isEmpty else {
            states[frame.deviceID] = state
            return []
        }

        defer { states[frame.deviceID] = DeviceState() }

        guard state.peakContactCount > 0 else { return [] }

        if state.invalidated {
            lastRejectReason = state.invalidReason
            return []
        }
        guard state.peakContactCount == configuration.requiredFingerCount else {
            lastRejectReason = "wrong finger count (\(state.peakContactCount))"
            return []
        }

        let spread = state.lastDownTime - state.firstDownTime
        guard spread <= configuration.simultaneityWindow else {
            lastRejectReason = "fingers landed \(String(format: "%.0f", spread * 1000))ms apart"
            return []
        }

        let duration = state.lastUpTime - state.firstDownTime
        guard duration >= 0, duration <= configuration.maximumDuration else {
            lastRejectReason = "duration \(String(format: "%.3f", duration))s"
            return []
        }

        guard state.lastUpTime - lastEmitTime >= configuration.rearmInterval else {
            lastRejectReason = "re-arm interval"
            return []
        }

        lastEmitTime = state.lastUpTime
        lastRejectReason = ""
        return [.middleClick]
    }

    public func reset() {
        states.removeAll()
    }

    public func reset(deviceID: String) {
        states.removeValue(forKey: deviceID)
    }
}
