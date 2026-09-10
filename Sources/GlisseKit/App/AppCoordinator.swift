//
//  AppCoordinator.swift
//  GlisseKit
//
//  Owns every service and defines startup, shutdown and recovery order.
//
//  Startup (spec §60) is deliberately cheap: nothing here blocks on hardware.
//  Display capability probing (which can take ~100 ms per external monitor
//  because of DDC) is kicked onto a utility queue, so the status item appears
//  immediately.
//

import AppKit
import Foundation

@MainActor
public final class AppCoordinator: MenuActionHandling {

    // MARK: Services

    private let settingsStore: SettingsStore
    private let permissions: PermissionManager
    private let loginItems = LoginItemManager()

    private let trackpadManager = TrackpadManager()
    private let engine = EdgeGestureEngine()
    private let tapRecognizer = ThreeFingerTapRecognizer()
    private let typingSuppression = TypingSuppressionService()
    private let modifierMonitor = ModifierMonitor()
    private let keyboardMonitor = KeyboardMonitor()

    private let volumeController = CoreAudioVolumeController()
    private let audioObserver = AudioDeviceObserver()

    private let builtInBrightness = DisplayServicesBrightnessBackend()
    private let ddcBrightness = DDCBrightnessBackend()
    private let displayManager: DisplayManager
    private let brightnessController: BrightnessController

    private let mediaKeys = MediaKeyController()
    private let hud: HUDCoordinator
    private let haptics: HapticFeedbackService
    private let cursor = CursorController()
    private let middleClick = MiddleClickSynthesizer()

    private let gestureCoordinator: GestureCoordinator
    private let lifecycle = AppLifecycleObserver()

    private var terminationGuard: TerminationGuard?
    private var statusItem: StatusItemController?
    private var aboutWindowController: AboutWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var diagnosticsWindowController: DiagnosticsWindowController?

    private var trackpadProblem: String?

    public init(settingsStore: SettingsStore = SettingsStore()) {
        self.settingsStore = settingsStore
        self.permissions = PermissionManager()
        self.displayManager = DisplayManager(builtInBackend: builtInBrightness,
                                            ddcBackend: ddcBrightness)
        self.brightnessController = BrightnessController(builtInBackend: builtInBrightness,
                                                         ddcBackend: ddcBrightness)
        self.haptics = HapticFeedbackService(strength: settingsStore.snapshot.hapticStrength)
        self.hud = HUDCoordinator(mediaKeys: mediaKeys)
        self.gestureCoordinator = GestureCoordinator(
            settings: settingsStore,
            engine: engine,
            tapRecognizer: tapRecognizer,
            volumeController: volumeController,
            brightnessController: brightnessController,
            displayManager: displayManager,
            typingSuppression: typingSuppression,
            modifierMonitor: modifierMonitor,
            hud: hud,
            mediaKeys: mediaKeys,
            haptics: haptics,
            cursor: cursor,
            middleClick: middleClick)
    }

    // MARK: - Startup

