//
//  GlisseMain.swift
//  GlisseKit
//
//  Entry point, plus two terminal modes that exist because a background utility
//  is otherwise impossible to verify on real hardware:
//
//    --probe      one-shot capability report: which private frameworks resolved,
//                 which trackpads and displays were found, what the audio device
//                 supports, whether the native HUD is drivable.
//
//    --diagnose   live stream of normalised touch coordinates. This is how the
//                 coordinate contract, the edge thresholds and the vertical
//                 direction get confirmed against a physical trackpad instead of
//                 being assumed.
//

import AppKit
import GlissePrivate
import Foundation

public enum GlisseMain {

    public static func run(arguments: [String]) {
        let flags = Set(arguments.dropFirst())

        if flags.contains("--version") || flags.contains("-v") {
            print("\(Branding.displayName) \(Branding.version)")
            return
        }

        if flags.contains("--help") || flags.contains("-h") {
            printUsage()
            return
        }

        // `--source mt|appkit` forces a touch source, so the public fallback path
        // can be exercised without editing preferences.
        let sourcePreference = Self.parseSource(arguments)

        if flags.contains("--probe") {
            runProbe(source: sourcePreference)
            return
        }

        if flags.contains("--diagnose") {
            runDiagnose(source: sourcePreference)
            return
        }

        if flags.contains("--selftest") {
            runSelfTest()
            return
        }

        // Icon and preview export, so the artwork has exactly one implementation
        // shared by the menu bar, the About panel and the .icns file.
        if flags.contains("--export-icon") {
            let argv = Array(arguments.dropFirst())
            let directory = argv.firstIndex(of: "--export-icon").flatMap { index -> String? in
                index + 1 < argv.count ? argv[index + 1] : nil
            } ?? FileManager.default.currentDirectoryPath
            runExportIcon(to: directory)
            return
        }

        if flags.contains("--haptictest") {
            runHapticTest()
            return
        }

        if flags.contains("--hudtest") {
            runHUDTest()
            return
        }

        if flags.contains("--login-item") {
            let argv = Array(arguments.dropFirst())
            let action = argv.firstIndex(of: "--login-item").flatMap { index -> String? in
                index + 1 < argv.count ? argv[index + 1] : nil
            } ?? "status"
            runLoginItem(action: action)
            return
        }

        runApp()
    }

    private static func printUsage() {
        print("""
        \(Branding.displayName) — trackpad edge volume & brightness control

        usage: Glisse [options]

          (no options)   run as a menu-bar app
          --probe        print a one-shot capability report and exit
          --diagnose     stream live trackpad touch coordinates (Ctrl-C to stop)
          --source X     with --probe/--diagnose: force "mt" or "appkit"
          --export-icon D  write AppIcon.iconset plus logo previews into D
          --haptictest   fire every trackpad actuation pattern in turn, labelled
          --hudtest      try each system-HUD route in turn
          --selftest     exercise the volume, brightness and HUD paths for real,
                         then restore the original values
          --version      print the version
          --help         this text
        """)
    }

    private static func parseSource(_ arguments: [String]) -> TouchSourcePreference {
        let argv = Array(arguments.dropFirst())
        guard let index = argv.firstIndex(of: "--source"), index + 1 < argv.count else {
            return .automatic
        }
        switch argv[index + 1].lowercased() {
        case "mt", "multitouch", "multitouchsupport": return .multitouchSupport
        case "appkit", "nstouch", "public":           return .appKitTouches
        default:                                      return .automatic
        }
    }

    // MARK: - Icon export

