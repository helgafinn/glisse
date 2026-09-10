//
//  DisplayServicesBrightnessBackend.swift
//  GlisseKit
//
//  Real backlight control for the built-in panel and Apple external displays,
//  via the private DisplayServices bridge.
//
//  This is genuine hardware brightness. Glisse deliberately does *not* fall
//  back to a gamma-ramp trick or a black translucent overlay: those change what
//  the screen looks like without changing the backlight, so they do not save
//  power, they break screenshots and colour-managed work, and they are the
//  reason so many "brightness" utilities feel wrong.
//

import CoreGraphics
import GlissePrivate
import Foundation

public final class DisplayServicesBrightnessBackend: @unchecked Sendable {

    public init() {}

    public static var isAvailable: Bool { GLBrightnessBridge.isAvailable }

    /// Probes what this display supports. Cheap enough to call on display
    /// reconfiguration, too expensive to call per frame — DisplayManager caches
    /// the result.
    public func capabilities(for displayID: CGDirectDisplayID) -> DisplayCapabilities {
        guard GLBrightnessBridge.isAvailable else { return .unsupported }

        let kind = GLBrightnessBridge.preferredBackend(forDisplay: displayID)
        switch kind {
        case .displayServices:
            return DisplayCapabilities(canControlBrightness: true, backend: .displayServices)
        case .coreDisplay:
            return DisplayCapabilities(canControlBrightness: true, backend: .coreDisplay)
        case .ioDisplay:
            return DisplayCapabilities(canControlBrightness: true, backend: .ioDisplay)
        case .none:
            return .unsupported
        @unknown default:
            return .unsupported
        }
    }

    public func currentBrightness(for displayID: CGDirectDisplayID) throws -> Double {
        var value: Double = 0
        guard GLBrightnessBridge.getBrightness(&value, forDisplay: displayID) else {
            throw BrightnessControlError.unsupportedDisplay(displayID)
        }
        return clamp01(value)
    }

    public func setBrightness(_ value: Double, for displayID: CGDirectDisplayID) throws {
        let target = clamp01(value)
        guard GLBrightnessBridge.setBrightness(target, forDisplay: displayID) else {
            throw BrightnessControlError.backendFailed(.displayServices, displayID)
        }
    }

    public func diagnosticsDescription() -> String {
        GLBrightnessBridge.diagnosticsDescription()
    }
}