    public func start() {
        let settings = settingsStore.snapshot
        Log.diagnosticsEnabled = settings.diagnosticLogging
        Log.app.info("\(Branding.displayName, privacy: .public) starting (macOS \(ProcessInfo.processInfo.operatingSystemVersionString, privacy: .public))")

        // 0. Signal safety before anything can alter system state: a SIGTERM
        //    while the pointer is frozen must still release it.
        let guardian = TerminationGuard { [weak self] in
            self?.shutDown()
        }
        guardian.install()
        terminationGuard = guardian

        // 1. Menu bar first: the app must look alive instantly.
        let controller = StatusItemController(handler: self) { [weak self] in
            self?.currentMenuState() ?? MenuState.placeholder
        }
        controller.install()
        statusItem = controller

        // 2. Settings propagation.
        gestureCoordinator.applySettings(settings)

        // 3. Permissions: check, never nag on first launch.
        permissions.onAccessibilityChanged = { [weak self] state in
            self?.accessibilityChanged(to: state)
        }
        permissions.refresh()

        // 4. Lifecycle observers before any hardware is touched, so a wake during
        //    startup is not missed.
        lifecycle.onEvent = { [weak self] event in
            self?.handleLifecycle(event)
        }
        lifecycle.start()

        // 5. Audio.
        audioObserver.onOutputDeviceChanged = { [weak self] in
            guard let self else { return }
            self.volumeController.invalidateDeviceCache()
            Task { @MainActor in self.statusItem?.refresh() }
        }
        audioObserver.start()

        // 6. Displays. The first refresh probes DDC, so keep it off the main
        //    thread; the menu just shows nothing controllable for a moment.
        displayManager.externalDDCEnabled = settings.externalDDCEnabled
        displayManager.onDisplaysChanged = { [weak self] in
            Task { @MainActor in self?.statusItem?.refresh() }
        }
        DispatchQueue.global(qos: .utility).async { [displayManager] in
            displayManager.start()
        }

        // 7. Trackpad.
        trackpadManager.frameHandler = { [gestureCoordinator] frame in
            gestureCoordinator.handle(frame: frame)
        }
        trackpadManager.onSourceChanged = { [weak self] kind in
            Task { @MainActor in
                self?.trackpadProblem = nil
                // A different source may use a different coordinate convention.
                self?.gestureCoordinator.axisVerifier.invalidate()
                self?.prepareHaptics()
                self?.gestureCoordinator.resetState(reason: "touch source changed to \(kind.rawValue)")
                self?.statusItem?.refresh()
            }
        }
        trackpadManager.onUnavailable = { [weak self] error in
            Task { @MainActor in
                self?.trackpadProblem = error.localizedDescription
                self?.statusItem?.refresh()
                Log.trackpad.error("no touch source: \(error.localizedDescription, privacy: .public)")
            }
        }
        trackpadManager.setPreference(settings.touchSource)

        if settings.isEnabled {
            trackpadManager.start()
        }

        // 7b. Haptics: MTActuator is addressed by multitouch device id, so it can
        //     only be opened once devices are enumerated.
        prepareHaptics()

        // 8. Keyboard: only when it can do something useful.
        startKeyboardMonitorIfNeeded()

        // 9. Login item: reconcile the stored preference with reality.
        reconcileLaunchAtLogin(desired: settings.launchAtLogin)

        modifierMonitor.onToggleStateChanged = { [weak self] _ in
            Task { @MainActor in self?.statusItem?.refresh() }
        }
        modifierMonitor.setMode(settings.modifierMode)

        watchPermissionIfFeaturesAreWaiting()
        statusItem?.refresh()
        Log.app.info("\(Branding.displayName, privacy: .public) ready")
    }

    // MARK: - Shutdown

    private var hasShutDown = false

    public func shutDown() {
        guard !hasShutDown else { return }
        hasShutDown = true
        terminationGuard?.markCleanupComplete()
        Log.app.info("\(Branding.displayName, privacy: .public) shutting down")

        // Order matters: stop producing input, then release anything that alters
        // system state, then tear down observers.
        trackpadManager.stop()
        keyboardMonitor.stop()
        audioObserver.stop()

        gestureCoordinator.cancelActiveGesture(reason: "app quitting")
        // Cursor release is idempotent and must not depend on the async above.
        cursor.forceRelease(reason: "app quitting")

        brightnessController.flushPendingWrites()
        ddcBrightness.invalidate()
        haptics.invalidateBackend()

        permissions.stopWatching()
        statusItem?.remove()
        statusItem = nil
    }

    // MARK: - Settings plumbing

    private func mutate(_ change: (inout AppSettings) -> Void) {
        settingsStore.update(change)
        settingsDidChange()
    }

    private func settingsDidChange() {
        let settings = settingsStore.snapshot
        gestureCoordinator.applySettings(settings)
        trackpadManager.setPreference(settings.touchSource)

        if settings.isEnabled {
            if !trackpadManager.isRunning { trackpadManager.start() }
        } else {
            trackpadManager.stop()
            gestureCoordinator.cancelActiveGesture(reason: "disabled")
        }

        startKeyboardMonitorIfNeeded()
        displayManager.externalDDCEnabled = settings.externalDDCEnabled
        watchPermissionIfFeaturesAreWaiting()
        statusItem?.refresh()
        settingsWindowController?.reload()
    }

    /// Keeps an eye on Accessibility for as long as an enabled feature is blocked
    /// on it, so granting later just works instead of needing a relaunch.
    private func watchPermissionIfFeaturesAreWaiting() {
        guard !permissions.accessibility.isGranted else {
            permissions.stopWatching()
            return
        }
        let settings = settingsStore.snapshot
        let waiting = settings.hudEnabled
            || settings.smartTypingDetection
            || settings.threeFingerMiddleClick
            || modifierMonitor.requiresKeyboardTap
        permissions.wantsIndefiniteWatch = waiting
        if waiting {
            permissions.watchIndefinitely()
        }
    }

