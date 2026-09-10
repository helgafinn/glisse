//
//  DisplayManager.swift
//  GlisseKit
//
//  Knows which displays exist and what each one can do.
//
//  Not an actor, on purpose. The gesture pipeline needs a display's capabilities
//  *synchronously* while deciding where to send a brightness delta; awaiting an
//  actor there would add a hop and jitter to the one path that has to stay under
//  ~16 ms. Instead the state is a small dictionary behind an NSLock, and the
//  expensive part (probing DDC, which blocks for ~100 ms per monitor) happens on
//  a dedicated utility queue and only on reconfiguration.
//

import AppKit
import CoreGraphics
import Foundation

public final class DisplayManager: @unchecked Sendable {

    private let lock = NSLock()
    private var targets: [DisplayTarget] = []
    private var mainDisplayID: CGDirectDisplayID = CGMainDisplayID()

    private let builtInBackend: DisplayServicesBrightnessBackend
    private let ddcBackend: DDCBrightnessBackend
    private let probeQueue = DispatchQueue(label: "xyz.glisse.display-probe", qos: .utility)

    private var reconfigurationCallbackInstalled = false
    /// Coalesces the burst of reconfiguration callbacks macOS emits for one
    /// physical change.
    private var reconfigureWorkItem: DispatchWorkItem?

    public var externalDDCEnabled: Bool = true

    /// Called on `probeQueue` after the display set or capabilities changed.
    public var onDisplaysChanged: (() -> Void)?

    public init(builtInBackend: DisplayServicesBrightnessBackend,
                ddcBackend: DDCBrightnessBackend) {
        self.builtInBackend = builtInBackend
        self.ddcBackend = ddcBackend
    }

    deinit {
        if reconfigurationCallbackInstalled {
            CGDisplayRemoveReconfigurationCallback(Self.reconfigurationCallback,
                                                   Unmanaged.passUnretained(self).toOpaque())
        }
    }

    // MARK: Lifecycle

    public func start() {
        installReconfigurationCallback()
        refresh()
    }

    private func installReconfigurationCallback() {
        guard !reconfigurationCallbackInstalled else { return }
        let result = CGDisplayRegisterReconfigurationCallback(
            Self.reconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque())
        reconfigurationCallbackInstalled = (result == .success)
        if !reconfigurationCallbackInstalled {
            Log.brightness.error("could not register for display reconfiguration callbacks")
        }
    }

    private static let reconfigurationCallback: CGDisplayReconfigurationCallBack = {
        _, flags, userInfo in
        guard let userInfo else { return }
        // Only react to changes that can affect brightness control.
        let interesting: CGDisplayChangeSummaryFlags = [
            .addFlag, .removeFlag, .enabledFlag, .disabledFlag,
            .setMainFlag, .beginConfigurationFlag,
        ]
        guard !flags.intersection(interesting).isEmpty else { return }
        let manager = Unmanaged<DisplayManager>.fromOpaque(userInfo).takeUnretainedValue()
        manager.scheduleRefresh()
    }

    /// Debounced: macOS fires several callbacks for a single plug event, and
    /// each refresh probes DDC.
    public func scheduleRefresh(after delay: TimeInterval = 0.75) {
        lock.lock()
        reconfigureWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.refresh()
        }
        reconfigureWorkItem = item
        lock.unlock()
        probeQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Re-enumerates displays and re-probes capabilities. Blocking; runs on
    /// `probeQueue` when triggered by a reconfiguration.
    public func refresh() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else {
            Log.brightness.error("CGGetOnlineDisplayList failed")
            return
        }

        let main = CGMainDisplayID()
        let allowDDC = externalDDCEnabled
        var discovered: [DisplayTarget] = []

        for index in 0..<Int(count) {
            let id = ids[index]
            guard (CGDisplayIsActive(id) != 0) || (CGDisplayIsOnline(id) != 0) else { continue }

            let builtIn = (CGDisplayIsBuiltin(id) != 0)

            var capabilities = builtInBackend.capabilities(for: id)
            if !capabilities.canControlBrightness, !builtIn, allowDDC {
                capabilities = ddcBackend.probeCapabilities(for: id)
            }

            discovered.append(DisplayTarget(
                id: id,
                name: Self.name(for: id, isBuiltIn: builtIn),
                isBuiltIn: builtIn,
                isMain: id == main,
                capabilities: capabilities))
        }

