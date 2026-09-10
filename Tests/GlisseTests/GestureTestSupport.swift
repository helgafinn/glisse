//
//  GestureTestSupport.swift
//  GlisseTests
//
//  Frame builders. The gesture engine is pure, so a "gesture" in a test is just a
//  sequence of frames with synthetic timestamps — no trackpad required.
//

import Foundation
@testable import GlisseKit

let testDevice = "test-trackpad"
let otherDevice = "test-trackpad-2"

/// Builds one frame.
func frame(_ touches: [TrackpadTouch],
           at timestamp: TimeInterval,
           device: String = testDevice) -> TrackpadFrame {
    TrackpadFrame(deviceID: device, timestamp: timestamp, touches: touches)
}

func touch(id: Int32 = 1,
           x: Double,
           y: Double,
           phase: TouchPhase = .moved,
           at timestamp: TimeInterval) -> TrackpadTouch {
    TrackpadTouch(id: id, x: x, y: y, phase: phase, pressure: 1.0, timestamp: timestamp)
}

/// A complete single-finger slide: touch down at (x, startY), move to endY over
/// `steps` frames, then lift.
///
/// `steps` matters: the engine works on frame-to-frame deltas, so a slide
/// delivered in one giant jump is not the same input as a real slide.
func slideFrames(id: Int32 = 1,
                 x: Double,
                 from startY: Double,
                 to endY: Double,
                 steps: Int = 10,
                 startTime: TimeInterval = 100,
                 interval: TimeInterval = 0.008,
                 device: String = testDevice,
                 lift: Bool = true) -> [TrackpadFrame] {
    var frames: [TrackpadFrame] = []
    var time = startTime

    frames.append(frame([touch(id: id, x: x, y: startY, phase: .began, at: time)],
                        at: time, device: device))

    for step in 1...max(steps, 1) {
        time += interval
        let progress = Double(step) / Double(max(steps, 1))
        let y = startY + (endY - startY) * progress
        frames.append(frame([touch(id: id, x: x, y: y, phase: .moved, at: time)],
                            at: time, device: device))
    }

    if lift {
        time += interval
        frames.append(frame([touch(id: id, x: x, y: endY, phase: .ended, at: time)],
                            at: time, device: device))
    }
    return frames
}

extension EdgeGestureEngine {
    /// Runs a sequence and returns everything produced.
    func run(_ frames: [TrackpadFrame]) -> EngineOutput {
        var actions: [EdgeAction] = []
        var lifecycle: [GestureLifecycle] = []
        for f in frames {
            let output = process(f)
            actions.append(contentsOf: output.actions)
            lifecycle.append(contentsOf: output.lifecycle)
        }
        return EngineOutput(actions: actions, lifecycle: lifecycle)
    }
}

/// Default configuration for tests: matches shipped defaults so the tests
/// exercise what users actually get.
func testConfiguration(
    edgeWidth: Double = 0.08,
    bottomQuarterOnly: Bool = false,
    verticalActivationThreshold: Double = 0.011,
    horizontalRejectThreshold: Double = 0.045,
    sensitivity: Double = 1.4,
    invertVertical: Bool = false,
    left: EdgeAssignment = .brightness,
    right: EdgeAssignment = .volume,
    modifierSatisfied: Bool = true,
    typingSuppressed: Bool = false,
    isEnabled: Bool = true,
    maximumSimultaneousTouches: Int = 1
) -> GestureConfiguration {
    GestureConfiguration(
        edgeWidth: edgeWidth,
        bottomQuarterOnly: bottomQuarterOnly,
        bottomRegionHeight: 0.25,
        verticalActivationThreshold: verticalActivationThreshold,
        horizontalRejectThreshold: horizontalRejectThreshold,
        candidateTimeout: 1.2,
        sensitivity: sensitivity,
        invertVertical: invertVertical,
        leftAssignment: left,
        rightAssignment: right,
        modifierSatisfied: modifierSatisfied,
        typingSuppressed: typingSuppressed,
        isEnabled: isEnabled,
        maximumSimultaneousTouches: maximumSimultaneousTouches)
}
