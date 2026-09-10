//
//  GestureSessionTests.swift
//  GlisseTests
//
//  Session bookkeeping, plus the typing-suppression service (which is pure
//  enough to test directly by injecting timestamps).
//

import XCTest
@testable import GlisseKit

final class GestureSessionTests: XCTestCase {

    private func makeSession(x: Double = 0.98,
                             y: Double = 0.5,
                             edge: TrackpadEdge = .right,
                             assignment: EdgeAssignment = .volume) -> GestureSession {
        GestureSession(touchID: 7, edge: edge, assignment: assignment,
                       x: x, y: y, timestamp: 100)
    }

    func testNewSessionStartsAsCandidate() {
        let session = makeSession()
        XCTAssertEqual(session.state, .candidate)
        XCTAssertEqual(session.startX, 0.98)
        XCTAssertEqual(session.startY, 0.5)
        XCTAssertEqual(session.currentY, 0.5)
        XCTAssertEqual(session.lastY, 0.5)
        XCTAssertEqual(session.residual, 0)
    }

    func testAdvanceTracksPositionAndPeakHorizontalTravel() {
        var session = makeSession()
        session.advance(x: 0.95, y: 0.6, timestamp: 100.1)
        XCTAssertEqual(session.currentX, 0.95)
        XCTAssertEqual(session.currentY, 0.6)
        XCTAssertEqual(session.peakHorizontalTravel, 0.03, accuracy: 1e-12)

        // Peak is a high-water mark: coming back does not lower it.
        session.advance(x: 0.98, y: 0.7, timestamp: 100.2)
        XCTAssertEqual(session.peakHorizontalTravel, 0.03, accuracy: 1e-12)

        session.advance(x: 0.80, y: 0.7, timestamp: 100.3)
        XCTAssertEqual(session.peakHorizontalTravel, 0.18, accuracy: 1e-12)
    }

    func testVerticalTravelIsMeasuredFromStart() {
        var session = makeSession(y: 0.4)
        session.advance(x: 0.98, y: 0.75, timestamp: 100.2)
        XCTAssertEqual(session.verticalTravel, 0.35, accuracy: 1e-12)
    }

    func testConsumingDeltaAdvancesTheBaseline() {
        var session = makeSession(y: 0.4)
        session.advance(x: 0.98, y: 0.5, timestamp: 100.1)
        XCTAssertEqual(session.consumeVerticalDelta(), 0.1, accuracy: 1e-12)
        // Consuming twice with no movement must yield zero, not repeat the delta.
        XCTAssertEqual(session.consumeVerticalDelta(), 0, accuracy: 1e-12)

        session.advance(x: 0.98, y: 0.55, timestamp: 100.2)
        XCTAssertEqual(session.consumeVerticalDelta(), 0.05, accuracy: 1e-12)
    }

    /// Activation must not emit the movement that proved intent, or the value
    /// would jump by the whole activation threshold at the start of every slide.
    func testActivationRebasesSoThereIsNoJump() {
        var session = makeSession(y: 0.4)
        session.advance(x: 0.98, y: 0.42, timestamp: 100.1)
        session.activate()
        XCTAssertEqual(session.state, .active)
        XCTAssertEqual(session.consumeVerticalDelta(), 0, accuracy: 1e-12)
    }

    func testResidualAccumulatesAndDrains() {
        var session = makeSession()
        session.addResidual(0.001)
        session.addResidual(0.002)
        XCTAssertEqual(session.residual, 0.003, accuracy: 1e-12)
        XCTAssertEqual(session.takeResidual(), 0.003, accuracy: 1e-12)
        XCTAssertEqual(session.residual, 0)
    }

    func testResidualIgnoresNonFiniteInput() {
        var session = makeSession()
        session.addResidual(.nan)
        XCTAssertTrue(session.residual.isFinite)
    }

    func testDurationUsesLatestTimestamp() {
        var session = makeSession()
        session.advance(x: 0.98, y: 0.6, timestamp: 100.35)
        XCTAssertEqual(session.duration, 0.35, accuracy: 1e-12)
    }

    func testTouchCoordinatesAreClampedAtConstruction() {
        let low = TrackpadTouch(id: 1, x: -2, y: -2, phase: .began, timestamp: 0)
        XCTAssertEqual(low.x, 0)
        XCTAssertEqual(low.y, 0)
        let high = TrackpadTouch(id: 1, x: 3, y: 3, phase: .began, timestamp: 0)
        XCTAssertEqual(high.x, 1)
        XCTAssertEqual(high.y, 1)
    }

    func testPhaseActivityClassification() {
        XCTAssertTrue(TouchPhase.began.isActive)
        XCTAssertTrue(TouchPhase.moved.isActive)
        XCTAssertTrue(TouchPhase.stationary.isActive)
        XCTAssertFalse(TouchPhase.ended.isActive)
        XCTAssertFalse(TouchPhase.cancelled.isActive)
    }

