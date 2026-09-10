//
//  DisplayTarget.swift
//  GlisseKit
//

import CoreGraphics
import Foundation

public enum DisplayBackend: String, Sendable, Equatable {
    /// Private DisplayServices — the working path for the built-in panel and
    /// Apple external displays.
    case displayServices
    /// CoreDisplay user-brightness. Only used where it has been cross-checked
    /// against DisplayServices and agrees.
    case coreDisplay
    /// IODisplay float parameter. Intel-era built-in panels.
    case ioDisplay
    /// DDC/CI over I2C. Third-party external monitors.
    case ddc
    case unsupported

    public var displayName: String {
        switch self {
        case .displayServices: return "DisplayServices"
        case .coreDisplay:     return "CoreDisplay"
        case .ioDisplay:       return "IODisplay"
        case .ddc:             return "DDC/CI"
        case .unsupported:     return "Unsupported"
        }
    }
}

public struct DisplayCapabilities: Sendable, Equatable {
    public let canControlBrightness: Bool
    public let backend: DisplayBackend
    /// Native VCP maximum for DDC displays. Never assume 100.
    public let ddcMaximum: UInt16?
    /// How the DDC channel was matched to this display, when applicable.
    public let ddcMatchStrategy: String?

    public static let unsupported = DisplayCapabilities(
        canControlBrightness: false,
        backend: .unsupported,
        ddcMaximum: nil,
        ddcMatchStrategy: nil)

    public init(canControlBrightness: Bool,
                backend: DisplayBackend,
                ddcMaximum: UInt16? = nil,
                ddcMatchStrategy: String? = nil) {
        self.canControlBrightness = canControlBrightness
        self.backend = backend
        self.ddcMaximum = ddcMaximum
        self.ddcMatchStrategy = ddcMatchStrategy
    }
}

public struct DisplayTarget: Sendable, Equatable, Identifiable, Hashable {
    public let id: CGDirectDisplayID
    public let name: String
    public let isBuiltIn: Bool
    public let isMain: Bool
    public let capabilities: DisplayCapabilities

    public init(id: CGDirectDisplayID,
                name: String,
                isBuiltIn: Bool,
                isMain: Bool,
                capabilities: DisplayCapabilities) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.isMain = isMain
        self.capabilities = capabilities
    }

    public static func == (lhs: DisplayTarget, rhs: DisplayTarget) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

public enum BrightnessControlError: LocalizedError, Equatable {
    case unsupportedDisplay(CGDirectDisplayID)
    case backendFailed(DisplayBackend, CGDirectDisplayID)
    case noTargetDisplay

    public var errorDescription: String? {
        switch self {
        case .unsupportedDisplay(let id):
            return "Display \(id) does not support brightness control."
        case .backendFailed(let backend, let id):
            return "\(backend.displayName) failed for display \(id)."
        case .noTargetDisplay:
            return "No display is available for brightness control."
        }
    }
}

public enum DDCError: LocalizedError, Equatable {
    case transportUnavailable
    case noChannel(CGDirectDisplayID)
    case readFailed(CGDirectDisplayID)
    case writeFailed(CGDirectDisplayID)
    case circuitOpen(CGDirectDisplayID)

    public var errorDescription: String? {
        switch self {
        case .transportUnavailable:
            return "No DDC/CI transport is available on this machine."
        case .noChannel(let id):
            return "No DDC/CI channel could be opened for display \(id)."
        case .readFailed(let id):
            return "Display \(id) did not answer a DDC/CI read."
        case .writeFailed(let id):
            return "Display \(id) rejected a DDC/CI write."
        case .circuitOpen(let id):
            return "DDC/CI is temporarily suspended for display \(id) after repeated failures."
        }
    }
}
