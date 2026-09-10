//
//  EdgeGestureEngineTests.swift
//  GlisseTests
//
//  The gesture test matrix from the spec (§52). These are the most important
//  tests in the project: the stated quality metric is "activates exactly when
//  intended and never when unintended", and everything here is a case where a
//  naive implementation gets it wrong.
//

import XCTest
@testable import GlisseKit

final class EdgeGestureEngineTests: XCTestCase {

    private func engine(_ configuration: GestureConfiguration = testConfiguration())
    -> EdgeGestureEngine {
        EdgeGestureEngine(configuration: configuration)
    }

    // MARK: - Normal behaviour

    func testLeftEdgeUpwardIncreasesBrightness() {
        let output = engine().run(slideFrames(x: 0.02, from: 0.4, to: 0.8))

        XCTAssertEqual(output.beganCount, 1)
        XCTAssertEqual(output.endedCount, 1)
        XCTAssertTrue(output.volumeDeltas.isEmpty, "left edge must not touch volume")
        XCTAssertGreaterThan(output.totalBrightnessDelta, 0, "sliding up must increase")
    }

    func testLeftEdgeDownwardDecreasesBrightness() {
        let output = engine().run(slideFrames(x: 0.02, from: 0.8, to: 0.4))
        XCTAssertEqual(output.beganCount, 1)
        XCTAssertLessThan(output.totalBrightnessDelta, 0)
    }

    func testRightEdgeUpwardIncreasesVolume() {
        let output = engine().run(slideFrames(x: 0.98, from: 0.3, to: 0.7))
        XCTAssertEqual(output.beganCount, 1)
        XCTAssertTrue(output.brightnessDeltas.isEmpty, "right edge must not touch brightness")
        XCTAssertGreaterThan(output.totalVolumeDelta, 0)
    }

    func testRightEdgeDownwardDecreasesVolume() {
        let output = engine().run(slideFrames(x: 0.98, from: 0.7, to: 0.3))
        XCTAssertLessThan(output.totalVolumeDelta, 0)
    }

    /// The magnitude has to be proportional to travel × sensitivity, minus the
    /// activation threshold that is consumed proving intent.
    func testDeltaMagnitudeTracksTravelAndSensitivity() {
        let configuration = testConfiguration(verticalActivationThreshold: 0.01, sensitivity: 2.0)
        let output = engine(configuration).run(
            slideFrames(x: 0.98, from: 0.2, to: 0.7, steps: 50))

        // 0.5 of travel, minus roughly the activation threshold, times 2.0.
        let expected = (0.5 - 0.01) * 2.0
        XCTAssertEqual(output.totalVolumeDelta, expected, accuracy: 0.05)
    }

    // MARK: - Boundaries

    func testExactlyAtLeftThresholdActivates() {
        let output = engine().run(slideFrames(x: 0.08, from: 0.4, to: 0.7))
        XCTAssertEqual(output.beganCount, 1, "x == edgeWidth must be inside the strip")
    }

    func testJustOutsideLeftThresholdDoesNotActivate() {
        let output = engine().run(slideFrames(x: 0.0801, from: 0.4, to: 0.7))
        XCTAssertEqual(output.beganCount, 0)
        XCTAssertTrue(output.actions.isEmpty)
    }

    func testExactlyAtRightThresholdActivates() {
        let output = engine().run(slideFrames(x: 0.92, from: 0.4, to: 0.7))
        XCTAssertEqual(output.beganCount, 1)
    }

    func testJustOutsideRightThresholdDoesNotActivate() {
        let output = engine().run(slideFrames(x: 0.9199, from: 0.4, to: 0.7))
        XCTAssertEqual(output.beganCount, 0)
        XCTAssertTrue(output.actions.isEmpty)
    }

    func testExtremeEdgesActivate() {
        XCTAssertEqual(engine().run(slideFrames(x: 0.0, from: 0.4, to: 0.7)).beganCount, 1)
        XCTAssertEqual(engine().run(slideFrames(x: 1.0, from: 0.4, to: 0.7)).beganCount, 1)
    }

    // MARK: - Wrong entry (the single most important case)