    /// The keyboard tap is only installed when a feature needs it, so a user who
    /// wants nothing but edge sliding is never asked for Accessibility.
    private func startKeyboardMonitorIfNeeded() {
        let settings = settingsStore.snapshot
        let needsTap = settings.smartTypingDetection || modifierMonitor.requiresKeyboardTap

        guard needsTap, permissions.accessibility.isGranted else {
            if keyboardMonitor.isRunning { keyboardMonitor.stop() }
            return
        }
        guard !keyboardMonitor.isRunning else { return }

        keyboardMonitor.onKeyDown = { [typingSuppression] timestamp in
            typingSuppression.noteKeyDown(at: timestamp)
        }
        keyboardMonitor.onFlagsChanged = { [modifierMonitor] flags in
            modifierMonitor.handleFlagsChanged(flags)
        }
        keyboardMonitor.onTapInvalidated = { [weak self] in
            Task { @MainActor in
                self?.permissions.refresh()
                self?.statusItem?.refresh()
            }
        }

        do {
            try keyboardMonitor.start()
        } catch {
            Log.input.warning("keyboard monitor unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func prepareHaptics() {
        let deviceID = trackpadManager.actuatorDeviceID
        guard deviceID != 0 else {
            haptics.invalidateBackend()
            return
        }
        haptics.prepare(deviceID: deviceID)
    }

    private func accessibilityChanged(to state: PermissionManager.AccessibilityState) {
        middleClick.refreshAvailability()
        if state.isGranted {
            Log.permissions.info("accessibility granted; enabling dependent features")
            permissions.stopWatching()
            startKeyboardMonitorIfNeeded()
        } else {
            keyboardMonitor.stop()
            watchPermissionIfFeaturesAreWaiting()
            // A revoked permission can kill the AppKit touch source; make sure
            // no gesture is left half-finished.
            gestureCoordinator.cancelActiveGesture(reason: "accessibility revoked")
            if trackpadManager.activeSourceKind == .appKit {
                trackpadProblem = "Accessibility permission was revoked."
                trackpadManager.stop()
            }
        }
        statusItem?.refresh()
        settingsWindowController?.reload()
        diagnosticsWindowController?.reload()
    }

    /// Brings the actual login-item registration in line with the stored
    /// preference — but only for an installed copy.
    ///
    /// Auto-registering whatever bundle happens to be running would mean that
    /// building the project silently adds `build/Glisse.app` to the user's
    /// login items, pointing at a path that gets deleted by `make clean`. The
    /// manual menu toggle still works from anywhere.
    private func reconcileLaunchAtLogin(desired: Bool) {
        let state = loginItems.state
        if case .unavailable = state { return }
        guard state.isEnabled != desired else { return }

        guard loginItems.isInInstalledLocation else {
            Log.app.info("""
                skipping automatic launch-at-login registration: running from \
                \(Bundle.main.bundleURL.deletingLastPathComponent().path, privacy: .public)
                """)
            return
        }
        _ = loginItems.setEnabled(desired)
    }

    // MARK: - Lifecycle recovery

    private func handleLifecycle(_ event: AppLifecycleObserver.Event) {
        switch event {
        case .willSleep, .screensDidSleep, .screenLocked, .sessionResignedActive:
            // Never leave the cursor detached across a sleep or a lock.
            gestureCoordinator.cancelActiveGesture(reason: "system going inactive")
            cursor.forceRelease(reason: "system going inactive")
            haptics.invalidateBackend()

        case .didWake, .screensDidWake, .screenUnlocked, .sessionBecameActive:
            recoverAfterWake()

        case .displayConfigurationChanged:
            displayManager.invalidateTransports()
            brightnessController.invalidateCaches()
            displayManager.scheduleRefresh()

        case .appDidResignActive:
            // The app losing focus must not leave a gesture running.
            gestureCoordinator.cancelActiveGesture(reason: "app resigned active")

        case .appDidBecomeActive:
            permissions.refresh()
        }
    }

    /// Everything that can go stale across sleep, rebuilt in dependency order.
    private func recoverAfterWake() {
        Log.lifecycle.info("recovering after wake")

        // 1. No gesture may survive a discontinuity.
        gestureCoordinator.resetState(reason: "wake")
        cursor.forceRelease(reason: "wake")

        // 2. Audio: the default device may have changed while asleep.
        volumeController.invalidateDeviceCache()

        // 2b. The haptic actuator and the OSD helper connection both go stale.
        haptics.invalidateBackend()
        hud.invalidateConnections()

        // 3. Displays: DDC endpoints are stale even when they look valid.
        displayManager.invalidateTransports()
        brightnessController.invalidateCaches()
        displayManager.scheduleRefresh(after: 1.5)

        // 4. Trackpad: MultitouchSupport device refs are the classic casualty.
        //    Give the HID stack a moment to come back before re-registering.
        if settingsStore.snapshot.isEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.trackpadManager.restart(reason: "wake")
                self.prepareHaptics()
                self.statusItem?.refresh()
            }
        }

        // 5. Event taps sometimes come back disabled.
        if keyboardMonitor.isRunning {
            keyboardMonitor.restart()
        } else {
            startKeyboardMonitorIfNeeded()
        }

        permissions.refresh()
    }

