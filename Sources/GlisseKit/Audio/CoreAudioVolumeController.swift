//
//  CoreAudioVolumeController.swift
//  GlisseKit
//
//  Volume control against the *current* default output device.
//
//  Strategy chain, in order, because no single property works everywhere:
//    1. kAudioHardwareServiceDeviceProperty_VirtualMainVolume ('vmvc')
//       The HAL's own aggregate control. Handles multi-channel devices
//       correctly and is what the system volume keys drive.
//    2. kAudioDevicePropertyVolumeScalar on the main element
//       Some devices expose this but not 'vmvc'.
//    3. kAudioDevicePropertyVolumeScalar per stereo channel
//       Last resort for devices with only per-channel controls; both channels
//       are written together so balance is preserved.
//
//  Measured on macOS 27.0 with the built-in speakers: 'vmvc' and main-element
//  'volm' both present and settable; per-channel elements not supported. Hence
//  the chain rather than picking one.
//
//  No AppleScript, no `osascript`, no shell out. Those cost tens of
//  milliseconds and would be visible as lag on every frame.
//

import AudioToolbox
import CoreAudio
import Foundation

public final class CoreAudioVolumeController: VolumeControlling, @unchecked Sendable {

    // MARK: Property addresses

    private static let virtualMainVolumeSelector = AudioObjectPropertySelector(0x766D_7663)  // 'vmvc'

    private enum Strategy: Equatable {
        case virtualMain
        case mainScalar
        case perChannel([UInt32])
        case unsupported
    }

    private let lock = NSLock()
    private var cachedDevice: AudioDeviceID = kAudioObjectUnknown
    private var cachedStrategy: Strategy = .unsupported
    private var cachedDeviceName: String = "Unknown"

    /// Bumped by the observer; forces a re-resolve on next access.
    private var generation: UInt64 = 0
    private var resolvedGeneration: UInt64 = .max

    public init() {}

    // MARK: Device resolution

    /// Invalidates the cached device. Called by AudioDeviceObserver when the
    /// default output device changes, so a gesture right after switching to
    /// AirPods controls the AirPods and not the vanished speakers.
    public func invalidateDeviceCache() {
        lock.lock()
        generation &+= 1
        lock.unlock()
        Log.audio.info("output device cache invalidated")
    }

    private func resolvedDevice() throws -> (AudioDeviceID, Strategy) {
        lock.lock()
        defer { lock.unlock() }

        if resolvedGeneration == generation, cachedDevice != kAudioObjectUnknown {
            return (cachedDevice, cachedStrategy)
        }

        let device = try Self.defaultOutputDevice()
        let strategy = Self.detectStrategy(for: device)

        cachedDevice = device
        cachedStrategy = strategy
        cachedDeviceName = Self.deviceName(device) ?? "Unknown"
        resolvedGeneration = generation

        Log.audio.info("""
            output device resolved: \(self.cachedDeviceName, privacy: .public) \
            (id \(device, privacy: .public)) strategy \(String(describing: strategy), privacy: .public)
            """)
        return (device, strategy)
    }

