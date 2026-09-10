//
//  TrackpadTouch.swift
//  GlisseKit
//
//  Canonical touch model. Every touch source normalises into this, so the
//  gesture engine never has to know whether the data came from
//  MultitouchSupport or from AppKit.
//
//  COORDINATE CONTRACT — this is the thing that must not be guessed:
//
//    x: 0 at the physical LEFT edge, 1 at the physical RIGHT edge.
//    y: 0 at the physical BOTTOM edge (nearest the user / the click hinge),
//       1 at the physical TOP edge (nearest the keyboard).
//
//  So "slide finger up" means y increasing. This matches AppKit's documented
//  `NSTouch.normalizedPosition` (origin lower-left) and matches what
//  MultitouchSupport reports. `AppSettings.invertVerticalAxis` exists as an
//  escape hatch if a device ever disagrees.
//

import Foundation

public enum TouchPhase: String, Sendable, Equatable, CaseIterable {
    case began
    case moved
    case stationary
    case ended
    case cancelled

    /// True while the finger is still on the surface.
    public var isActive: Bool {
        switch self {
        case .began, .moved, .stationary: return true
        case .ended, .cancelled:          return false
        }
    }
}

public struct TrackpadTouch: Sendable, Equatable {
    /// Stable for the life of one contact on one device.
    public let id: Int32
    /// 0...1, left to right.
    public let x: Double
    /// 0...1, bottom to top.
    public let y: Double
    public let phase: TouchPhase
    /// Arbitrary units, nil when the source does not report it.
    public let pressure: Double?
    public let timestamp: TimeInterval

    public init(id: Int32,
                x: Double,
                y: Double,
                phase: TouchPhase,
                pressure: Double? = nil,
                timestamp: TimeInterval) {
        self.id = id
        self.x = clamp01(x)
        self.y = clamp01(y)
        self.phase = phase
        self.pressure = pressure
        self.timestamp = timestamp
    }
}

public struct TrackpadFrame: Sendable, Equatable {
    /// Which physical device. Sessions are keyed on this so a Magic Trackpad
    /// and the built-in trackpad never share gesture state.
    public let deviceID: String
    public let timestamp: TimeInterval
    public let touches: [TrackpadTouch]

    public init(deviceID: String, timestamp: TimeInterval, touches: [TrackpadTouch]) {
        self.deviceID = deviceID
        self.timestamp = timestamp
        self.touches = touches
    }

    /// Touches still on the surface.
    public var activeTouches: [TrackpadTouch] {
        touches.filter { $0.phase.isActive }
    }
}

// MARK: - Device description

public struct TrackpadDevice: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let isBuiltIn: Bool
    /// Raw `MTDeviceGetDeviceID` value; 0 when the source cannot supply one.
    /// Needed because MTActuator is addressed by device id, not by our string key.
    public let numericID: UInt64
    /// Physical surface in millimetres where known; used only for diagnostics.
    public let widthMM: Double?
    public let heightMM: Double?

    public init(id: String,
                name: String,
                isBuiltIn: Bool,
                numericID: UInt64 = 0,
                widthMM: Double?,
                heightMM: Double?) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.numericID = numericID
        self.widthMM = widthMM
        self.heightMM = heightMM
    }
}

// MARK: - Errors

public enum TrackpadError: LocalizedError, Equatable {
    case noSourceAvailable(String)
    case multitouchUnavailable(String)
    case noDevicesFound
    case eventTapCreationFailed
    case accessibilityRequired

    public var errorDescription: String? {
        switch self {
        case .noSourceAvailable(let detail):
            return "No trackpad touch source is available. \(detail)"
        case .multitouchUnavailable(let detail):
            return "MultitouchSupport is unavailable: \(detail)"
        case .noDevicesFound:
            return "No multitouch trackpad was found."
        case .eventTapCreationFailed:
            return "Could not create the touch event tap."
        case .accessibilityRequired:
            return "Accessibility permission is required for the fallback touch source."
        }
    }
}