    func testTouchStartingInCentreThenMovingToEdgeNeverActivates() {
        let engine = engine()
        var frames: [TrackpadFrame] = []
        var time = 100.0

        frames.append(frame([touch(x: 0.5, y: 0.5, phase: .began, at: time)], at: time))
        // Travel to the right edge and then slide vertically, which is exactly the
        // shape of a normal pointer movement followed by a scroll.
        for step in 1...30 {
            time += 0.008
            let x = 0.5 + 0.48 * Double(step) / 30.0
            frames.append(frame([touch(x: x, y: 0.5, phase: .moved, at: time)], at: time))
        }
        for step in 1...30 {
            time += 0.008
            let y = 0.5 + 0.4 * Double(step) / 30.0
            frames.append(frame([touch(x: 0.98, y: y, phase: .moved, at: time)], at: time))
        }

        let output = engine.run(frames)
        XCTAssertEqual(output.beganCount, 0, "a gesture must only start inside the edge strip")
        XCTAssertTrue(output.actions.isEmpty)
    }

    func testRejectionIsStickyForTheLifeOfTheContact() {
        let engine = engine()
        var time = 100.0
        // Born ineligible.
        _ = engine.process(frame([touch(x: 0.5, y: 0.5, phase: .began, at: time)], at: time))
        // Sitting on the edge for a long time must not rehabilitate it.
        for _ in 0..<200 {
            time += 0.008
            _ = engine.process(frame([touch(x: 0.99, y: 0.5, phase: .moved, at: time)], at: time))
        }
        time += 0.008
        let output = engine.process(frame([touch(x: 0.99, y: 0.9, phase: .moved, at: time)], at: time))
        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertEqual(output.beganCount, 0)
    }

    // MARK: - Noise

    func testTinyNoisyFramesDoNotChangeValue() {
        let engine = engine()
        var time = 100.0
        var output = EngineOutput.empty

        output = engine.process(frame([touch(x: 0.98, y: 0.5, phase: .began, at: time)], at: time))
        XCTAssertTrue(output.actions.isEmpty)

        // Jitter well under the activation threshold.
        for delta in [0.0004, -0.0006, 0.0003, -0.0002, 0.0005] {
            time += 0.008
            let y = 0.5 + delta
            output = engine.process(frame([touch(x: 0.98, y: y, phase: .moved, at: time)], at: time))
            XCTAssertTrue(output.actions.isEmpty, "sensor noise must not move the value")
            XCTAssertEqual(output.beganCount, 0)
        }
    }

    func testActivationRequiresTheConfiguredVerticalTravel() {
        let configuration = testConfiguration(verticalActivationThreshold: 0.02)
        // 0.015 of travel is real movement but below the threshold.
        let below = engine(configuration).run(
            slideFrames(x: 0.98, from: 0.5, to: 0.515, steps: 15))
        XCTAssertEqual(below.beganCount, 0)

        let above = engine(configuration).run(
            slideFrames(x: 0.98, from: 0.5, to: 0.55, steps: 15))
        XCTAssertEqual(above.beganCount, 1)
    }

    // MARK: - Horizontal motion

    func testStrongSidewaysMotionRejectsTheCandidate() {
        let engine = engine(testConfiguration(horizontalRejectThreshold: 0.04))
        var frames: [TrackpadFrame] = []
        var time = 100.0

        frames.append(frame([touch(x: 0.98, y: 0.5, phase: .began, at: time)], at: time))
        // Sideways first: this is a swipe starting near the edge, not a slide.
        for step in 1...10 {
            time += 0.008
            let x = 0.98 - 0.3 * Double(step) / 10.0
            frames.append(frame([touch(x: x, y: 0.5, phase: .moved, at: time)], at: time))
        }
        // Then vertical, which must no longer count.
        for step in 1...20 {
            time += 0.008
            let y = 0.5 + 0.4 * Double(step) / 20.0
            frames.append(frame([touch(x: 0.68, y: y, phase: .moved, at: time)], at: time))
        }

        let output = engine.run(frames)
        XCTAssertEqual(output.beganCount, 0)
        XCTAssertTrue(output.actions.isEmpty)
    }

    func testSmallHorizontalWobbleDoesNotReject() {
        // Fingers are not rulers; a couple of millimetres of drift is normal.
        let engine = engine(testConfiguration(horizontalRejectThreshold: 0.045))
        var frames: [TrackpadFrame] = []
        var time = 100.0
        frames.append(frame([touch(x: 0.97, y: 0.3, phase: .began, at: time)], at: time))
        for step in 1...20 {
            time += 0.008
            let x = 0.97 + (step % 2 == 0 ? 0.01 : -0.01)
            let y = 0.3 + 0.5 * Double(step) / 20.0
            frames.append(frame([touch(x: x, y: y, phase: .moved, at: time)], at: time))
        }
        let output = engine.run(frames)
        XCTAssertEqual(output.beganCount, 1)
        XCTAssertGreaterThan(output.totalVolumeDelta, 0)
    }

