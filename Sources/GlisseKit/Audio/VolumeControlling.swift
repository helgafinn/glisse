//
//  VolumeControlling.swift
//  GlisseKit
//

import Foundation

public enum AudioControlError: LocalizedError, Equatable {
    case noDefaultOutputDevice
    case propertyUnsupported(String)
    case osStatus(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .noDefaultOutputDevice:
            return "There is no default audio output device."
        case .propertyUnsupported(let what):
            return "The current output device does not support \(what)."
        case .osStatus(let what, let code):
            return "Core Audio rejected \(what) (OSStatus \(code))."
        }
    }
}

public protocol VolumeControlling: AnyObject {
    func currentVolume() throws -> Double
    func setVolume(_ value: Double) throws
    func isMuted() throws -> Bool
    func setMuted(_ muted: Bool) throws

    /// False when the active output device exposes no volume control at all
    /// (some HDMI sinks and aggregate devices). Lets the UI say so instead of
    /// silently doing nothing.
    var isVolumeControlAvailable: Bool { get }

    /// Human-readable name of the device currently being controlled.
    var currentDeviceName: String { get }
}
