//
//  AudioDeviceObserver.swift
//  GlisseKit
//
//  Watches for the default output device changing (speakers -> AirPods -> HDMI)
//  and for the device list changing, so the volume controller never writes to a
//  stale AudioDeviceID.
//
//  Event driven: no polling, nothing scheduled while idle.
//

import CoreAudio
import Foundation

public final class AudioDeviceObserver {

    private let queue = DispatchQueue(label: "xyz.glisse.audio-observer", qos: .utility)
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var isObserving = false

    /// Called on `queue` whenever the active output device may have changed.
    public var onOutputDeviceChanged: (() -> Void)?

    public init() {}

    deinit {
        stop()
    }

    public func start() {
        guard !isObserving else { return }
        isObserving = true

        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDefaultOutputDevice,
            // Covers a device disappearing while it is the default, and new
            // devices appearing that macOS then auto-selects.
            kAudioHardwarePropertyDevices,
        ]

        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)

            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.onOutputDeviceChanged?()
            }

            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, block)

            if status == noErr {
                listeners.append((address, block))
            } else {
                Log.audio.error("failed to observe audio property \(selector, privacy: .public): \(status, privacy: .public)")
            }
        }

        Log.audio.info("audio device observer started (\(self.listeners.count, privacy: .public) listeners)")
    }

    public func stop() {
        for (address, block) in listeners {
            var mutableAddress = address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &mutableAddress, queue, block)
        }
        listeners.removeAll()
        isObserving = false
    }
}