    // MARK: - Bottom quarter

    func testBottomQuarterModeRejectsTouchNearTop() {
        let configuration = testConfiguration(bottomQuarterOnly: true)
        // y = 0.8 is near the physical TOP, outside the bottom quarter.
        let output = engine(configuration).run(slideFrames(x: 0.98, from: 0.8, to: 0.95))
        XCTAssertEqual(output.beganCount, 0)
    }

    func testBottomQuarterModeAcceptsTouchInsideRegion() {
        let configuration = testConfiguration(bottomQuarterOnly: true)
        let output = engine(configuration).run(slideFrames(x: 0.98, from: 0.1, to: 0.6))
        XCTAssertEqual(output.beganCount, 1)
        XCTAssertGreaterThan(output.totalVolumeDelta, 0)
    }

    func testBottomQuarterBoundaryIsInclusive() {
        let configuration = testConfiguration(bottomQuarterOnly: true)
        let atBoundary = engine(configuration).run(slideFrames(x: 0.98, from: 0.25, to: 0.6))
        XCTAssertEqual(atBoundary.beganCount, 1)

        let justOutside = engine(configuration).run(slideFrames(x: 0.98, from: 0.2501, to: 0.6))
        XCTAssertEqual(justOutside.beganCount, 0)
    }

    /// Bottom-quarter only constrains where the gesture *starts*; once running it
    /// must be able to slide the full height.
    func testBottomQuarterGestureMaySlideOutOfTheRegion() {
        let configuration = testConfiguration(bottomQuarterOnly: true)
        let output = engine(configuration).run(slideFrames(x: 0.98, from: 0.05, to: 0.95, steps: 40))
        XCTAssertEqual(output.beganCount, 1)
        XCTAssertGreaterThan(output.totalVolumeDelta, 0.5)
    }

    // MARK: - Swap sides

    func testSwappedMappingReversesEdges() {
        let swapped = testConfiguration(left: .volume, right: .brightness)

        let leftOutput = engine(swapped).run(slideFrames(x: 0.02, from: 0.3, to: 0.7))
        XCTAssertGreaterThan(leftOutput.totalVolumeDelta, 0)
        XCTAssertTrue(leftOutput.brightnessDeltas.isEmpty)

        let rightOutput = engine(swapped).run(slideFrames(x: 0.98, from: 0.3, to: 0.7))
        XCTAssertGreaterThan(rightOutput.totalBrightnessDelta, 0)
        XCTAssertTrue(rightOutput.volumeDeltas.isEmpty)
    }

    func testSwapSidesSettingResolvesThroughAppSettings() {
        var settings = AppSettings.default
        XCTAssertEqual(settings.assignment(for: .left), .brightness)
        XCTAssertEqual(settings.assignment(for: .right), .volume)

        settings.swapSides = true
        XCTAssertEqual(settings.assignment(for: .left), .volume)
        XCTAssertEqual(settings.assignment(for: .right), .brightness)
    }

    func testUnassignedEdgeProducesNothing() {
        let configuration = testConfiguration(left: .none)
        let output = engine(configuration).run(slideFrames(x: 0.02, from: 0.3, to: 0.7))
        XCTAssertEqual(output.beganCount, 0)
        XCTAssertTrue(output.actions.isEmpty)
    }

    // MARK: - Fine control

    func testFineSensitivityProducesSmallerChangeForSameMotion() {
        let normal = engine(testConfiguration(sensitivity: 1.4))
            .run(slideFrames(x: 0.98, from: 0.2, to: 0.8, steps: 30))
        let fine = engine(testConfiguration(sensitivity: 0.4))
            .run(slideFrames(x: 0.98, from: 0.2, to: 0.8, steps: 30))

        XCTAssertGreaterThan(normal.totalVolumeDelta, 0)
        XCTAssertGreaterThan(fine.totalVolumeDelta, 0)
        XCTAssertLessThan(fine.totalVolumeDelta, normal.totalVolumeDelta)
        // Ratio should track the sensitivity ratio.
        XCTAssertEqual(fine.totalVolumeDelta / normal.totalVolumeDelta,
                       0.4 / 1.4, accuracy: 0.06)
    }

