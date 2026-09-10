//
//  MappingTests.swift
//  GlisseTests
//
//  Value arithmetic: relative adjustment, mute coupling, DDC scaling and HUD
//  quantisation. These are the calculations that decide what actually gets
//  written to hardware, so they are tested away from the hardware.
//

import GlissePrivate
import XCTest
@testable import GlisseKit

final class VolumeMappingTests: XCTestCase {

    func testRelativeAdjustmentAddsDelta() {
        let result = ValueAdjustment.apply(current: 0.4, delta: 0.15)
        XCTAssertEqual(result.value, 0.55, accuracy: 1e-12)
        XCTAssertFalse(result.hitLimit)
    }

    func testNegativeDeltaSubtracts() {
        XCTAssertEqual(ValueAdjustment.apply(current: 0.4, delta: -0.15).value,
                       0.25, accuracy: 1e-12)
    }

    func testClampsAtCeiling() {
        let result = ValueAdjustment.apply(current: 0.95, delta: 0.4)
        XCTAssertEqual(result.value, 1.0)
        XCTAssertFalse(result.hitLimit, "a delta that still moved the value is not a limit hit")
    }

    func testClampsAtFloor() {
        XCTAssertEqual(ValueAdjustment.apply(current: 0.05, delta: -0.4).value, 0.0)
    }

    func testDetectsLimitOnlyWhenNothingChanged() {
        XCTAssertTrue(ValueAdjustment.apply(current: 1.0, delta: 0.1).hitLimit)
        XCTAssertTrue(ValueAdjustment.apply(current: 0.0, delta: -0.1).hitLimit)
        XCTAssertFalse(ValueAdjustment.apply(current: 1.0, delta: -0.1).hitLimit)
    }

    func testNonFiniteDeltaIsIgnored() {
        XCTAssertEqual(ValueAdjustment.apply(current: 0.5, delta: .nan).value, 0.5)
        XCTAssertEqual(ValueAdjustment.apply(current: 0.5, delta: .infinity).value, 0.5)
    }

    func testOutOfRangeCurrentIsSanitised() {
        XCTAssertEqual(ValueAdjustment.apply(current: 5.0, delta: 0).value, 1.0)
        XCTAssertEqual(ValueAdjustment.apply(current: -3.0, delta: 0).value, 0.0)
        XCTAssertEqual(ValueAdjustment.apply(current: .nan, delta: 0.1).value, 0.1, accuracy: 1e-12)
    }

    /// Relative control: the same accumulated travel must land on the same place
    /// regardless of how many frames it arrived in.
    func testAccumulationIsPathIndependent() {
        var oneShot = ValueAdjustment.apply(current: 0.2, delta: 0.3).value

        var incremental = 0.2
        for _ in 0..<30 {
            incremental = ValueAdjustment.apply(current: incremental, delta: 0.01).value
        }
        XCTAssertEqual(oneShot, incremental, accuracy: 1e-9)
        oneShot = 0
    }

    // MARK: Mute coupling

    func testSlidingToSilenceMutes() {
        XCTAssertEqual(MuteCoupling.decide(targetVolume: 0,
                                          currentlyMuted: false,
                                          startedMuted: false), .mute)
    }

    func testAlreadyMutedAtSilenceDoesNothing() {
        XCTAssertEqual(MuteCoupling.decide(targetVolume: 0,
                                          currentlyMuted: true,
                                          startedMuted: false), .none)
    }

    func testSlidingUpFromMuteUnmutes() {
        XCTAssertEqual(MuteCoupling.decide(targetVolume: 0.3,
                                          currentlyMuted: true,
                                          startedMuted: true), .unmute)
    }

    /// The state that must never be left behind.
    func testVolumeAboveZeroNeverStaysMuted() {
        for volume in [0.001, 0.05, 0.5, 1.0] {
            XCTAssertEqual(MuteCoupling.decide(targetVolume: volume,
                                               currentlyMuted: true,
                                               startedMuted: false),
                           .unmute,
                           "volume \(volume) with mute on must unmute")
        }
    }

    func testUnmutedMidRangeIsLeftAlone() {
        XCTAssertEqual(MuteCoupling.decide(targetVolume: 0.5,
                                          currentlyMuted: false,
                                          startedMuted: false), .none)
    }

