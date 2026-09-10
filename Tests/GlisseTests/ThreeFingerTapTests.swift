//
//  ThreeFingerTapTests.swift
//  GlisseTests
//
//  A three-finger tap recogniser is only useful if it stays quiet during every
//  three-finger *swipe*, which macOS uses for Mission Control and desktop
//  switching. Most of these tests are about not firing.
//

import XCTest
@testable import GlisseKit

final class ThreeFingerTapTests: XCTestCase {

    private func recognizer(
        _ configuration: ThreeFingerTapConfiguration = .default
    ) -> ThreeFingerTapRecognizer {
        ThreeFingerTapRecognizer(configuration: configuration)
    }

    /// Builds a tap: `count` fingers down together, held for `duration`, moved by
    /// `movement`, then all lifted.
    private func tapFrames(count: Int,
                           duration: TimeInterval,
                           movement: Double = 0,
                           startSpread: TimeInterval = 0,
                           startTime: TimeInterval = 50) -> [TrackpadFrame] {
        var frames: [TrackpadFrame] = []
        let xs = [0.35, 0.5, 0.65, 0.8]

        // Downs, optionally staggered.
        for index in 0..<count {
            let time = startTime + startSpread * Double(index)
            var touches: [TrackpadTouch] = []
            for existing in 0...index {
                touches.append(touch(id: Int32(existing + 1),
                                     x: xs[existing],
                                     y: 0.5,
                                     phase: existing == index ? .began : .stationary,
                                     at: time))
            }
            frames.append(frame(touches, at: time))
        }

        let downComplete = startTime + startSpread * Double(max(count - 1, 0))

        // Hold, with movement applied linearly.
        let holdSteps = 4
        for step in 1...holdSteps {
            let time = downComplete + duration * Double(step) / Double(holdSteps)
            let offset = movement * Double(step) / Double(holdSteps)
            let touches = (0..<count).map { index in
                touch(id: Int32(index + 1), x: xs[index], y: 0.5 + offset,
                      phase: movement == 0 ? .stationary : .moved, at: time)
            }
            frames.append(frame(touches, at: time))
        }

        // All up.
        let upTime = downComplete + duration
        let touches = (0..<count).map { index in
            touch(id: Int32(index + 1), x: xs[index], y: 0.5 + movement,
                  phase: .ended, at: upTime)
        }
        frames.append(frame(touches, at: upTime))
        return frames
    }

    private func run(_ recognizer: ThreeFingerTapRecognizer,
                     _ frames: [TrackpadFrame],
                     sliderActive: Bool = false) -> [TapRecognition] {
        var results: [TapRecognition] = []
        for f in frames {
            results.append(contentsOf: recognizer.process(f, sliderGestureActive: sliderActive))
        }
        return results
    }

    // MARK: - Should fire

    func testValidTapProducesExactlyOneMiddleClick() {
        let results = run(recognizer(), tapFrames(count: 3, duration: 0.10))
        XCTAssertEqual(results, [.middleClick])
    }

    func testTapAtDurationLimitStillFires() {
        let configuration = ThreeFingerTapConfiguration(maximumDuration: 0.25)
        let results = run(recognizer(configuration), tapFrames(count: 3, duration: 0.24))
        XCTAssertEqual(results, [.middleClick])
    }

    func testTinyMovementIsTolerated() {
        let results = run(recognizer(), tapFrames(count: 3, duration: 0.10, movement: 0.01))
        XCTAssertEqual(results, [.middleClick])
    }

    // MARK: - Should not fire

    func testLongHoldDoesNotFire() {
        let results = run(recognizer(), tapFrames(count: 3, duration: 0.60))
        XCTAssertTrue(results.isEmpty, "a hold is not a tap")
    }

    func testThreeFingerSwipeDoesNotFire() {
        let results = run(recognizer(), tapFrames(count: 3, duration: 0.15, movement: 0.25))
        XCTAssertTrue(results.isEmpty, "a swipe must be left to macOS")
    }

    func testTwoFingersDoNotFire() {
        XCTAssertTrue(run(recognizer(), tapFrames(count: 2, duration: 0.10)).isEmpty)
    }

    func testFourFingersDoNotFire() {
        XCTAssertTrue(run(recognizer(), tapFrames(count: 4, duration: 0.10)).isEmpty)
    }

    func testOneFingerDoesNotFire() {
        XCTAssertTrue(run(recognizer(), tapFrames(count: 1, duration: 0.10)).isEmpty)
    }

    func testStaggeredFingersDoNotFire() {
        // Fingers arriving 150 ms apart is a deliberate sequence, not a tap.
        let results = run(recognizer(), tapFrames(count: 3, duration: 0.10, startSpread: 0.15))
        XCTAssertTrue(results.isEmpty)
    }

    func testTapDuringSliderGestureDoesNotFire() {
        let results = run(recognizer(), tapFrames(count: 3, duration: 0.10), sliderActive: true)
        XCTAssertTrue(results.isEmpty)
    }

    func testCancelledTouchDoesNotFire() {
        var frames = tapFrames(count: 3, duration: 0.10)
        // Replace the final lift with a cancellation.
        frames.removeLast()
        frames.append(frame([
            touch(id: 1, x: 0.35, y: 0.5, phase: .cancelled, at: 50.2),
            touch(id: 2, x: 0.50, y: 0.5, phase: .cancelled, at: 50.2),
            touch(id: 3, x: 0.65, y: 0.5, phase: .cancelled, at: 50.2),
        ], at: 50.2))
        XCTAssertTrue(run(recognizer(), frames).isEmpty)
    }

    // MARK: - No duplicates

    func testTwoRapidTapsProduceOneClick() {
        let recognizer = recognizer()
        var results = run(recognizer, tapFrames(count: 3, duration: 0.08, startTime: 50))
        // Second tap only 100 ms later: inside the re-arm window.
        results += run(recognizer, tapFrames(count: 3, duration: 0.08, startTime: 50.18))
        XCTAssertEqual(results, [.middleClick], "bouncy release must not double-click")
    }

    func testTwoDeliberateTapsProduceTwoClicks() {
        let recognizer = recognizer()
        var results = run(recognizer, tapFrames(count: 3, duration: 0.08, startTime: 50))
        results += run(recognizer, tapFrames(count: 3, duration: 0.08, startTime: 51.0))
        XCTAssertEqual(results, [.middleClick, .middleClick])
    }

    // MARK: - Devices

    func testTapsOnSeparateDevicesAreTrackedSeparately() {
        let recognizer = recognizer()
        // One finger on each of two devices must not add up to a three-finger tap.
        var results: [TapRecognition] = []
        for time in stride(from: 50.0, through: 50.1, by: 0.02) {
            results += recognizer.process(
                frame([touch(id: 1, x: 0.4, y: 0.5, phase: time == 50.0 ? .began : .stationary, at: time)],
                      at: time, device: testDevice),
                sliderGestureActive: false)
            results += recognizer.process(
                frame([touch(id: 1, x: 0.6, y: 0.5, phase: time == 50.0 ? .began : .stationary, at: time)],
                      at: time, device: otherDevice),
                sliderGestureActive: false)
        }
        XCTAssertTrue(results.isEmpty)
    }

    func testResetClearsPendingState() {
        let recognizer = recognizer()
        var frames = tapFrames(count: 3, duration: 0.10)
        let final = frames.removeLast()
        _ = run(recognizer, frames)
        recognizer.reset()
        // The lift now belongs to no gesture.
        XCTAssertTrue(recognizer.process(final, sliderGestureActive: false).isEmpty)
    }
}
