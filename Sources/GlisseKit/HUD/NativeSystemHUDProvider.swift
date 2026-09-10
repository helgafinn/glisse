//
//  NativeSystemHUDProvider.swift
//  GlisseKit
//
//  Drives the real macOS volume / brightness HUD through the private OSD
//  framework. This is what makes Glisse feel like part of the system rather
//  than a third-party overlay.
//
//  Availability is re-checked, not assumed: if `OSDManager` stops answering the
//  app switches to the media-key mechanism without interrupting the gesture.
//

import CoreGraphics
import GlissePrivate
import Foundation

public final class NativeSystemHUDProvider: SystemHUDProviding, @unchecked Sendable {

    public let name = "Native macOS HUD"

    /// 16 segments is what the system itself uses, so the HUD looks identical to
    /// pressing the volume keys.
    private let chicletCount = 16

    private let lock = NSLock()
    private var consecutiveFailures = 0
    /// After this many failures the provider declares itself unavailable and the
    /// coordinator swaps in the fallback.
    private let failureLimit = 3

    public init() {}

    public var isAvailable: Bool {
        guard GLOSDBridge.isAvailable else { return false }
        lock.lock(); defer { lock.unlock() }
        return consecutiveFailures < failureLimit
    }

    public func showVolume(level: Double, muted: Bool) {
        let graphic: GLOSDGraphic = muted ? .speakerMuted : .speaker
        // A muted device still shows its level so the user can see where the
        // slider is sitting, which is what the system does.
        show(graphic: graphic, level: level, display: nil)
    }

    public func showBrightness(level: Double, display: CGDirectDisplayID?) {
        show(graphic: .brightness, level: level, display: display)
    }

    private func show(graphic: GLOSDGraphic, level: Double, display: CGDirectDisplayID?) {
        let targetDisplay = display ?? CGMainDisplayID()
        let ok = GLOSDBridge.show(graphic,
                                  level: clamp01(level),
                                  chiclets: chicletCount,
                                  onDisplay: targetDisplay)
        lock.lock()
        if ok {
            consecutiveFailures = 0
        } else {
            consecutiveFailures += 1
        }
        let failures = consecutiveFailures
        lock.unlock()

        if !ok, failures == failureLimit {
            Log.hud.error("native HUD failed \(failures, privacy: .public) times; falling back")
        }
    }

    public func invalidateConnections() {
        GLOSDBridge.invalidateConnections()
        lock.lock(); consecutiveFailures = 0; lock.unlock()
    }

    public var activeRouteName: String {
        switch GLOSDBridge.activeRoute {
        case .osduiHelper: return "OSDUIHelper (XPC)"
        case .osdManager:  return "OSDManager"
        case .none:        return "none"
        @unknown default:  return "unknown"
        }
    }

    public func diagnosticsDescription() -> String {
        GLOSDBridge.diagnosticsDescription()
    }
}