    func testSilenceThresholdIsInclusive() {
        XCTAssertEqual(MuteCoupling.decide(targetVolume: MuteCoupling.silenceThreshold,
                                          currentlyMuted: false,
                                          startedMuted: false), .mute)
    }
}

final class BrightnessMappingTests: XCTestCase {

    // MARK: DDC scaling

    func testNativeScalingUsesReportedMaximum() {
        XCTAssertEqual(DDCScaling.native(normalized: 0.5, maximum: 100), 50)
        XCTAssertEqual(DDCScaling.native(normalized: 0.5, maximum: 255), 128)
        XCTAssertEqual(DDCScaling.native(normalized: 0.5, maximum: 20), 10)
    }

    /// The classic DDC bug is assuming a maximum of 100.
    func testNativeScalingNeverExceedsMaximum() {
        for maximum in [UInt16(20), 100, 255, 1_000] {
            XCTAssertEqual(DDCScaling.native(normalized: 1.0, maximum: maximum), maximum)
            XCTAssertEqual(DDCScaling.native(normalized: 2.0, maximum: maximum), maximum)
            XCTAssertEqual(DDCScaling.native(normalized: 0.0, maximum: maximum), 0)
            XCTAssertEqual(DDCScaling.native(normalized: -1.0, maximum: maximum), 0)
        }
    }

    func testZeroMaximumIsSafe() {
        XCTAssertEqual(DDCScaling.native(normalized: 0.5, maximum: 0), 0)
        XCTAssertEqual(DDCScaling.normalized(native: 50, maximum: 0), 0)
    }

    func testNormalisationIsInverseOfScaling() {
        for maximum in [UInt16(20), 100, 255] {
            for percent in stride(from: 0.0, through: 1.0, by: 0.05) {
                let native = DDCScaling.native(normalized: percent, maximum: maximum)
                let back = DDCScaling.normalized(native: native, maximum: maximum)
                XCTAssertEqual(back, percent, accuracy: 1.0 / Double(maximum))
            }
        }
    }

    func testNativeValueAboveMaximumClampsWhenReading() {
        XCTAssertEqual(DDCScaling.normalized(native: 500, maximum: 100), 1.0)
    }

    func testNonFiniteNormalizedIsSafe() {
        // NaN means "no information": go to the floor.
        XCTAssertEqual(DDCScaling.native(normalized: .nan, maximum: 100), 0)
        // Infinity means "past the top": clamp to the ceiling, never wrap.
        XCTAssertEqual(DDCScaling.native(normalized: .infinity, maximum: 100), 100)
        XCTAssertEqual(DDCScaling.native(normalized: -.infinity, maximum: 100), 0)
    }

    // MARK: HUD quantisation

    func testChicletsRoundHalfUp() {
        XCTAssertEqual(HUDScaling.filledChiclets(level: 0.0, total: 16), 0)
        XCTAssertEqual(HUDScaling.filledChiclets(level: 1.0, total: 16), 16)
        XCTAssertEqual(HUDScaling.filledChiclets(level: 0.5, total: 16), 8)
        // A nudge off zero should light the first segment.
        XCTAssertEqual(HUDScaling.filledChiclets(level: 0.04, total: 16), 1)
    }

    func testChicletsNeverExceedTotal() {
        XCTAssertEqual(HUDScaling.filledChiclets(level: 5.0, total: 16), 16)
        XCTAssertEqual(HUDScaling.filledChiclets(level: -5.0, total: 16), 0)
        XCTAssertEqual(HUDScaling.filledChiclets(level: 0.5, total: 0), 0)
    }

    // MARK: Quantisation helper used by haptics

    func testQuantizationProducesStableDetents() {
        XCTAssertEqual((0.0).quantized(steps: 50), 0)
        XCTAssertEqual((1.0).quantized(steps: 50), 50)
        XCTAssertEqual((0.5).quantized(steps: 50), 25)
        XCTAssertEqual(Double.nan.quantized(steps: 50), 0)
        XCTAssertEqual((0.5).quantized(steps: 0), 0)
    }

    func testHapticDetentsChangeOnceEveryTwoPercent() {
        // 50 detents over 0...1 means a tick roughly every 2%.
        var changes = 0
        var previous = (0.0).quantized(steps: 50)
        for step in 1...100 {
            let current = (Double(step) / 100.0).quantized(steps: 50)
            if current != previous { changes += 1 }
            previous = current
        }
        XCTAssertEqual(changes, 50)
    }
}

