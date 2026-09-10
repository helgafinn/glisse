//
//  GestureCoordinator.swift
//  GlisseKit
//
//  Turns trackpad frames into real volume and brightness changes.
//
//  Threading model
//  ---------------
//      touch source thread (~125 Hz)
//            |  minimal work: hand off the immutable frame
//            v
//      serial gesture queue (.userInteractive)
//            |  engine step, value arithmetic, hardware write
//            +--> DisplayServices / Core Audio  (fast, synchronous)
//            +--> DDC coalescer queue           (slow, off this thread)
//            +--> HUD (throttled)  +  haptics (detent-gated)
//
//  Nothing here touches AppKit on the gesture queue. Backpressure is handled by
//  dropping frames rather than queueing them: a stale finger position is worth
//  less than low latency, and an unbounded queue would turn one slow write into
//  a growing lag.
//

import CoreGraphics
import Foundation

public final class GestureCoordinator: @unchecked Sendable {

    // MARK: Dependencies

    private let settings: SettingsStore
    private let engine: EdgeGestureEngine
    private let tapRecognizer: ThreeFingerTapRecognizer
    private let volumeController: CoreAudioVolumeController
    private let brightnessController: BrightnessController
    private let displayManager: DisplayManager
    private let typingSuppression: TypingSuppressionService
    private let modifierMonitor: ModifierMonitor
    private let hud: HUDCoordinator
    private let mediaKeys: MediaKeyController
    private let haptics: HapticFeedbackService
    private let cursor: CursorController
    private let middleClick: MiddleClickSynthesizer
    /// Confirms the vertical coordinate contract against this machine. Stops
    /// sampling for good once it reaches a verdict.
    public let axisVerifier = AxisOrientationVerifier()

    // MARK: Queue

    private let queue = DispatchQueue(label: "xyz.glisse.gesture", qos: .userInteractive)
    /// Frames handed to the queue but not yet processed.
    private let inFlight = AtomicCounter()
    /// Above this, incoming frames are dropped. 3 is ~24 ms of trackpad data.
    private let maximumInFlightFrames = 3

    // MARK: In-flight gesture state (gesture queue only)

    private struct ActiveGesture {
        let assignment: EdgeAssignment
        let edge: TrackpadEdge
        let deviceID: String
        var value: Double
        var displays: [DisplayTarget]
        var startedMuted: Bool
        var hitLimit: Bool
        /// How this gesture produces the OS HUD. Decided once, at the start, so it
        /// cannot change halfway through a slide.
        var hudMechanism: HUDMechanism
    }
    private var active: ActiveGesture?

    /// Cached snapshot of settings, refreshed when the store publishes.
    private let settingsLock = NSLock()
    private var cachedSettings: AppSettings

    /// Reported to the UI.
    public private(set) var lastError: String?

    public init(settings: SettingsStore,
                engine: EdgeGestureEngine,
                tapRecognizer: ThreeFingerTapRecognizer,
                volumeController: CoreAudioVolumeController,
                brightnessController: BrightnessController,
                displayManager: DisplayManager,
                typingSuppression: TypingSuppressionService,
                modifierMonitor: ModifierMonitor,
                hud: HUDCoordinator,
                mediaKeys: MediaKeyController,
                haptics: HapticFeedbackService,
                cursor: CursorController,
                middleClick: MiddleClickSynthesizer) {
        self.settings = settings
        self.engine = engine
        self.tapRecognizer = tapRecognizer
        self.volumeController = volumeController
        self.brightnessController = brightnessController
        self.displayManager = displayManager
        self.typingSuppression = typingSuppression
        self.modifierMonitor = modifierMonitor
        self.hud = hud
        self.mediaKeys = mediaKeys
        self.haptics = haptics
        self.cursor = cursor
        self.middleClick = middleClick
        self.cachedSettings = settings.snapshot
    }

    // MARK: Settings

    public func applySettings(_ newSettings: AppSettings) {
        settingsLock.lock()
        cachedSettings = newSettings
        settingsLock.unlock()

        typingSuppression.isEnabled = newSettings.smartTypingDetection
        typingSuppression.suppressionDuration = newSettings.typingSuppression
        haptics.isEnabled = newSettings.hapticsEnabled
        haptics.strength = newSettings.hapticStrength
        hud.isEnabled = newSettings.hudEnabled
        modifierMonitor.setMode(newSettings.modifierMode)
        displayManager.externalDDCEnabled = newSettings.externalDDCEnabled

        if !newSettings.isEnabled {
            cancelActiveGesture(reason: "disabled")
        }
    }