    // MARK: - Menu state

    private func currentMenuState() -> MenuState {
        // One AXIsProcessTrusted() call. Cheap, and it means opening the menu
        // always shows the truth rather than a cached answer from launch.
        permissions.refresh()

        let settings = settingsStore.snapshot
        let devices = trackpadManager.devices

        var problem: String? = trackpadProblem
        if problem == nil, settings.isEnabled, devices.isEmpty {
            problem = "No trackpad detected"
        }
        if problem == nil, !volumeController.isVolumeControlAvailable,
           settings.assignment(for: .left) == .volume || settings.assignment(for: .right) == .volume {
            problem = "\(volumeController.currentDeviceName) has no volume control"
        }
        // The macOS HUD can only be triggered by delegating the change to the
        // system, which needs Accessibility. Say so rather than silently showing
        // nothing.
        if problem == nil, settings.hudEnabled, hud.needsAccessibilityForHUD {
            problem = "Grant Accessibility to show the macOS volume/brightness display"
        }
        if problem == nil, case .requiresApproval = loginItems.state {
            problem = "Approve \(Branding.displayName) in Login Items"
        }

        return MenuState(
            settings: settings,
            isActive: settings.isEnabled && !modifierMonitor.isToggledOff && !devices.isEmpty,
            isToggledOff: modifierMonitor.isToggledOff,
            touchSourceName: trackpadManager.activeSourceName,
            trackpadCount: devices.count,
            accessibilityGranted: permissions.accessibility.isGranted,
            launchAtLoginState: loginItems.state,
            audioDeviceName: volumeController.currentDeviceName,
            volumeControlAvailable: volumeController.isVolumeControlAvailable,
            controllableDisplays: displayManager.controllableDisplays,
            hudProviderName: hud.mechanism(canUseMediaKeys: true).displayName,
            problem: problem)
    }

    // MARK: - MenuActionHandling

    public func toggleEnabled() {
        mutate { $0.isEnabled.toggle() }
    }

    public func setEdgeAssignment(_ assignment: EdgeAssignment, for edge: TrackpadEdge) {
        mutate { settings in
            // Menu positions are what the user sees, so undo the swap before
            // storing: choosing "Left Edge: Volume" must mean the physical left.
            let physical: TrackpadEdge = settings.swapSides ? (edge == .left ? .right : .left) : edge
            if physical == .left {
                settings.leftEdgeAction = assignment
            } else {
                settings.rightEdgeAction = assignment
            }
        }
    }

    public func toggleFineControl() { mutate { $0.fineControl.toggle() } }
    public func toggleSwapSides() { mutate { $0.swapSides.toggle() } }
    public func toggleBottomQuarter() { mutate { $0.bottomQuarterOnly.toggle() } }
    public func toggleFreezeCursor() { mutate { $0.freezeCursor.toggle() } }
    public func toggleHaptics() { mutate { $0.hapticsEnabled.toggle() } }

    public func setHapticStrength(_ strength: HapticStrength) {
        mutate {
            $0.hapticStrength = strength
            // Choosing a strength implies wanting haptics on.
            $0.hapticsEnabled = true
        }
        // Fire one tick immediately so the choice can be felt without having to
        // go and make a gesture.
        haptics.demoTick()
    }
    public func toggleNativeHUD() { mutate { $0.hudEnabled.toggle() } }

    public func toggleThreeFingerMiddleClick() {
        let willEnable = !settingsStore.snapshot.threeFingerMiddleClick
        if willEnable, !permissions.accessibility.isGranted {
            promptForAccessibility(reason: "Three-finger middle click needs to post mouse events.")
            return
        }
        mutate { $0.threeFingerMiddleClick.toggle() }
    }