    func testActiveSensitivityFollowsFineControlToggle() {
        var settings = AppSettings.default
        settings.sensitivity = 1.4
        settings.fineSensitivity = 0.4
        XCTAssertEqual(settings.activeSensitivity, 1.4)
        settings.fineControl = true
        XCTAssertEqual(settings.activeSensitivity, 0.4)
    }

    // MARK: - Typing suppression

    func testTypingSuppressionBlocksNewGesture() {
        let configuration = testConfiguration(typingSuppressed: true)
        let output = engine(configuration).run(slideFrames(x: 0.98, from: 0.3, to: 0.7))
        XCTAssertEqual(output.beganCount, 0)
        XCTAssertTrue(output.actions.isEmpty)
    }

    func testGestureWorksOnceSuppressionLifts() {
        let output = engine(testConfiguration(typingSuppressed: false))
            .run(slideFrames(x: 0.98, from: 0.3, to: 0.7))
        XCTAssertEqual(output.beganCount, 1)
    }

    /// Suppression must not kill a slide already in progress — that would feel
    /// like the app breaking at random.
    func testSuppressionDoesNotInterruptAnActiveGesture() {
        let engine = engine()
        var time = 100.0

        _ = engine.process(frame([touch(x: 0.98, y: 0.3, phase: .began, at: time)], at: time))
        time += 0.01
        let began = engine.process(frame([touch(x: 0.98, y: 0.35, phase: .moved, at: time)], at: time))
        XCTAssertEqual(began.beganCount, 1)

        // Now a keystroke arrives.
        engine.configuration.typingSuppressed = true
        time += 0.01
        let during = engine.process(frame([touch(x: 0.98, y: 0.45, phase: .moved, at: time)], at: time))
        XCTAssertFalse(during.actions.isEmpty, "an active gesture must keep working")
    }

    // MARK: - Modifier gating

    func testUnsatisfiedModifierBlocksGesture() {
        let configuration = testConfiguration(modifierSatisfied: false)
        let output = engine(configuration).run(slideFrames(x: 0.98, from: 0.3, to: 0.7))
        XCTAssertEqual(output.beganCount, 0)
        XCTAssertTrue(output.actions.isEmpty)
    }

    func testSatisfiedModifierAllowsGesture() {
        let output = engine(testConfiguration(modifierSatisfied: true))
            .run(slideFrames(x: 0.98, from: 0.3, to: 0.7))
        XCTAssertEqual(output.beganCount, 1)
        XCTAssertGreaterThan(output.totalVolumeDelta, 0)
    }

    func testReleasingHoldModifierEndsActiveGesture() {
        let engine = engine()
        var time = 100.0
        _ = engine.process(frame([touch(x: 0.98, y: 0.3, phase: .began, at: time)], at: time))
        time += 0.01
        XCTAssertEqual(engine.process(
            frame([touch(x: 0.98, y: 0.36, phase: .moved, at: time)], at: time)).beganCount, 1)

        engine.configuration.modifierSatisfied = false
        time += 0.01
        let output = engine.process(
            frame([touch(x: 0.98, y: 0.42, phase: .moved, at: time)], at: time))
        XCTAssertEqual(output.endedCount, 1)
        XCTAssertFalse(engine.hasActiveGesture)
    }

    // MARK: - Disabled

    func testDisabledEngineProducesNothing() {
        let output = engine(testConfiguration(isEnabled: false))
            .run(slideFrames(x: 0.98, from: 0.3, to: 0.7))
        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertEqual(output.beganCount, 0)
    }

    // MARK: - Multiple fingers

    func testTwoFingerScrollNearEdgeDoesNotActivate() {
        let engine = engine()
        var frames: [TrackpadFrame] = []
        var time = 100.0

        // Two fingers down, both near the right edge, sliding vertically: this is
        // a scroll and must be left entirely alone.
        frames.append(frame([
            touch(id: 1, x: 0.95, y: 0.3, phase: .began, at: time),
            touch(id: 2, x: 0.99, y: 0.32, phase: .began, at: time),
        ], at: time))

        for step in 1...25 {
            time += 0.008
            let offset = 0.5 * Double(step) / 25.0
            frames.append(frame([
                touch(id: 1, x: 0.95, y: 0.3 + offset, phase: .moved, at: time),
                touch(id: 2, x: 0.99, y: 0.32 + offset, phase: .moved, at: time),
            ], at: time))
        }

        let output = engine.run(frames)
        XCTAssertEqual(output.beganCount, 0)
        XCTAssertTrue(output.actions.isEmpty)
    }