    func testFrameActiveTouchesFiltersLifted() {
        let f = frame([
            touch(id: 1, x: 0.1, y: 0.1, phase: .moved, at: 1),
            touch(id: 2, x: 0.2, y: 0.2, phase: .ended, at: 1),
            touch(id: 3, x: 0.3, y: 0.3, phase: .cancelled, at: 1),
        ], at: 1)
        XCTAssertEqual(f.activeTouches.map(\.id), [1])
    }
}

final class TypingSuppressionTests: XCTestCase {

    func testSuppressedImmediatelyAfterKeystroke() {
        let service = TypingSuppressionService(suppressionDuration: 0.5)
        service.noteKeyDown(at: 1_000)
        XCTAssertTrue(service.isSuppressed(now: 1_000))
        XCTAssertTrue(service.isSuppressed(now: 1_000.2))
        XCTAssertTrue(service.isSuppressed(now: 1_000.499))
    }

    func testNotSuppressedOnceTheWindowElapses() {
        let service = TypingSuppressionService(suppressionDuration: 0.5)
        service.noteKeyDown(at: 1_000)
        XCTAssertFalse(service.isSuppressed(now: 1_000.5))
        XCTAssertFalse(service.isSuppressed(now: 1_001))
    }

    func testEachKeystrokeExtendsTheWindow() {
        let service = TypingSuppressionService(suppressionDuration: 0.5)
        service.noteKeyDown(at: 1_000)
        service.noteKeyDown(at: 1_000.4)
        XCTAssertTrue(service.isSuppressed(now: 1_000.8))
        XCTAssertFalse(service.isSuppressed(now: 1_000.91))
    }

    func testDisabledServiceNeverSuppresses() {
        let service = TypingSuppressionService(suppressionDuration: 0.5, isEnabled: false)
        service.noteKeyDown(at: 1_000)
        XCTAssertFalse(service.isSuppressed(now: 1_000))
    }

    func testZeroDurationNeverSuppresses() {
        let service = TypingSuppressionService(suppressionDuration: 0)
        service.noteKeyDown(at: 1_000)
        XCTAssertFalse(service.isSuppressed(now: 1_000))
    }

    func testNothingIsSuppressedBeforeAnyKeystroke() {
        let service = TypingSuppressionService(suppressionDuration: 0.5)
        XCTAssertFalse(service.isSuppressed(now: 0))
        XCTAssertFalse(service.isSuppressed(now: 1_000_000))
    }

    /// The monotonic clock pauses across sleep, so a pre-sleep keystroke could
    /// otherwise appear to have just happened.
    func testResetClearsTheWindow() {
        let service = TypingSuppressionService(suppressionDuration: 0.5)
        service.noteKeyDown(at: 1_000)
        service.reset()
        XCTAssertFalse(service.isSuppressed(now: 1_000))
    }

    func testRemainingCountsDown() {
        let service = TypingSuppressionService(suppressionDuration: 0.5)
        service.noteKeyDown(at: 1_000)
        XCTAssertEqual(service.remaining(now: 1_000), 0.5, accuracy: 1e-9)
        XCTAssertEqual(service.remaining(now: 1_000.25), 0.25, accuracy: 1e-9)
        XCTAssertEqual(service.remaining(now: 1_001), 0, accuracy: 1e-9)
    }

    func testDurationChangesTakeEffectImmediately() {
        let service = TypingSuppressionService(suppressionDuration: 0.5)
        service.noteKeyDown(at: 1_000)
        XCTAssertTrue(service.isSuppressed(now: 1_000.3))
        service.suppressionDuration = 0.2
        XCTAssertFalse(service.isSuppressed(now: 1_000.3))
    }

    func testNegativeDurationIsClampedToZero() {
        let service = TypingSuppressionService(suppressionDuration: 0.5)
        service.suppressionDuration = -5
        XCTAssertEqual(service.suppressionDuration, 0)
    }
}

final class ThrottlerTests: XCTestCase {

    func testFirstCallIsAllowed() {
        var throttle = Throttler(interval: 0.1)
        XCTAssertTrue(throttle.allow(now: 0))
    }

    func testSubsequentCallsWithinIntervalAreBlocked() {
        var throttle = Throttler(interval: 0.1)
        XCTAssertTrue(throttle.allow(now: 100))
        XCTAssertFalse(throttle.allow(now: 100.05))
        XCTAssertFalse(throttle.allow(now: 100.099))
        // Deliberately past the boundary rather than exactly on it: 100.1 - 100
        // is 0.0999999999999943 in binary floating point.
        XCTAssertTrue(throttle.allow(now: 100.11))
    }

    func testResetRearmsImmediately() {
        var throttle = Throttler(interval: 0.1)
        XCTAssertTrue(throttle.allow(now: 100))
        throttle.reset()
        XCTAssertTrue(throttle.allow(now: 100))
    }
}