    private var currentSettings: AppSettings {
        settingsLock.lock(); defer { settingsLock.unlock() }
        return cachedSettings
    }

    // MARK: Frame intake

    /// Called from the touch source thread. Keep this tiny.
    public func handle(frame: TrackpadFrame) {
        guard inFlight.value < maximumInFlightFrames else {
            Log.diagnostic(Log.gesture, "dropping frame: \(self.inFlight.value) in flight")
            return
        }
        inFlight.increment()
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.inFlight.decrement() }
            self.process(frame: frame)
        }
    }

    // MARK: Processing (gesture queue)

    private func process(frame: TrackpadFrame) {
        let snapshot = currentSettings

        // Passive, self-terminating: costs nothing once a verdict exists.
        if !axisVerifier.isComplete {
            axisVerifier.observe(frame: frame)
        }

        // Modifier state is sampled per frame rather than cached: for hold mode
        // it is a direct hardware read, and it must be current at the exact
        // moment a contact appears.
        let modifierOK = modifierMonitor.isSatisfied()
        let suppressed = typingSuppression.isSuppressed()

        engine.configuration = GestureConfiguration.from(settings: snapshot,
                                                        modifierSatisfied: modifierOK,
                                                        typingSuppressed: suppressed)

        let output = engine.process(frame)

        // Lifecycle before actions so the starting value is captured before the
        // first delta is applied.
        for event in output.lifecycle {
            switch event {
            case .began(let deviceID, let edge, let assignment, _):
                beginGesture(deviceID: deviceID, edge: edge, assignment: assignment, settings: snapshot)
            case .ended:
                endGesture()
            }
        }

        if !output.actions.isEmpty {
            apply(actions: output.actions, settings: snapshot)
            if snapshot.freezeCursor { cursor.heartbeat() }
        }

        // Three-finger tap: only when no slider gesture is running.
        if snapshot.threeFingerMiddleClick, snapshot.isEnabled {
            let taps = tapRecognizer.process(frame, sliderGestureActive: engine.hasActiveGesture)
            if !taps.isEmpty, modifierOK {
                middleClick.performMiddleClick()
            }
        }
    }

    // MARK: Gesture lifecycle

    private func beginGesture(deviceID: String,
                              edge: TrackpadEdge,
                              assignment: EdgeAssignment,
                              settings snapshot: AppSettings) {
        var displays: [DisplayTarget] = []
        var startValue = 0.0
        var startedMuted = false
        /// Media keys act on whatever output device and display macOS considers
        /// current. That is fine for volume and for the main built-in screen, but
        /// it cannot address a pinned or external display — so those keep the
        /// precise direct path and forgo the HUD.
        var canDelegateToSystem = false


        switch assignment {
        case .volume:
            startedMuted = (try? volumeController.isMuted()) ?? false
            startValue = (try? volumeController.currentVolume()) ?? 0
            guard volumeController.isVolumeControlAvailable else {
                lastError = "The current output device has no volume control."
                Log.audio.warning("volume gesture ignored: device has no volume control")
                return
            }
            canDelegateToSystem = true

        case .brightness:
            displays = displayManager.resolveTargets(preference: snapshot.brightnessTarget,
                                                     pinnedDisplayID: snapshot.pinnedDisplayID)
            guard let primary = displays.first else {
                lastError = "No display supports brightness control."
                Log.brightness.warning("brightness gesture ignored: no controllable display")
                return
            }
            brightnessController.prepareForGesture(on: displays)
            startValue = brightnessController.brightnessForGestureStart(primary)
            canDelegateToSystem = displays.count == 1
                && primary.isMain
                && primary.capabilities.backend != .ddc
                && snapshot.pinnedDisplayID == nil

        case .none:
            return
        }

        let mechanism = hud.mechanism(canUseMediaKeys: canDelegateToSystem)

        active = ActiveGesture(assignment: assignment,
                               edge: edge,
                               deviceID: deviceID,
                               value: clamp01(startValue),
                               displays: displays,
                               startedMuted: startedMuted,
                               hitLimit: false,
                               hudMechanism: mechanism)

        haptics.beginGesture(atValue: clamp01(startValue))
        if snapshot.freezeCursor { cursor.freeze() }
        if mechanism == .mediaKeys { mediaKeys.resetAccumulator() }

        // Only the direct-OSD mechanism can show a value without changing it, so
        // only it gets an opening frame. With media keys the HUD appears with the
        // first real step, exactly as it does when pressing the keys.
        if mechanism == .osdInjection { presentHUD(force: true) }

        Log.diagnostic(Log.gesture, """
            gesture began: \(assignment.rawValue) on \(edge.rawValue) edge, \
            start \(String(format: "%.3f", startValue))
            """)
    }

    private func endGesture() {
        guard active != nil else { return }
        active = nil

        brightnessController.flushPendingWrites()
        mediaKeys.resetAccumulator()
        haptics.endGesture()
        cursor.release()
        hud.gestureDidEnd()

        Log.diagnostic(Log.gesture, "gesture ended")
    }

    /// Used when the app is disabled, loses permission, sleeps or the trackpad
    /// disappears mid-slide.
    public func cancelActiveGesture(reason: String) {
        queue.async { [weak self] in
            guard let self else { return }
            _ = self.engine.cancelAll()
            self.tapRecognizer.reset()
            if self.active != nil {
                Log.gesture.info("cancelling active gesture: \(reason, privacy: .public)")
            }
            self.active = nil
            self.brightnessController.flushPendingWrites()
            self.mediaKeys.resetAccumulator()
            self.haptics.endGesture()
            self.cursor.forceRelease(reason: reason)
            self.hud.reset()
        }
    }

    /// Full state reset. Called on wake and when the touch source changes.
    public func resetState(reason: String) {
        queue.async { [weak self] in
            guard let self else { return }
            _ = self.engine.cancelAll()
            self.engine.reset()
            self.tapRecognizer.reset()
            self.active = nil
            self.typingSuppression.reset()
            self.mediaKeys.resetAccumulator()
            self.haptics.endGesture()
            self.cursor.forceRelease(reason: reason)
            self.hud.reset()
            self.brightnessController.invalidateCaches()
            Log.gesture.info("gesture state reset: \(reason, privacy: .public)")
        }
    }

    // MARK: Applying adjustments

    private func apply(actions: [EdgeAction], settings snapshot: AppSettings) {
        guard var gesture = active else { return }

        // Sum the frame's deltas: one hardware write per frame, never several.
        var delta = 0.0
        for action in actions {
            switch action {
            case .volume(let d) where gesture.assignment == .volume:
                delta += d
            case .brightness(let d) where gesture.assignment == .brightness:
                delta += d
            default:
                continue
            }
        }
        guard delta != 0, delta.isFinite else { return }

        // ------------------------------------------------------------------
        // Media-key path: hand the change to macOS so macOS draws its own HUD.
        //
        // Nothing is written directly here — the system performs the change. The
        // value is then read back rather than predicted, so the haptics and the
        // end-stop detection stay in step with what actually happened.
        // ------------------------------------------------------------------
        if gesture.hudMechanism == .mediaKeys {
            let axis: MediaKeyController.Axis =
                gesture.assignment == .volume ? .volume : .brightness
            let posted = mediaKeys.apply(delta: delta, to: axis)
            guard posted > 0 else { return }

            let observed = readCurrentValue(for: gesture) ?? gesture.value
            let previous = gesture.value
            gesture.value = observed

            if observed == previous {
                if !gesture.hitLimit {
                    gesture.hitLimit = true
                    haptics.hitLimit()
                }
            } else {
                gesture.hitLimit = false
                haptics.valueChanged(to: observed)
            }
            active = gesture
            lastError = nil
            return
        }

        // ------------------------------------------------------------------
        // Direct path: write the exact value. Precise and continuous. Produces a
        // HUD only where the private OSD interface still renders (macOS 13–15).
        // ------------------------------------------------------------------
        let outcome = ValueAdjustment.apply(current: gesture.value, delta: delta)
        let target = outcome.value

        // At an end stop, tick once and stop writing.
        if outcome.hitLimit {
            if !gesture.hitLimit {
                gesture.hitLimit = true
                haptics.hitLimit()
            }
            active = gesture
            return
        }
        gesture.hitLimit = false
        gesture.value = target
        active = gesture

        switch gesture.assignment {
        case .volume:
            writeVolume(target, gesture: gesture)
        case .brightness:
            writeBrightness(target, gesture: gesture)
        case .none:
            return
        }

        haptics.valueChanged(to: target)
        presentHUD(force: false)
    }

    /// Reads back what the system actually settled on. Used by the media-key path,
    /// where macOS owns the value.
    private func readCurrentValue(for gesture: ActiveGesture) -> Double? {
        switch gesture.assignment {
        case .volume:
            return try? volumeController.currentVolume()
        case .brightness:
            guard let display = gesture.displays.first else { return nil }
            return try? brightnessController.currentBrightness(for: display)
        case .none:
            return nil
        }
    }

    private func writeVolume(_ value: Double, gesture: ActiveGesture) {
        do {
            try volumeController.setVolume(value)

            // Mute coupling (spec §26). Decision logic lives in MuteCoupling so
            // it is unit tested rather than reasoned about in passing.
            let currentlyMuted = (try? volumeController.isMuted()) ?? false
            switch MuteCoupling.decide(targetVolume: value,
                                       currentlyMuted: currentlyMuted,
                                       startedMuted: gesture.startedMuted) {
            case .mute:   try? volumeController.setMuted(true)
            case .unmute: try? volumeController.setMuted(false)
            case .none:   break
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            Log.diagnostic(Log.audio, "volume write failed: \(error.localizedDescription)")
        }
    }

    private func writeBrightness(_ value: Double, gesture: ActiveGesture) {
        var anySuccess = false
        for display in gesture.displays {
            do {
                try brightnessController.setBrightness(value, for: display)
                anySuccess = true
            } catch {
                Log.diagnostic(Log.brightness,
                               "brightness write failed for \(display.id): \(error.localizedDescription)")
            }
        }
        if anySuccess {
            lastError = nil
        } else {
            lastError = "Brightness could not be changed on the target display."
        }
    }

    // MARK: HUD

    private func presentHUD(force: Bool) {
        guard let gesture = active else { return }
        switch gesture.assignment {
        case .volume:
            let muted = gesture.value <= MuteCoupling.silenceThreshold
            hud.showVolume(level: gesture.value, muted: muted, force: force)
        case .brightness:
            hud.showBrightness(level: gesture.value,
                               display: gesture.displays.first?.id,
                               force: force)
        case .none:
            break
        }
    }

    // MARK: Diagnostics

    public func diagnosticsSnapshot() -> GestureDiagnostics {
        queue.sync { engine.diagnostics }
    }

    public func diagnosticsDescription() -> String {
        let diagnostics = diagnosticsSnapshot()
        let snapshot = currentSettings
        return """
        Gesture engine
          frames processed : \(diagnostics.framesProcessed)
          candidates       : \(diagnostics.candidateCount)
          active           : \(diagnostics.activeCount)
          rejected         : \(diagnostics.rejectedCount)
          last reject      : \(diagnostics.lastRejectReason.isEmpty ? "-" : diagnostics.lastRejectReason)
          last start       : x=\(fmt(diagnostics.lastStartX)) y=\(fmt(diagnostics.lastStartY))
          last position    : x=\(fmt(diagnostics.lastX)) y=\(fmt(diagnostics.lastY))
          raw dY           : \(fmt(diagnostics.lastRawDeltaY))
          scaled delta     : \(fmt(diagnostics.lastScaledDelta))
          emitted delta    : \(fmt(diagnostics.lastEmittedDelta))
          edge strip       : x <= \(fmt(snapshot.edgeWidth)) or x >= \(fmt(1 - snapshot.edgeWidth))
          sensitivity      : \(fmt(snapshot.activeSensitivity))\(snapshot.fineControl ? " (fine)" : "")
          typing detection : \(snapshot.smartTypingDetection ? "on" : "off"), window \(Int(snapshot.typingSuppression * 1000))ms
          keys observed    : \(typingActivityDescription)
          typing suppressed: \(typingSuppression.isSuppressed())
          modifier ok      : \(modifierMonitor.isSatisfied())
          invert vertical  : \(snapshot.invertVerticalAxis)

        \(axisVerifier.diagnosticsDescription())
        """
    }

    private var typingActivityDescription: String {
        let activity = typingSuppression.activity
        guard let since = activity.secondsSinceLastKey else {
            return "0 — the keyboard tap has delivered nothing"
        }
        return "\(activity.keyCount), last \(String(format: "%.1f", since))s ago"
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}

// MARK: - Small lock-free counter

/// Used only for frame backpressure accounting.
final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }

    func decrement() {
        lock.lock(); count = max(0, count - 1); lock.unlock()
    }
}