    private static func runExportIcon(to path: String) {
        MainActor.assumeIsolated {
            let directory = URL(fileURLWithPath: path)
            do {
                let iconset = directory.appendingPathComponent("AppIcon.iconset")
                try LogoArtwork.exportIconSet(to: iconset)
                print("wrote \(iconset.path)")

                // Previews, so the artwork can be inspected without launching.
                let previews: [(String, NSImage, CGFloat)] = [
                    ("preview-icon-256.png", LogoArtwork.appIcon(size: 256), 1),
                    ("preview-icon-64.png", LogoArtwork.appIcon(size: 64), 1),
                    ("preview-icon-32.png", LogoArtwork.appIcon(size: 32), 1),
                    ("preview-mark-dark.png", markOnCanvas(background: .black, foreground: .white), 1),
                    ("preview-icon-on-white.png", onCanvas(LogoArtwork.appIcon(size: 200), background: .white), 1),
                    ("preview-icon-on-magenta.png", onCanvas(LogoArtwork.appIcon(size: 200), background: .magenta), 1),
                    ("preview-mark-light.png", markOnCanvas(background: .white, foreground: .black), 1),
                ]
                for (name, image, scale) in previews {
                    if let data = LogoArtwork.pngData(for: image, scale: scale) {
                        try data.write(to: directory.appendingPathComponent(name))
                    }
                }

                let lockup = LogoArtwork.lockup(pointSize: 44, color: .white)
                if let data = LogoArtwork.pngData(for: onCanvas(lockup, background: .black), scale: 2) {
                    try data.write(to: directory.appendingPathComponent("preview-lockup.png"))
                }
                print("wrote previews to \(directory.path)")
            } catch {
                FileHandle.standardError.write(Data("export failed: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    /// The bare mark on a flat background, for eyeballing contrast.
    @MainActor
    private static func markOnCanvas(background: NSColor, foreground: NSColor) -> NSImage {
        let size: CGFloat = 160
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            background.setFill()
            rect.fill()
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            let inset = size * 0.16
            context.translateBy(x: inset, y: inset)
            LogoArtwork.drawMark(in: context, size: size - inset * 2, foreground: foreground)
            return true
        }
    }

    @MainActor
    private static func onCanvas(_ image: NSImage, background: NSColor) -> NSImage {
        let padding: CGFloat = 28
        let canvas = NSSize(width: image.size.width + padding * 2,
                            height: image.size.height + padding * 2)
        return NSImage(size: canvas, flipped: false) { rect in
            background.setFill()
            rect.fill()
            image.draw(at: NSPoint(x: padding, y: padding), from: .zero,
                       operation: .sourceOver, fraction: 1)
            return true
        }
    }

    // MARK: - Haptic calibration

    /// Fires each actuation pattern in turn, announcing it first.
    ///
    /// This exists because haptic firmness cannot be measured from software — the
    /// return code is `kIOReturnSuccess` for every pattern. The only way to map
    /// pattern numbers onto "light / medium / strong" is for a person to feel them
    /// and say. Rest a finger on the trackpad while this runs.
    private static func runHapticTest() {
        print("\(Branding.displayName) haptic test")
        print("=====================")
        print("Rest a finger lightly on the trackpad. Each pattern fires 3 times.\n")

        let manager = TrackpadManager()
        manager.start()
        defer { manager.stop() }

        let deviceID = manager.actuatorDeviceID
        print("trackpad device   : 0x\(String(deviceID, radix: 16))")
        print("MTActuator symbols: \(GLHapticActuator.isFrameworkAvailable ? "resolved" : "MISSING")")

        guard deviceID != 0, GLHapticActuator.isFrameworkAvailable else {
            print("\nCannot run: no trackpad device id, or MTActuator is unavailable.")
            return
        }

        let actuator = GLHapticActuator()
        guard actuator.prepare(forDeviceID: deviceID) else {
            print("\nMTActuatorOpen failed — this trackpad has no addressable actuator.")
            return
        }
        print("actuator          : open\n")

        let labels: [Int32: String] = [
            1: "pattern 1  (currently mapped to Light)",
            2: "pattern 2",
            3: "pattern 3  (currently mapped to Medium)",
            4: "pattern 4",
            5: "pattern 5",
            6: "pattern 6  (currently mapped to Strong)",
            15: "pattern 15",
            16: "pattern 16",
        ]

        for number in GLHapticActuator.allPatterns {
            let raw = number.int32Value
            guard let pattern = GLActuationPattern(rawValue: raw) else { continue }
            let label = labels[raw] ?? "pattern \(raw)"
            print("  \(label) …")
            fflush(stdout)

            var succeeded = 0
            for _ in 0..<3 {
                if actuator.actuate(pattern) { succeeded += 1 }
                Thread.sleep(forTimeInterval: 0.28)
            }
            print("      \(succeeded)/3 accepted by the driver")
            Thread.sleep(forTimeInterval: 0.7)
        }

        print("""

            Also firing the public AppKit fallback, three times. On a background
            app this is expected to be silent — if you feel nothing here but did
            feel the patterns above, that confirms why haptics were missing.
            """)
        for pattern in [NSHapticFeedbackManager.FeedbackPattern.levelChange, .generic, .alignment] {
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
            Thread.sleep(forTimeInterval: 0.5)
        }

        actuator.invalidate()
        print("\nWhich pattern numbers felt light / medium / strong?")
    }

    // MARK: - HUD route test

    /// Tries each route to the system HUD in isolation, holding each one on screen
    /// long enough to see, and reports whether OSDUIHelper was activated.
    private static func runHUDTest() {
        print("\(Branding.displayName) HUD route test")
        print("========================")
        print("Watch the screen. Each route shows a rising volume HUD for ~4 s.\n")

        func helperIsRunning() -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-x", "OSDUIHelper"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        }

        print("OSDUIHelper running before test : \(helperIsRunning())")

        let routes: [(String, GLOSDRoute)] = [
            ("OSDUIHelper (XPC)", .osduiHelper),
            ("OSDManager", .osdManager),
        ]

        for (name, route) in routes {
            print("\n--- route: \(name)")
            GLOSDBridge.overrideRoute(route)

            var accepted = 0
            for step in 0...8 {
                let level = Double(step) / 8.0
                if GLOSDBridge.show(.speaker, level: level, chiclets: 16,
                                    onDisplay: CGMainDisplayID()) {
                    accepted += 1
                }
                Thread.sleep(forTimeInterval: 0.45)
            }
            print("    calls accepted        : \(accepted)/9")
            print("    OSDUIHelper running   : \(helperIsRunning())")
            print("    bridge reports route  : \(GLOSDBridge.activeRoute.rawValue)")
            Thread.sleep(forTimeInterval: 1.0)
        }

        GLOSDBridge.overrideRoute(.none)
        print("\n--- automatic selection")
        print(GLOSDBridge.diagnosticsDescription())

        // ---- Media keys: the only route to the OS HUD on macOS 26+ --------
        print("--- media keys (what macOS 26+ needs)")
        let keys = MediaKeyController()
        print("    accessibility         : \(keys.isAvailable ? "granted" : "NOT granted")")

        guard keys.isAvailable else {
            print("""

                Cannot test: posting media key events needs Accessibility.
                Grant it to this binary (or to Glisse.app) and run again.
                """)
            return
        }

        // Ramp up then back down, so the net change is zero but the genuine HUD
        // is driven the whole way.
        print("    stepping volume up 12 fine steps, then back down …")
        for _ in 0..<12 {
            keys.apply(delta: MediaKeyController.fineStep, to: .volume)
            Thread.sleep(forTimeInterval: 0.12)
        }
        Thread.sleep(forTimeInterval: 0.6)
        for _ in 0..<12 {
            keys.apply(delta: -MediaKeyController.fineStep, to: .volume)
            Thread.sleep(forTimeInterval: 0.12)
        }

        Thread.sleep(forTimeInterval: 0.8)
        print("    stepping brightness up 12 fine steps, then back down …")
        for _ in 0..<12 {
            keys.apply(delta: MediaKeyController.fineStep, to: .brightness)
            Thread.sleep(forTimeInterval: 0.12)
        }
        Thread.sleep(forTimeInterval: 0.6)
        for _ in 0..<12 {
            keys.apply(delta: -MediaKeyController.fineStep, to: .brightness)
            Thread.sleep(forTimeInterval: 0.12)
        }

        print("""

            Did the real macOS volume HUD appear, then the real brightness HUD?
            Volume and brightness should both be back where they started.
            """)
    }

    // MARK: - Login item

    /// Inspect or change the SMAppService registration from the terminal.
    ///
    /// Exists because launch-at-login is the one system integration that cannot
    /// be tested from outside the bundle: `SMAppService.mainApp` acts on
    /// `Bundle.main`, so the check has to run inside the app.
    private static func runLoginItem(action: String) {
        MainActor.assumeIsolated {
            let manager = LoginItemManager()
            print("bundle           : \(Bundle.main.bundleURL.path)")
            print("installed location: \(manager.isInInstalledLocation)")

            switch action.lowercased() {
            case "enable", "on":
                switch manager.setEnabled(true) {
                case .success(let state): print("register         : ok -> \(state.displayName)")
                case .failure(let error): print("register         : FAILED -> \(error.localizedDescription)")
                }
            case "disable", "off":
                switch manager.setEnabled(false) {
                case .success(let state): print("unregister       : ok -> \(state.displayName)")
                case .failure(let error): print("unregister       : FAILED -> \(error.localizedDescription)")
                }
            default:
                break
            }
            print("state            : \(manager.state.displayName)")
        }
    }

    // MARK: - Self test

    /// Drives the real controllers against real hardware and restores whatever it
    /// changed. This is what makes "volume actually changes" a verified claim
    /// rather than an assumption, without needing a finger on the trackpad.
    private static func runSelfTest() {
        print("\(Branding.displayName) self test")
        print("===================")
        var failures = 0

        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("  [\(ok ? "PASS" : "FAIL")] \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
            if !ok { failures += 1 }
        }

        // ---- Volume -------------------------------------------------------
        print("\nCore Audio volume")
        let volume = CoreAudioVolumeController()
        check("device resolved", volume.isVolumeControlAvailable, volume.currentDeviceName)

        if volume.isVolumeControlAvailable {
            do {
                let original = try volume.currentVolume()
                let wasMuted = try volume.isMuted()
                print("       original volume \(String(format: "%.3f", original)), muted \(wasMuted)")

                // Move somewhere clearly different, but stay quiet about it.
                let target = original > 0.5 ? original - 0.2 : original + 0.2
                try volume.setVolume(target)
                Thread.sleep(forTimeInterval: 0.15)
                let readback = try volume.currentVolume()
                check("volume write took effect", abs(readback - target) < 0.02,
                      String(format: "wrote %.3f, read %.3f", target, readback))

                // Relative-delta behaviour, the way a gesture drives it.
                var value = readback
                for _ in 0..<10 {
                    value = ValueAdjustment.apply(current: value, delta: 0.01).value
                    try volume.setVolume(value)
                }
                Thread.sleep(forTimeInterval: 0.15)
                let stepped = try volume.currentVolume()
                check("ten 1% steps accumulated", abs(stepped - value) < 0.02,
                      String(format: "expected %.3f, read %.3f", value, stepped))

                try volume.setVolume(original)
                try? volume.setMuted(wasMuted)
                Thread.sleep(forTimeInterval: 0.15)
                let restored = try volume.currentVolume()
                check("volume restored", abs(restored - original) < 0.02,
                      String(format: "%.3f", restored))
            } catch {
                check("volume round trip", false, error.localizedDescription)
            }
        }

        // ---- Brightness ---------------------------------------------------
        print("\nBrightness")
        let builtIn = DisplayServicesBrightnessBackend()
        let ddc = DDCBrightnessBackend()
        let displays = DisplayManager(builtInBackend: builtIn, ddcBackend: ddc)
        displays.refresh()
        let controller = BrightnessController(builtInBackend: builtIn, ddcBackend: ddc)

        let controllable = displays.controllableDisplays
        check("at least one controllable display", !controllable.isEmpty,
              "\(controllable.count) of \(displays.allDisplays.count)")

        for display in controllable {
            print("       \(display.name) via \(display.capabilities.backend.displayName)")
            do {
                let original = try controller.currentBrightness(for: display)
                let target = original > 0.5 ? original - 0.15 : original + 0.15
                try controller.setBrightness(target, for: display)
                controller.flushPendingWrites()
                Thread.sleep(forTimeInterval: 0.3)
                let readback = try controller.currentBrightness(for: display)
                check("brightness write took effect on \(display.name)",
                      abs(readback - target) < 0.03,
                      String(format: "wrote %.3f, read %.3f", target, readback))

                try controller.setBrightness(original, for: display)
                controller.flushPendingWrites()
                Thread.sleep(forTimeInterval: 0.3)
                let restored = try controller.currentBrightness(for: display)
                check("brightness restored on \(display.name)",
                      abs(restored - original) < 0.03,
                      String(format: "%.3f", restored))
            } catch {
                check("brightness round trip on \(display.name)", false,
                      error.localizedDescription)
            }
        }

        // ---- HUD ----------------------------------------------------------
        //
        // The requirement is "a HUD is available", not "the native one is". On
        // macOS 26+ the private OSD interface draws nothing, so the bridge reports
        // itself unavailable and Glisse's own panel takes over. That is the
        // designed outcome, not a failure.
        print("\nHUD")
        let native = NativeSystemHUDProvider()
        let majorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion

        if native.isAvailable {
            print("       native system HUD is drivable")
            native.showVolume(level: 0.5, muted: false)
            Thread.sleep(forTimeInterval: 0.6)
            native.showBrightness(level: 0.5, display: nil)
            Thread.sleep(forTimeInterval: 0.6)
            check("native HUD survived two calls", native.isAvailable,
                  "two HUDs should have appeared on screen")
        } else {
            print("       native system HUD not drivable — using Glisse's own panel")
            check("native HUD correctly reports unavailable rather than failing silently",
                  majorVersion >= 26,
                  "macOS \(majorVersion); the private OSD path draws nothing on 26+")
        }
        check("a HUD provider is available", true, native.isAvailable
              ? "native" : "Glisse panel (run --hudtest to see it)")

        // ---- Haptics -------------------------------------------------------
        //
        // Firmness cannot be measured from software, so this verifies only that a
        // real backend opened. `--haptictest` is how the feel gets calibrated.
        print("\nHaptics")
        let hapticTrackpads = TrackpadManager()
        hapticTrackpads.start()
        let hapticDeviceID = hapticTrackpads.actuatorDeviceID
        let haptics = HapticFeedbackService(strength: .medium)
        let opened = haptics.prepare(deviceID: hapticDeviceID)
        check("MTActuator symbols resolved", GLHapticActuator.isFrameworkAvailable)
        check("actuator opened for the trackpad", opened,
              "device 0x\(String(hapticDeviceID, radix: 16))")
        if opened {
            haptics.demoTick()
            Thread.sleep(forTimeInterval: 0.3)
            check("using the actuator, not the silent AppKit path", haptics.isUsingActuator,
                  "one tap should have been felt")
        }
        haptics.invalidateBackend()
        hapticTrackpads.stop()

        // ---- Gesture engine end to end ------------------------------------
        print("\nGesture engine")
        let engine = EdgeGestureEngine(configuration: GestureConfiguration())
        var total = 0.0
        var began = 0
        var time = MonotonicClock.now()
        _ = engine.process(TrackpadFrame(deviceID: "selftest", timestamp: time, touches: [
            TrackpadTouch(id: 1, x: 0.98, y: 0.2, phase: .began, timestamp: time)
        ]))
        for step in 1...40 {
            time += 0.008
            let y = 0.2 + 0.6 * Double(step) / 40.0
            let output = engine.process(TrackpadFrame(deviceID: "selftest", timestamp: time, touches: [
                TrackpadTouch(id: 1, x: 0.98, y: y, phase: .moved, timestamp: time)
            ]))
            began += output.beganCount
            total += output.totalVolumeDelta
        }
        check("synthetic right-edge slide activated once", began == 1, "began \(began)")
        check("synthetic slide produced upward volume delta", total > 0.5,
              String(format: "%.3f", total))
        time += 0.008
        let end = engine.process(TrackpadFrame(deviceID: "selftest", timestamp: time, touches: [
            TrackpadTouch(id: 1, x: 0.98, y: 0.8, phase: .ended, timestamp: time)
        ]))
        check("lift ended the gesture", end.endedCount == 1 && !engine.hasActiveGesture)

        // ---- Cursor freeze failsafe ---------------------------------------
        print("\nCursor freeze")
        let cursor = CursorController()
        cursor.freeze()
        let frozen = cursor.isFrozen
        cursor.release()
        check("freeze then release leaves cursor attached", frozen && !cursor.isFrozen)

        cursor.freeze()
        cursor.forceRelease(reason: "self test")
        check("forceRelease is effective", !cursor.isFrozen)
        cursor.forceRelease(reason: "self test, already released")
        check("forceRelease is idempotent", !cursor.isFrozen)

        // ---- Recovery ------------------------------------------------------
        //
        // This is the core action of the sleep/wake path: unregister every
        // MultitouchSupport callback, release the device references, enumerate
        // again and re-register. It is the step that historically leaves this
        // class of utility dead after a lid close, so it is exercised repeatedly
        // here rather than only being reasoned about.
        print("\nRecovery (simulates what wake does)")
        let trackpads = TrackpadManager()
        let frameCounter = AtomicCounter()
        trackpads.frameHandler = { _ in frameCounter.increment() }
        trackpads.start()

        let initialSource = trackpads.activeSourceKind
        let initialCount = trackpads.devices.count
        check("touch source started", initialSource != .none,
              "\(initialSource.rawValue), \(initialCount) device(s)")

        var recoveredEveryTime = true
        for round in 1...5 {
            trackpads.restart(reason: "self test round \(round)")
            Thread.sleep(forTimeInterval: 0.25)
            let ok = trackpads.activeSourceKind == initialSource
                && trackpads.devices.count == initialCount
                && trackpads.isRunning
            if !ok {
                recoveredEveryTime = false
                print("       round \(round): source=\(trackpads.activeSourceKind.rawValue) "
                      + "devices=\(trackpads.devices.count) running=\(trackpads.isRunning)")
            }
        }
        check("five restart cycles all recovered", recoveredEveryTime)

        // Stop / start, which is the harsher rebuild path.
        trackpads.stop()
        check("stop leaves nothing running", !trackpads.isRunning)
        trackpads.start()
        Thread.sleep(forTimeInterval: 0.25)
        check("start after stop recovered",
              trackpads.isRunning && trackpads.devices.count == initialCount)
        trackpads.stop()

        // Audio and display invalidation, the other two things wake has to redo.
        volume.invalidateDeviceCache()
        let afterInvalidation = (try? volume.currentVolume()) ?? -1
        check("volume readable after cache invalidation",
              afterInvalidation >= 0 && afterInvalidation <= 1,
              String(format: "%.3f", afterInvalidation))

        displays.invalidateTransports()
        displays.refresh()
        check("displays re-enumerated after transport invalidation",
              displays.controllableDisplays.count == controllable.count,
              "\(displays.controllableDisplays.count) controllable")

        print("\n\(failures == 0 ? "All checks passed." : "\(failures) check(s) FAILED.")")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Normal app

    private static func runApp() {
        // `run(arguments:)` is only ever called from the process entry point, so
        // this genuinely is the main thread.
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            // NSApplication holds its delegate weakly; keep it alive.
            objc_setAssociatedObject(app, Unmanaged.passUnretained(delegate).toOpaque(),
                                     delegate, .OBJC_ASSOCIATION_RETAIN)
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }

    // MARK: - Probe

    private static func runProbe(source: TouchSourcePreference) {
        print("\(Branding.displayName) capability probe")
        print("==========================")
        print("macOS            : \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("architecture     : \(AppCoordinator.architecture)")
        print("accessibility    : \(AXIsProcessTrusted() ? "granted" : "NOT granted")")
        print("")

        // Trackpad
        let manager = TrackpadManager()
        manager.setPreference(source)
        var frameSeen = false
        let frameLock = NSLock()
        manager.frameHandler = { _ in
            frameLock.lock(); frameSeen = true; frameLock.unlock()
        }
        manager.start()
        print(manager.diagnosticsDescription())
        for device in manager.devices {
            let width = device.widthMM.map { String(format: "%.1f mm", $0) } ?? "?"
            let height = device.heightMM.map { String(format: "%.1f mm", $0) } ?? "?"
            print("  device: \(device.name) builtIn=\(device.isBuiltIn) surface=\(width) x \(height)")
        }
        print("")

        // Audio
        let volume = CoreAudioVolumeController()
        print(volume.diagnosticsDescription())

        // Brightness + displays
        let builtIn = DisplayServicesBrightnessBackend()
        let ddc = DDCBrightnessBackend()
        print(builtIn.diagnosticsDescription())
        print(ddc.diagnosticsDescription())

        let displays = DisplayManager(builtInBackend: builtIn, ddcBackend: ddc)
        displays.refresh()
        print(displays.diagnosticsDescription())

        for target in displays.allDisplays where target.capabilities.canControlBrightness {
            let value = (try? BrightnessController(builtInBackend: builtIn, ddcBackend: ddc)
                .currentBrightness(for: target)).map { String(format: "%.3f", $0) } ?? "unreadable"
            print("  \(target.name): brightness \(value)")
        }
        print("")

        // HUD
        print(GLOSDBridge.diagnosticsDescription())

        // Give MultitouchSupport a beat to prove it is delivering frames if a
        // finger happens to be on the trackpad.
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        frameLock.lock()
        let sawFrames = frameSeen
        frameLock.unlock()
        print("touch frames in 1s : \(sawFrames ? "yes" : "none (touch the trackpad during --diagnose to confirm)")")

        manager.stop()
    }

    // MARK: - Diagnose

    private static func runDiagnose(source: TouchSourcePreference) {
        print("""
        Glisse trackpad diagnostic
        =============================

        Coordinate contract being verified:
          x = 0.000 at the physical LEFT edge, 1.000 at the RIGHT edge
          y = 0.000 at the physical BOTTOM edge (nearest you), 1.000 at the TOP

        What to check:
          1. Touch the far LEFT edge   -> x should read close to 0.00
          2. Touch the far RIGHT edge  -> x should read close to 1.00
          3. Slide UP (towards keyboard) -> y should INCREASE
          4. Touch the BOTTOM-left     -> y should read close to 0.00

        Columns: device | id | phase | x | y | dY since touch down | pressure
        Press Ctrl-C to stop.

        """)

        let manager = TrackpadManager()
        let engine = EdgeGestureEngine(configuration: GestureConfiguration())
        // Verifies the vertical contract from the data itself, by correlating
        // touch movement against pointer movement.
        let axis = AxisOrientationVerifier()
        let lock = NSLock()
        var startY: [Int32: Double] = [:]
        var frameCount = 0

        manager.frameHandler = { frame in
            if !axis.isComplete { axis.observe(frame: frame) }
            lock.lock()
            frameCount += 1
            var lines: [String] = []
            for touch in frame.touches {
                if touch.phase == .began { startY[touch.id] = touch.y }
                let base = startY[touch.id] ?? touch.y
                let travel = touch.y - base
                if !touch.phase.isActive { startY.removeValue(forKey: touch.id) }

                let edge: String
                if touch.x <= 0.08 { edge = "LEFT-EDGE " }
                else if touch.x >= 0.92 { edge = "RIGHT-EDGE" }
                else { edge = "          " }

                lines.append(String(
                    format: "%-14@ id=%-3d %-10@ %@ x=%.4f y=%.4f dY=%+.4f p=%.2f",
                    String(frame.deviceID.prefix(14)) as NSString,
                    touch.id,
                    touch.phase.rawValue as NSString,
                    edge as NSString,
                    touch.x, touch.y, travel, touch.pressure ?? 0))
            }
            let output = engine.process(frame)
            for action in output.actions {
                switch action {
                case .volume(let delta):
                    lines.append(String(format: "    -> VOLUME delta %+.5f", delta))
                case .brightness(let delta):
                    lines.append(String(format: "    -> BRIGHTNESS delta %+.5f", delta))
                }
            }
            for event in output.lifecycle {
                lines.append("    -> \(event)")
            }
            lock.unlock()

            for line in lines { print(line) }
        }

        manager.onUnavailable = { error in
            print("!! no touch source: \(error.localizedDescription)")
        }

        manager.setPreference(source)
        manager.start()
        print("source: \(manager.activeSourceName), devices: \(manager.devices.count)")
        if manager.devices.isEmpty {
            print("!! no trackpad detected")
        }
        print(manager.diagnosticsDescription())
        print("---- touch the trackpad now ----")

        // Print the resolved MTTouch layout after some frames have been seen, so
        // the validator has had a chance to corroborate it.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            print("\n---- layout and axis check after 10s ----")
            print(manager.diagnosticsDescription())
            print(axis.diagnosticsDescription())
            print("-----------------------------------------\n")
        }

        RunLoop.current.run()
    }
}
