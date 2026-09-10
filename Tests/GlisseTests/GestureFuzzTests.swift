//
//  GestureFuzzTests.swift
//  GlisseTests
//
//  Spec §53. Random and adversarial frame sequences. The engine must never
//  crash, never produce NaN, never emit an out-of-range delta, and never leave a
//  permanently active session behind.
//
//  Seeded so a failure is reproducible.
//

import XCTest
@testable import GlisseKit

final class GestureFuzzTests: XCTestCase {

    /// Small deterministic PRNG so failures can be replayed from the seed.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    func testRandomFrameSequencesNeverMisbehave() {
        for seed in UInt64(1)...40 {
            var generator = SeededGenerator(seed: seed)
            let engine = EdgeGestureEngine(configuration: randomConfiguration(&generator))

            var time = Double.random(in: 0...1_000, using: &generator)
            var liveIDs: Set<Int32> = []

            for _ in 0..<600 {
                time += Double.random(in: 0...0.05, using: &generator)

                let touchCount = Int.random(in: 0...5, using: &generator)
                var touches: [TrackpadTouch] = []

                for _ in 0..<touchCount {
                    let id = Int32.random(in: 1...6, using: &generator)
                    let phase: TouchPhase = {
                        switch Int.random(in: 0...5, using: &generator) {
                        case 0: return .began
                        case 1: return .ended
                        case 2: return .cancelled
                        case 3: return .stationary
                        default: return .moved
                        }
                    }()
                    if phase == .began { liveIDs.insert(id) }
                    if !phase.isActive { liveIDs.remove(id) }

                    touches.append(TrackpadTouch(
                        id: id,
                        x: Double.random(in: -0.5...1.5, using: &generator),
                        y: Double.random(in: -0.5...1.5, using: &generator),
                        phase: phase,
                        pressure: Double.random(in: 0...5, using: &generator),
                        timestamp: time))
                }

                let deviceID = Bool.random(using: &generator) ? testDevice : otherDevice
                let output = engine.process(
                    TrackpadFrame(deviceID: deviceID, timestamp: time, touches: touches))

                for action in output.actions {
                    let delta: Double
                    switch action {
                    case .volume(let d): delta = d
                    case .brightness(let d): delta = d
                    }
                    XCTAssertFalse(delta.isNaN, "seed \(seed): NaN delta")
                    XCTAssertTrue(delta.isFinite, "seed \(seed): non-finite delta")
                    XCTAssertLessThanOrEqual(abs(delta), 0.25 + 1e-9,
                                             "seed \(seed): delta out of bounds")
                }
            }

            // Draining every contact must leave no active gesture behind.
            time += 1
            _ = engine.process(TrackpadFrame(deviceID: testDevice, timestamp: time, touches: []))
            _ = engine.process(TrackpadFrame(deviceID: otherDevice, timestamp: time, touches: []))
            XCTAssertFalse(engine.hasActiveGesture, "seed \(seed): gesture stuck active")
        }
    }

    private func randomConfiguration(_ generator: inout SeededGenerator) -> GestureConfiguration {
        GestureConfiguration(
            edgeWidth: Double.random(in: 0.04...0.15, using: &generator),
            bottomQuarterOnly: Bool.random(using: &generator),
            bottomRegionHeight: 0.25,
            verticalActivationThreshold: Double.random(in: 0.002...0.05, using: &generator),
            horizontalRejectThreshold: Double.random(in: 0.01...0.4, using: &generator),
            candidateTimeout: Double.random(in: 0.2...2.0, using: &generator),
            sensitivity: Double.random(in: 0.2...4.0, using: &generator),
            invertVertical: Bool.random(using: &generator),
            leftAssignment: [.brightness, .volume, EdgeAssignment.none].randomElement(using: &generator)!,
            rightAssignment: [.brightness, .volume, EdgeAssignment.none].randomElement(using: &generator)!,
            modifierSatisfied: Bool.random(using: &generator),
            typingSuppressed: Bool.random(using: &generator),
            isEnabled: true,
            maximumSimultaneousTouches: Int.random(in: 1...3, using: &generator))
    }

    // MARK: - Specific adversarial inputs

    func testNonFiniteCoordinatesAreNeutralised() {
        // TrackpadTouch clamps at construction, so this documents the guarantee.
        let engine = EdgeGestureEngine(configuration: testConfiguration())
        let bad = TrackpadTouch(id: 1, x: .nan, y: .infinity, phase: .began,
                               pressure: .nan, timestamp: 10)
        XCTAssertEqual(bad.x, 0)
        XCTAssertEqual(bad.y, 1)
        let output = engine.process(frame([bad], at: 10))
        XCTAssertTrue(output.actions.isEmpty)
    }

    func testDuplicateIdenticalFramesProduceNoDrift() {
        let engine = EdgeGestureEngine(configuration: testConfiguration())
        var time = 100.0
        _ = engine.process(frame([touch(x: 0.98, y: 0.3, phase: .began, at: time)], at: time))
        time += 0.01
        _ = engine.process(frame([touch(x: 0.98, y: 0.36, phase: .moved, at: time)], at: time))

        // The same frame delivered twenty times must not accumulate change.
        let repeated = frame([touch(x: 0.98, y: 0.36, phase: .moved, at: time)], at: time)
        var total = 0.0
        for _ in 0..<20 {
            total += engine.process(repeated).totalVolumeDelta
        }
        XCTAssertEqual(total, 0, accuracy: 1e-9)
    }

    func testOutOfOrderTimestampsDoNotCrash() {
        let engine = EdgeGestureEngine(configuration: testConfiguration())
        _ = engine.process(frame([touch(x: 0.98, y: 0.3, phase: .began, at: 100)], at: 100))
        // Time going backwards, as it can if a source restarts.
        let output = engine.process(frame([touch(x: 0.98, y: 0.5, phase: .moved, at: 50)], at: 50))
        for delta in output.volumeDeltas {
            XCTAssertTrue(delta.isFinite)
        }
    }

    func testEmptyFrameStormIsHarmless() {
        let engine = EdgeGestureEngine(configuration: testConfiguration())
        for step in 0..<1_000 {
            let output = engine.process(frame([], at: Double(step) * 0.008))
            XCTAssertTrue(output.isEmpty)
        }
        XCTAssertFalse(engine.hasActiveGesture)
    }

    func testManySimultaneousContactsDoNotActivate() {
        let engine = EdgeGestureEngine(configuration: testConfiguration())
        var time = 100.0
        var output = EngineOutput.empty
        for step in 0..<30 {
            time += 0.008
            let touches = (1...5).map { id in
                touch(id: Int32(id),
                      x: Double(id) * 0.19,
                      y: 0.2 + 0.02 * Double(step),
                      phase: step == 0 ? .began : .moved,
                      at: time)
            }
            let step = engine.process(frame(touches, at: time))
            output = EngineOutput(actions: output.actions + step.actions,
                                  lifecycle: output.lifecycle + step.lifecycle)
        }
        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertEqual(output.beganCount, 0)
    }

    func testIDReuseAfterLiftStartsAFreshEvaluation() {
        let engine = EdgeGestureEngine(configuration: testConfiguration())
        // Contact 1 born in the centre: rejected.
        _ = engine.process(frame([touch(id: 1, x: 0.5, y: 0.5, phase: .began, at: 100)], at: 100))
        _ = engine.process(frame([touch(id: 1, x: 0.5, y: 0.5, phase: .ended, at: 100.1)], at: 100.1))
        // The same id reused, now born on the edge: must be eligible again.
        let output = engine.run(slideFrames(id: 1, x: 0.98, from: 0.3, to: 0.7, startTime: 101))
        XCTAssertEqual(output.beganCount, 1)
    }
}