    private static func defaultOutputDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)

        guard status == noErr, device != kAudioObjectUnknown else {
            throw AudioControlError.noDefaultOutputDevice
        }
        return device
    }

    private static func detectStrategy(for device: AudioDeviceID) -> Strategy {
        if isSettable(device, virtualMainVolumeSelector, kAudioObjectPropertyElementMain) {
            return .virtualMain
        }
        if isSettable(device, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain) {
            return .mainScalar
        }
        let channels = preferredStereoChannels(device)
        let usable = channels.filter { isSettable(device, kAudioDevicePropertyVolumeScalar, $0) }
        if !usable.isEmpty {
            return .perChannel(usable)
        }
        return .unsupported
    }

    private static func isSettable(_ device: AudioDeviceID,
                                   _ selector: AudioObjectPropertySelector,
                                   _ element: AudioObjectPropertyElement) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: element)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    private static func preferredStereoChannels(_ device: AudioDeviceID) -> [UInt32] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)

        var channels: (UInt32, UInt32) = (1, 2)
        var size = UInt32(MemoryLayout<(UInt32, UInt32)>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &channels)
        guard status == noErr else { return [1, 2] }
        return [channels.0, channels.1]
    }

    private static func deviceName(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return name as String
    }

    // MARK: Scalar access

    private static func scalar(_ device: AudioDeviceID,
                               _ selector: AudioObjectPropertySelector,
                               _ element: AudioObjectPropertyElement) throws -> Double {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: element)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr else {
            throw AudioControlError.osStatus("reading volume", status)
        }
        return clamp01(Double(value))
    }

    private static func setScalar(_ device: AudioDeviceID,
                                  _ selector: AudioObjectPropertySelector,
                                  _ element: AudioObjectPropertyElement,
                                  _ value: Double) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: element)
        var scalarValue = Float32(clamp01(value))
        let size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, size, &scalarValue)
        guard status == noErr else {
            throw AudioControlError.osStatus("writing volume", status)
        }
    }

    // MARK: VolumeControlling

    public var isVolumeControlAvailable: Bool {
        guard let (_, strategy) = try? resolvedDevice() else { return false }
        return strategy != .unsupported
    }

    public var currentDeviceName: String {
        _ = try? resolvedDevice()
        lock.lock()
        defer { lock.unlock() }
        return cachedDeviceName
    }

    public func currentVolume() throws -> Double {
        let (device, strategy) = try resolvedDevice()
        switch strategy {
        case .virtualMain:
            return try Self.scalar(device, Self.virtualMainVolumeSelector, kAudioObjectPropertyElementMain)
        case .mainScalar:
            return try Self.scalar(device, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain)
        case .perChannel(let channels):
            // Report the loudest channel: matches how the system HUD behaves
            // when channels are unbalanced.
            var best = 0.0
            for channel in channels {
                if let value = try? Self.scalar(device, kAudioDevicePropertyVolumeScalar, channel) {
                    best = max(best, value)
                }
            }
            return best
        case .unsupported:
            throw AudioControlError.propertyUnsupported("volume control")
        }
    }

    public func setVolume(_ value: Double) throws {
        let (device, strategy) = try resolvedDevice()
        let target = clamp01(value)

        switch strategy {
        case .virtualMain:
            try Self.setScalar(device, Self.virtualMainVolumeSelector,
                               kAudioObjectPropertyElementMain, target)
        case .mainScalar:
            try Self.setScalar(device, kAudioDevicePropertyVolumeScalar,
                               kAudioObjectPropertyElementMain, target)
        case .perChannel(let channels):
            var lastError: Error?
            for channel in channels {
                do {
                    try Self.setScalar(device, kAudioDevicePropertyVolumeScalar, channel, target)
                } catch {
                    lastError = error
                }
            }
            if let lastError { throw lastError }
        case .unsupported:
            throw AudioControlError.propertyUnsupported("volume control")
        }
    }

    public func isMuted() throws -> Bool {
        let (device, _) = try resolvedDevice()
        guard let muted = Self.readMute(device) else {
            // No mute property: treat as unmuted rather than failing the gesture.
            return false
        }
        return muted
    }

    public func setMuted(_ muted: Bool) throws {
        let (device, _) = try resolvedDevice()
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else {
            throw AudioControlError.propertyUnsupported("mute")
        }
        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(device, &address, 0, nil,
                                               UInt32(MemoryLayout<UInt32>.size), &value)
        guard status == noErr else {
            throw AudioControlError.osStatus("writing mute", status)
        }
    }

    private static func readMute(_ device: AudioDeviceID) -> Bool? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value != 0
    }

    // MARK: Diagnostics

    public func diagnosticsDescription() -> String {
        var text = "Core Audio volume\n"
        do {
            let (device, strategy) = try resolvedDevice()
            text += "  device           : \(currentDeviceName) (id \(device))\n"
            text += "  strategy         : \(strategy)\n"
            text += "  volume           : \(String(format: "%.3f", (try? currentVolume()) ?? -1))\n"
            text += "  muted            : \((try? isMuted()) ?? false)\n"
        } catch {
            text += "  error            : \(error.localizedDescription)\n"
        }
        return text
    }
}