        lock.lock()
        let changed = discovered != targets || main != mainDisplayID
        targets = discovered
        mainDisplayID = main
        lock.unlock()

        if changed {
            Log.brightness.info("""
                displays: \(discovered.map { "\($0.name)#\($0.id)/\($0.capabilities.backend.rawValue)" }
                    .joined(separator: ", "), privacy: .public)
                """)
            onDisplaysChanged?()
        }
    }

    /// Drops DDC channels; needed after wake because I2C endpoints go stale.
    public func invalidateTransports() {
        ddcBackend.invalidate()
    }

    // MARK: Queries (hot path, synchronous)

    public var allDisplays: [DisplayTarget] {
        lock.lock(); defer { lock.unlock() }
        return targets
    }

    public var controllableDisplays: [DisplayTarget] {
        allDisplays.filter { $0.capabilities.canControlBrightness }
    }

    public func display(withID id: CGDirectDisplayID) -> DisplayTarget? {
        lock.lock(); defer { lock.unlock() }
        return targets.first { $0.id == id }
    }

    public var builtInDisplay: DisplayTarget? {
        lock.lock(); defer { lock.unlock() }
        return targets.first { $0.isBuiltIn }
    }

    public var mainDisplay: DisplayTarget? {
        lock.lock(); defer { lock.unlock() }
        let main = mainDisplayID
        return targets.first { $0.id == main } ?? targets.first
    }

    /// Display containing the pointer. Uses the AppKit screen list because
    /// CGDisplay has no "contains point" helper.
    public func displayUnderCursor() -> DisplayTarget? {
        let location = NSEvent.mouseLocation
        for screen in NSScreen.screens where screen.frame.contains(location) {
            if let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                if let target = display(withID: CGDirectDisplayID(number.uint32Value)) {
                    return target
                }
            }
        }
        return mainDisplay
    }

    /// Resolves the user's preference into concrete displays.
    public func resolveTargets(preference: BrightnessTarget,
                               pinnedDisplayID: UInt32?) -> [DisplayTarget] {
        if let pinnedDisplayID, let pinned = display(withID: CGDirectDisplayID(pinnedDisplayID)),
           pinned.capabilities.canControlBrightness {
            return [pinned]
        }

        let controllable = controllableDisplays

        switch preference {
        case .builtIn:
            // Fall back to main so a Mac mini / Magic Trackpad setup is not left
            // with a dead left edge.
            if let builtIn = builtInDisplay, builtIn.capabilities.canControlBrightness {
                return [builtIn]
            }
            return mainControllable(from: controllable)

        case .main:
            return mainControllable(from: controllable)

        case .underCursor:
            if let under = displayUnderCursor(), under.capabilities.canControlBrightness {
                return [under]
            }
            return mainControllable(from: controllable)

        case .allSupported:
            return controllable
        }
    }

    private func mainControllable(from controllable: [DisplayTarget]) -> [DisplayTarget] {
        if let main = mainDisplay, main.capabilities.canControlBrightness { return [main] }
        if let first = controllable.first { return [first] }
        return []
    }

    // MARK: Naming

    private static func name(for id: CGDirectDisplayID, isBuiltIn: Bool) -> String {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  CGDirectDisplayID(number.uint32Value) == id else { continue }
            let name = screen.localizedName
            if !name.isEmpty { return name }
        }
        return isBuiltIn ? "Built-in Display" : "Display \(id)"
    }

    // MARK: Diagnostics

    public func diagnosticsDescription() -> String {
        var text = "Displays\n"
        for target in allDisplays {
            text += "  - \(target.name) (id \(target.id))"
            text += target.isBuiltIn ? " [built-in]" : ""
            text += target.isMain ? " [main]" : ""
            text += "\n      backend: \(target.capabilities.backend.displayName)"
            text += ", controllable: \(target.capabilities.canControlBrightness)"
            if let maximum = target.capabilities.ddcMaximum {
                text += ", VCP max: \(maximum)"
            }
            if let strategy = target.capabilities.ddcMatchStrategy {
                text += ", match: \(strategy)"
            }
            text += "\n"
        }
        return text
    }
}
