//
//  SettingsStoreTests.swift
//  GlisseTests
//

import XCTest
@testable import GlisseKit

final class SettingsStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "xyz.glisse.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: Defaults

    func testShippedDefaultsMatchSpecification() {
        let settings = AppSettings.default
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.leftEdgeAction, .brightness)
        XCTAssertEqual(settings.rightEdgeAction, .volume)
        XCTAssertFalse(settings.fineControl)
        XCTAssertFalse(settings.swapSides)
        XCTAssertFalse(settings.bottomQuarterOnly)
        XCTAssertFalse(settings.freezeCursor)
        XCTAssertTrue(settings.smartTypingDetection)
        XCTAssertTrue(settings.hapticsEnabled)
        XCTAssertFalse(settings.threeFingerMiddleClick)
        XCTAssertEqual(settings.modifierMode, .none)
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertEqual(settings.edgeWidth, 0.08, accuracy: 1e-12)
        XCTAssertEqual(settings.typingSuppression, 0.7, accuracy: 1e-12)
    }

    // MARK: Persistence

    func testChangesPersistAcrossStoreInstances() {
        let store = SettingsStore(defaults: defaults)
        store.update {
            $0.fineControl = true
            $0.edgeWidth = 0.12
            $0.modifierMode = .hold(.option)
            $0.pinnedDisplayID = 42
        }

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.snapshot.fineControl)
        XCTAssertEqual(reloaded.snapshot.edgeWidth, 0.12, accuracy: 1e-12)
        XCTAssertEqual(reloaded.snapshot.modifierMode, .hold(.option))
        XCTAssertEqual(reloaded.snapshot.pinnedDisplayID, 42)
    }

    func testModifierModeRoundTripsForEveryCase() {
        var modes: [ModifierMode] = [.none]
        for key in ModifierKeyChoice.allCases {
            modes.append(.hold(key))
            modes.append(.toggle(key))
        }
        for mode in modes {
            let store = SettingsStore(defaults: defaults)
            store.update { $0.modifierMode = mode }
            let reloaded = SettingsStore(defaults: defaults)
            XCTAssertEqual(reloaded.snapshot.modifierMode, mode)
        }
    }

    func testResetRestoresDefaults() {
        let store = SettingsStore(defaults: defaults)
        store.update { $0.fineControl = true; $0.swapSides = true }
        store.resetToDefaults()
        XCTAssertEqual(store.snapshot, AppSettings.default)
    }

    // MARK: Validation

    func testInvalidValuesAreClampedOnWrite() {
        let store = SettingsStore(defaults: defaults)
        store.update {
            $0.sensitivity = 500
            $0.fineSensitivity = -3
            $0.edgeWidth = 0.9
            $0.typingSuppression = 60
            $0.verticalActivationThreshold = 0
        }
        let settings = store.snapshot
        XCTAssertLessThanOrEqual(settings.sensitivity, 6.0)
        XCTAssertGreaterThanOrEqual(settings.fineSensitivity, 0.05)
        XCTAssertLessThanOrEqual(settings.edgeWidth, 0.15)
        XCTAssertLessThanOrEqual(settings.typingSuppression, 2.0)
        XCTAssertGreaterThanOrEqual(settings.verticalActivationThreshold, 0.002)
    }

    func testNaNValuesFallBackToDefaults() {
        var settings = AppSettings.default
        settings.sensitivity = .nan
        settings.edgeWidth = .infinity
        let validated = settings.validated()
        XCTAssertTrue(validated.sensitivity.isFinite)
        XCTAssertTrue(validated.edgeWidth.isFinite)
        XCTAssertEqual(validated.sensitivity, 1.4, accuracy: 1e-12)
    }

    func testCorruptStoredDataFallsBackToDefaults() {
        defaults.set(Data("not json at all".utf8), forKey: "settings.v1")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.snapshot, AppSettings.default)
    }

    /// A settings file written by a build that predates a new preference must not
    /// wipe every other preference.
    func testPartialStoredDataMergesOverDefaults() throws {
        let partial: [String: Any] = [
            "isEnabled": false,
            "fineControl": true,
            "edgeWidth": 0.11,
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: partial), forKey: "settings.v1")

        let store = SettingsStore(defaults: defaults)
        let settings = store.snapshot
        XCTAssertFalse(settings.isEnabled)
        XCTAssertTrue(settings.fineControl)
        XCTAssertEqual(settings.edgeWidth, 0.11, accuracy: 1e-12)
        // Untouched keys keep their defaults rather than becoming zero.
        XCTAssertEqual(settings.rightEdgeAction, .volume)
        XCTAssertTrue(settings.smartTypingDetection)
        XCTAssertEqual(settings.sensitivity, AppSettings.default.sensitivity, accuracy: 1e-12)
    }

    func testNoWriteWhenNothingChanged() {
        let store = SettingsStore(defaults: defaults)
        let before = store.snapshot
        let after = store.update { $0.fineControl = before.fineControl }
        XCTAssertEqual(before, after)
    }

    // MARK: Concurrency

    func testConcurrentReadsAndWritesAreSafe() {
        let store = SettingsStore(defaults: defaults)
        let iterations = 500
        let group = DispatchGroup()

        for index in 0..<4 {
            DispatchQueue.global().async(group: group) {
                for step in 0..<iterations {
                    if index % 2 == 0 {
                        store.update { $0.sensitivity = 0.5 + Double(step % 30) / 10.0 }
                    } else {
                        _ = store.snapshot.activeSensitivity
                    }
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        XCTAssertTrue(store.snapshot.sensitivity.isFinite)
    }

    // MARK: Derived behaviour

    func testGestureConfigurationDerivesFromSettings() {
        var settings = AppSettings.default
        settings.edgeWidth = 0.1
        settings.fineControl = true
        settings.fineSensitivity = 0.3
        settings.swapSides = true
        settings.bottomQuarterOnly = true

        let configuration = GestureConfiguration.from(settings: settings,
                                                     modifierSatisfied: false,
                                                     typingSuppressed: true)
        XCTAssertEqual(configuration.edgeWidth, 0.1, accuracy: 1e-12)
        XCTAssertEqual(configuration.sensitivity, 0.3, accuracy: 1e-12)
        XCTAssertEqual(configuration.leftAssignment, .volume)
        XCTAssertEqual(configuration.rightAssignment, .brightness)
        XCTAssertTrue(configuration.bottomQuarterOnly)
        XCTAssertFalse(configuration.modifierSatisfied)
        XCTAssertTrue(configuration.typingSuppressed)
    }

    func testEdgeClassificationMatchesConfiguredWidth() {
        let configuration = GestureConfiguration(edgeWidth: 0.1)
        XCTAssertEqual(configuration.edge(forStartX: 0.0), .left)
        XCTAssertEqual(configuration.edge(forStartX: 0.1), .left)
        XCTAssertNil(configuration.edge(forStartX: 0.11))
        XCTAssertNil(configuration.edge(forStartX: 0.5))
        XCTAssertNil(configuration.edge(forStartX: 0.89))
        XCTAssertEqual(configuration.edge(forStartX: 0.9), .right)
        XCTAssertEqual(configuration.edge(forStartX: 1.0), .right)
    }
}