    public func toggleSmartTyping() {
        let willEnable = !settingsStore.snapshot.smartTypingDetection
        if willEnable, !permissions.accessibility.isGranted {
            promptForAccessibility(reason: "Pausing while you type needs to observe keyboard activity.")
            return
        }
        mutate { $0.smartTypingDetection.toggle() }
    }

    public func setModifierMode(_ mode: ModifierMode) {
        if case .toggle = mode, !permissions.accessibility.isGranted {
            promptForAccessibility(reason: "Toggle mode needs to observe modifier keys.")
            return
        }
        mutate { $0.modifierMode = mode }
        modifierMonitor.setMode(mode)
    }

    public func setBrightnessTarget(_ target: BrightnessTarget) {
        mutate { $0.brightnessTarget = target }
    }

    public func pinDisplay(_ displayID: UInt32?) {
        mutate { $0.pinnedDisplayID = displayID }
    }

    public func toggleLaunchAtLogin() {
        let desired = !loginItems.state.isEnabled
        switch loginItems.setEnabled(desired) {
        case .success(let state):
            mutate { $0.launchAtLogin = state.isEnabled }
            if state == .requiresApproval {
                loginItems.openLoginItemsSettings()
            }
        case .failure(let error):
            presentAlert(title: "Launch at Login", message: error.localizedDescription)
        }
    }

    public func openPermissions() {
        permissions.refresh()
        let granted = permissions.accessibility.isGranted

        let alert = NSAlert()
        alert.messageText = "Accessibility: \(permissions.accessibility.displayName)"
        alert.informativeText = PermissionManager.accessibilityRationale
        alert.alertStyle = granted ? .informational : .warning

        if granted {
            alert.addButton(withTitle: "Done")
            alert.addButton(withTitle: "Open System Settings")
        } else {
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")
        }

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        let openSettings = granted
            ? (response == .alertSecondButtonReturn)
            : (response == .alertFirstButtonReturn)
        if openSettings {
            permissions.requestAccessibility()
            permissions.openSystemSettings()
        }
    }

    private func promptForAccessibility(reason: String) {
        let alert = NSAlert()
        alert.messageText = "Accessibility permission required"
        alert.informativeText = reason + "\n\n" + PermissionManager.accessibilityRationale
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            permissions.requestAccessibility()
            permissions.openSystemSettings()
        }
    }

    public func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                settingsStore: settingsStore,
                permissions: permissions,
                loginItems: loginItems,
                displayManager: displayManager,
                volumeController: volumeController,
                onChange: { [weak self] in self?.settingsDidChange() })
        }
        settingsWindowController?.show()
    }

    public func openDiagnostics() {
        if diagnosticsWindowController == nil {
            diagnosticsWindowController = DiagnosticsWindowController { [weak self] in
                self?.diagnosticsText() ?? "unavailable"
            }
        }
        diagnosticsWindowController?.show()
    }

    public func showAbout() {
        if aboutWindowController == nil {
            aboutWindowController = AboutWindowController()
        }
        aboutWindowController?.show()
    }

    public func quit() {
        NSApp.terminate(nil)
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Diagnostics text

    public func diagnosticsText() -> String {
        var text = "Glisse diagnostics\n"
        text += "=====================\n\n"
        text += "System\n"
        text += "  macOS            : \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        text += "  bundle           : \(Bundle.main.bundleURL.lastPathComponent)\n"
        text += "  architecture     : \(Self.architecture)\n\n"

        text += permissions.diagnosticsDescription() + "\n"
        text += "  keyboard tap     : \(keyboardMonitor.isRunning ? "running" : "NOT running")\n\n"
        text += loginItems.diagnosticsDescription() + "\n\n"
        text += trackpadManager.diagnosticsDescription() + "\n"
        text += gestureCoordinator.diagnosticsDescription() + "\n\n"
        text += haptics.diagnosticsDescription() + "\n"
        text += volumeController.diagnosticsDescription() + "\n"
        text += builtInBrightness.diagnosticsDescription() + "\n"
        text += ddcBrightness.diagnosticsDescription() + "\n"
        text += displayManager.diagnosticsDescription() + "\n"
        text += hud.diagnosticsDescription()
        return text
    }

    nonisolated static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

// MARK: - Placeholder

extension MenuState {
    static let placeholder = MenuState(
        settings: .default,
        isActive: false,
        isToggledOff: false,
        touchSourceName: "starting",
        trackpadCount: 0,
        accessibilityGranted: false,
        launchAtLoginState: .disabled,
        audioDeviceName: "-",
        volumeControlAvailable: false,
        controllableDisplays: [],
        hudProviderName: "-",
        problem: nil)
}