final class HapticStrengthTests: XCTestCase {

    /// macOS offers no intensity control, so strength has to map onto distinct
    /// patterns. If two strengths shared a pattern the setting would be a lie.
    func testEachStrengthUsesADistinctActuationPattern() {
        let patterns = HapticStrength.allCases.map(\.actuationPattern.rawValue)
        XCTAssertEqual(Set(patterns).count, HapticStrength.allCases.count)
    }

    func testEachStrengthUsesADistinctAppKitPattern() {
        let patterns = HapticStrength.allCases.map(\.appKitPattern)
        XCTAssertEqual(Set(patterns).count, HapticStrength.allCases.count)
    }

    /// Actuation ids ascend with firmness, so the ordering is inspectable rather
    /// than only felt.
    func testActuationPatternsAscendWithStrength() {
        XCTAssertLessThan(HapticStrength.light.actuationPattern.rawValue,
                          HapticStrength.medium.actuationPattern.rawValue)
        XCTAssertLessThan(HapticStrength.medium.actuationPattern.rawValue,
                          HapticStrength.strong.actuationPattern.rawValue)
    }

    /// Every mapped pattern must be one the driver actually accepts.
    func testMappedPatternsAreAllValid() {
        let valid = Set(GLHapticActuator.allPatterns.map { $0.int32Value })
        for strength in HapticStrength.allCases {
            XCTAssertTrue(valid.contains(strength.actuationPattern.rawValue),
                          "\(strength.displayName) maps to an unsupported actuation id")
        }
    }

    func testAppKitFallbackOrderingIsLightToStrong() {
        XCTAssertEqual(HapticStrength.light.appKitPattern, .levelChange)
        XCTAssertEqual(HapticStrength.medium.appKitPattern, .generic)
        XCTAssertEqual(HapticStrength.strong.appKitPattern, .alignment)
    }

    /// A firmer pulse takes longer to settle, so stronger must mean sparser.
    /// Otherwise "strong" stops feeling like detents and becomes a buzz.
    func testStrongerMeansFewerDetentsAndMoreSpacing() {
        XCTAssertGreaterThan(HapticStrength.light.stepsPerUnit,
                             HapticStrength.medium.stepsPerUnit)
        XCTAssertGreaterThan(HapticStrength.medium.stepsPerUnit,
                             HapticStrength.strong.stepsPerUnit)

        XCTAssertLessThan(HapticStrength.light.minimumInterval,
                          HapticStrength.medium.minimumInterval)
        XCTAssertLessThan(HapticStrength.medium.minimumInterval,
                          HapticStrength.strong.minimumInterval)
    }

    /// Detent spacing must stay coarse enough that a full-range sweep cannot
    /// out-run the throttle and silently drop ticks.
    func testDetentDensityIsAchievableWithinTheThrottle() {
        for strength in HapticStrength.allCases {
            // A brisk full-range sweep takes roughly 400 ms.
            let sweep = 0.4
            let maximumTicks = sweep / strength.minimumInterval
            XCTAssertLessThanOrEqual(Double(strength.stepsPerUnit), maximumTicks * 4,
                                     "\(strength.displayName) would drop most of its ticks")
        }
    }

    func testDefaultIsMedium() {
        XCTAssertEqual(AppSettings.default.hapticStrength, .medium)
        XCTAssertTrue(AppSettings.default.hapticsEnabled)
    }

    func testStrengthRoundTripsThroughTheStore() {
        let suite = "xyz.glisse.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        for strength in HapticStrength.allCases {
            SettingsStore(defaults: defaults).update { $0.hapticStrength = strength }
            XCTAssertEqual(SettingsStore(defaults: defaults).snapshot.hapticStrength, strength)
        }
    }

    /// Changing strength mid-gesture rebases the detent index, so the density
    /// change cannot fire a spurious tick.
    func testChangingStrengthDoesNotThrowOrStick() {
        let service = HapticFeedbackService(strength: .light)
        service.beginGesture(atValue: 0.5)
        service.valueChanged(to: 0.55)
        service.strength = .strong
        XCTAssertEqual(service.strength, .strong)
        service.valueChanged(to: 0.60)
        service.endGesture()
        service.strength = .medium
        XCTAssertEqual(service.strength, .medium)
    }

    func testDisabledServiceStaysSilentButTracksValue() {
        let service = HapticFeedbackService(strength: .medium)
        service.isEnabled = false
        service.beginGesture(atValue: 0.0)
        for step in 1...20 {
            service.valueChanged(to: Double(step) / 20.0)
        }
        service.hitLimit()
        service.endGesture()
        XCTAssertFalse(service.isEnabled)
    }
}