    func testSecondFingerLandingEndsAnActiveGesture() {
        let engine = engine()
        var time = 100.0
        _ = engine.process(frame([touch(id: 1, x: 0.98, y: 0.3, phase: .began, at: time)], at: time))
        time += 0.01
        XCTAssertEqual(engine.process(
            frame([touch(id: 1, x: 0.98, y: 0.36, phase: .moved, at: time)], at: time)).beganCount, 1)

        time += 0.01
        let output = engine.process(frame([
            touch(id: 1, x: 0.98, y: 0.40, phase: .moved, at: time),
            touch(id: 2, x: 0.60, y: 0.40, phase: .began, at: time),
        ], at: time))

        XCTAssertEqual(output.endedCount, 1)
        XCTAssertFalse(engine.hasActiveGesture)
    }

    func testOnlyOneGestureCanBeActivePerDevice() {
        let engine = engine(testConfiguration(maximumSimultaneousTouches: 2))
        var time = 100.0

        _ = engine.process(frame([
            touch(id: 1, x: 0.02, y: 0.3, phase: .began, at: time),
            touch(id: 2, x: 0.98, y: 0.3, phase: .began, at: time),
        ], at: time))

        var total = EngineOutput.empty
        for step in 1...20 {
            time += 0.008
            let offset = 0.4 * Double(step) / 20.0
            let output = engine.process(frame([
                touch(id: 1, x: 0.02, y: 0.3 + offset, phase: .moved, at: time),
                touch(id: 2, x: 0.98, y: 0.3 + offset, phase: .moved, at: time),
            ], at: time))
            total = EngineOutput(actions: total.actions + output.actions,
                                 lifecycle: total.lifecycle + output.lifecycle)
        }

        XCTAssertEqual(total.beganCount, 1, "two edges must not both drive at once")
        let sawBoth = !total.volumeDeltas.isEmpty && !total.brightnessDeltas.isEmpty
        XCTAssertFalse(sawBoth, "only one property may be adjusted at a time")
    }

    // MARK: - Devices are independent

    func testTwoDevicesKeepSeparateSessions() {
        let engine = engine()
        // Built-in trackpad slides on the right edge; a Magic Trackpad contact
        // sits in the middle of its own surface and must not interfere.
        var time = 100.0
        _ = engine.process(frame([touch(id: 1, x: 0.98, y: 0.3, phase: .began, at: time)], at: time))
        _ = engine.process(frame([touch(id: 1, x: 0.50, y: 0.5, phase: .began, at: time)],
                                 at: time, device: otherDevice))

        var total = EngineOutput.empty
        for step in 1...20 {
            time += 0.008
            let offset = 0.4 * Double(step) / 20.0
            let a = engine.process(
                frame([touch(id: 1, x: 0.98, y: 0.3 + offset, phase: .moved, at: time)], at: time))
            let b = engine.process(
                frame([touch(id: 1, x: 0.50, y: 0.5 + offset, phase: .moved, at: time)],
                      at: time, device: otherDevice))
            total = EngineOutput(actions: total.actions + a.actions + b.actions,
                                 lifecycle: total.lifecycle + a.lifecycle + b.lifecycle)
        }

        XCTAssertEqual(total.beganCount, 1)
        XCTAssertGreaterThan(total.totalVolumeDelta, 0)
    }

    // MARK: - Cleanup

    func testLiftingFingerEndsGestureAndClearsState() {
        let engine = engine()
        let output = engine.run(slideFrames(x: 0.98, from: 0.3, to: 0.7))
        XCTAssertEqual(output.endedCount, 1)
        XCTAssertFalse(engine.hasActiveGesture)

        // A fresh frame with nothing in it must produce nothing at all.
        let idle = engine.process(frame([], at: 200))
        XCTAssertTrue(idle.isEmpty)
    }

    func testVanishedTouchWithoutEndPhaseStillEndsGesture() {
        // MultitouchSupport does not guarantee a final frame per contact.
        let engine = engine()
        var time = 100.0
        _ = engine.process(frame([touch(x: 0.98, y: 0.3, phase: .began, at: time)], at: time))
        time += 0.01
        XCTAssertEqual(engine.process(
            frame([touch(x: 0.98, y: 0.36, phase: .moved, at: time)], at: time)).beganCount, 1)

        time += 0.01
        let output = engine.process(frame([], at: time))
        XCTAssertEqual(output.endedCount, 1)
        XCTAssertFalse(engine.hasActiveGesture)
    }

    func testCancelledTouchEndsGesture() {
        let engine = engine()
        var time = 100.0
        _ = engine.process(frame([touch(x: 0.98, y: 0.3, phase: .began, at: time)], at: time))
        time += 0.01
        _ = engine.process(frame([touch(x: 0.98, y: 0.36, phase: .moved, at: time)], at: time))
        time += 0.01
        let output = engine.process(
            frame([touch(x: 0.98, y: 0.36, phase: .cancelled, at: time)], at: time))
        XCTAssertEqual(output.endedCount, 1)
        XCTAssertFalse(engine.hasActiveGesture)
    }

    func testCancelAllReportsInFlightGestures() {
        let engine = engine()
        var time = 100.0
        _ = engine.process(frame([touch(x: 0.98, y: 0.3, phase: .began, at: time)], at: time))
        time += 0.01
        _ = engine.process(frame([touch(x: 0.98, y: 0.36, phase: .moved, at: time)], at: time))

        let events = engine.cancelAll()
        XCTAssertEqual(events.count, 1)
        XCTAssertFalse(engine.hasActiveGesture)
    }

    func testResetClearsEverything() {
        let engine = engine()
        _ = engine.run(slideFrames(x: 0.98, from: 0.3, to: 0.7, lift: false))
        engine.reset()
        XCTAssertFalse(engine.hasActiveGesture)
    }

    // MARK: - Candidate timeout

    func testFingerRestingOnEdgeForeverIsAbandoned() {
        let engine = engine()
        var time = 100.0
        _ = engine.process(frame([touch(x: 0.98, y: 0.5, phase: .began, at: time)], at: time))

        // Rest for well over the candidate timeout with only noise.
        for _ in 0..<250 {
            time += 0.008
            _ = engine.process(
                frame([touch(x: 0.98, y: 0.5001, phase: .stationary, at: time)], at: time))
        }

        // Now move properly: it must be too late.
        var output = EngineOutput.empty
        for step in 1...20 {
            time += 0.008
            let y = 0.5 + 0.4 * Double(step) / 20.0
            let step = engine.process(frame([touch(x: 0.98, y: y, phase: .moved, at: time)], at: time))
            output = EngineOutput(actions: output.actions + step.actions,
                                  lifecycle: output.lifecycle + step.lifecycle)
        }
        XCTAssertEqual(output.beganCount, 0)
        XCTAssertTrue(output.actions.isEmpty)
    }

    // MARK: - Inverted axis escape hatch

    func testInvertVerticalFlipsDirection() {
        let normal = engine(testConfiguration(invertVertical: false))
            .run(slideFrames(x: 0.98, from: 0.3, to: 0.7))
        let inverted = engine(testConfiguration(invertVertical: true))
            .run(slideFrames(x: 0.98, from: 0.3, to: 0.7))

        XCTAssertGreaterThan(normal.totalVolumeDelta, 0)
        XCTAssertLessThan(inverted.totalVolumeDelta, 0)
        XCTAssertEqual(normal.totalVolumeDelta, -inverted.totalVolumeDelta, accuracy: 1e-9)
    }

    // MARK: - Relative, not absolute

    /// Two slides of identical length starting at different heights must produce
    /// the same change. This is the property that makes the control feel right.
    func testEqualTravelFromDifferentStartsProducesEqualChange() {
        let low = engine().run(slideFrames(x: 0.98, from: 0.10, to: 0.40, steps: 30))
        let high = engine().run(slideFrames(x: 0.98, from: 0.60, to: 0.90, steps: 30))
        XCTAssertEqual(low.totalVolumeDelta, high.totalVolumeDelta, accuracy: 1e-9)
    }

    func testPerFrameDeltaIsBounded() {
        // A dropped frame produces a huge jump; it must be clamped so the volume
        // cannot slam from one end to the other.
        let engine = engine(testConfiguration(sensitivity: 4.0))
        var time = 100.0
        _ = engine.process(frame([touch(x: 0.98, y: 0.02, phase: .began, at: time)], at: time))
        time += 0.01
        _ = engine.process(frame([touch(x: 0.98, y: 0.05, phase: .moved, at: time)], at: time))
        time += 0.5
        let output = engine.process(frame([touch(x: 0.98, y: 0.99, phase: .moved, at: time)], at: time))

        for delta in output.volumeDeltas {
            XCTAssertLessThanOrEqual(abs(delta), 0.25 + 1e-9)
        }
    }
}