final class MediaKeyStepperTests: XCTestCase {

    private func stepper(step: Double = 1.0 / 64.0, cap: Int = 6) -> MediaKeyStepper {
        MediaKeyStepper(step: step, maximumStepsPerCall: cap)
    }

    func testExactlyOneStepEmitsOnePress() {
        var s = stepper()
        let outcome = s.consume(delta: 1.0 / 64.0)
        XCTAssertEqual(outcome, .init(steps: 1, increasing: true))
    }

    func testSubStepMovementEmitsNothingButIsBanked() {
        var s = stepper()
        XCTAssertEqual(s.consume(delta: 0.005).steps, 0)
        XCTAssertEqual(s.consume(delta: 0.005).steps, 0)
        XCTAssertGreaterThan(s.residual, 0)
    }

    /// The property that makes a slow slide work at all: many tiny deltas must
    /// eventually add up to a press rather than being discarded.
    func testManyTinyDeltasAccumulateIntoPresses() {
        var s = stepper()
        var total = 0
        for _ in 0..<64 {
            total += s.consume(delta: 1.0 / 256.0).steps
        }
        // 64 * (1/256) = 0.25 of the range = 16 steps of 1/64.
        XCTAssertEqual(total, 16)
    }

    func testNegativeDeltaStepsDown() {
        var s = stepper()
        let outcome = s.consume(delta: -1.0 / 64.0)
        XCTAssertEqual(outcome, .init(steps: 1, increasing: false))
    }

    func testLargeDeltaIsCapped() {
        var s = stepper(cap: 6)
        // Half the range would be 32 presses.
        XCTAssertEqual(s.consume(delta: 0.5).steps, 6)
    }

    /// Overflow must be dropped, not banked, or the value keeps moving after the
    /// finger has stopped.
    func testCappedOverflowIsNotBanked() {
        var s = stepper(cap: 6)
        _ = s.consume(delta: 0.9)
        XCTAssertEqual(s.residual, 0)
        XCTAssertEqual(s.consume(delta: 0).steps, 0)
    }

    /// A reversal must respond immediately rather than first burning through
    /// credit banked in the other direction.
    func testReversalDiscardsOppositeResidual() {
        var s = stepper()
        XCTAssertEqual(s.consume(delta: 0.014).steps, 0)   // banked, just under 1/64
        let back = s.consume(delta: -1.0 / 64.0)
        XCTAssertEqual(back, .init(steps: 1, increasing: false))
    }

    func testNonFiniteDeltaIsIgnored() {
        var s = stepper()
        XCTAssertEqual(s.consume(delta: .nan).steps, 0)
        XCTAssertEqual(s.consume(delta: .infinity).steps, 0)
        XCTAssertTrue(s.residual.isFinite)
    }

    func testResetClearsBankedMovement() {
        var s = stepper()
        _ = s.consume(delta: 0.014)
        s.reset()
        XCTAssertEqual(s.residual, 0)
        XCTAssertEqual(s.consume(delta: 0.014).steps, 0)
    }

    func testZeroStepSizeFallsBackToASaneValue() {
        var s = stepper(step: 0)
        XCTAssertEqual(s.consume(delta: 1.0 / 64.0).steps, 1)
    }

    /// A full-range sweep delivered frame by frame should produce close to 64
    /// presses: the resolution the fine media key gives.
    func testFullSweepProducesRoughlySixtyFourPresses() {
        var s = stepper(cap: 6)
        var total = 0
        // 125 frames, as one second of trackpad data would deliver.
        for _ in 0..<125 {
            total += s.consume(delta: 1.0 / 125.0).steps
        }
        XCTAssertEqual(total, 64, accuracy: 2)
    }
}
