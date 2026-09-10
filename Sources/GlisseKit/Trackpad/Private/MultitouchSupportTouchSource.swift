//
//  MultitouchSupportTouchSource.swift
//  GlisseKit
//
//  Swift face of the MultitouchSupport bridge. Converts raw MT states into
//  `TouchPhase` and raw contacts into the canonical coordinate space.
//
//  Everything unsafe stays in GlissePrivate; this file only maps values.
//

import GlissePrivate
import Foundation

public final class MultitouchSupportTouchSource: TouchSource {

    public let identifier = "MultitouchSupport"

    private let bridge = GLMultitouchBridge()

    /// Phase derivation needs memory: MultitouchSupport reports a *state* per
    /// contact, not a phase, so "began" is "a state I had not seen for this id".
    private let lock = NSLock()
    private var knownTouchIDs: [String: Set<Int32>] = [:]

    public var frameHandler: ((TrackpadFrame) -> Void)?
    public var failureHandler: ((TrackpadError) -> Void)?

    public static var isAvailable: Bool { GLMultitouchBridge.isFrameworkAvailable }
    public static var unavailableReason: String { GLMultitouchBridge.unavailableReason }

    public init() {
        bridge.frameHandler = { [weak self] deviceKey, _, timestamp, touches, count in
            self?.handle(deviceKey: deviceKey, timestamp: timestamp, touches: touches, count: count)
        }
        bridge.layoutFailureHandler = { [weak self] in
            guard let self else { return }
            Log.trackpad.error("MTTouch layout could not be parsed; switching to the AppKit touch source")
            self.failureHandler?(.multitouchUnavailable("MTTouch byte layout not recognised on this macOS build"))
        }
    }

    deinit {
        bridge.frameHandler = nil
        bridge.layoutFailureHandler = nil
        bridge.stop()
    }

    // MARK: TouchSource

    public var isRunning: Bool { bridge.isRunning }

    public var devices: [TrackpadDevice] {
        bridge.devices.map { info in
            TrackpadDevice(
                id: info.key,
                name: info.displayName,
                isBuiltIn: info.isBuiltIn,
                numericID: info.deviceID,
                // The framework reports the sensor surface in hundredths of a
                // millimetre.
                widthMM: info.surfaceWidth > 0 ? Double(info.surfaceWidth) / 100.0 : nil,
                heightMM: info.surfaceHeight > 0 ? Double(info.surfaceHeight) / 100.0 : nil
            )
        }
    }

    public func start() throws {
        guard Self.isAvailable else {
            throw TrackpadError.multitouchUnavailable(Self.unavailableReason)
        }
        // `-startAndReturnError:` is imported as a throwing call.
        do {
            try bridge.start()
        } catch {
            throw TrackpadError.multitouchUnavailable(error.localizedDescription)
        }
        lock.lock(); knownTouchIDs.removeAll(); lock.unlock()
        Log.trackpad.info("MultitouchSupport started with \(self.bridge.devices.count, privacy: .public) device(s)")
    }

    public func stop() {
        bridge.stop()
        lock.lock(); knownTouchIDs.removeAll(); lock.unlock()
    }

    public func restart() throws {
        defer { lock.lock(); knownTouchIDs.removeAll(); lock.unlock() }
        do {
            try bridge.restart()
        } catch {
            throw TrackpadError.multitouchUnavailable(error.localizedDescription)
        }
        Log.trackpad.info("MultitouchSupport restarted with \(self.bridge.devices.count, privacy: .public) device(s)")
    }

    public func diagnosticsDescription() -> String {
        var text = bridge.diagnosticsDescription()
        let dump = bridge.lastFrameHexDump()
        if !dump.isEmpty {
            text += "\n" + dump
        }
        return text
    }

    // MARK: Conversion

    private func handle(deviceKey: String,
                        timestamp: TimeInterval,
                        touches: UnsafePointer<GLRawTouch>?,
                        count: Int) {
        guard let handler = frameHandler else { return }

        var converted: [TrackpadTouch] = []
        converted.reserveCapacity(max(count, 4))

        var seen = Set<Int32>()
        seen.reserveCapacity(max(count, 4))

        lock.lock()
        var known = knownTouchIDs[deviceKey] ?? []

        if let touches, count > 0 {
            for index in 0..<count {
                let raw = touches[index]
                let onSurface = GLMTTouchStateIsTouching(raw.state)

                if onSurface {
                    let phase: TouchPhase
                    if known.contains(raw.identifier) {
                        phase = .moved
                    } else {
                        phase = .began
                        known.insert(raw.identifier)
                    }
                    seen.insert(raw.identifier)
                    converted.append(TrackpadTouch(id: raw.identifier,
                                                   x: raw.x,
                                                   y: raw.y,
                                                   phase: phase,
                                                   pressure: raw.pressure,
                                                   timestamp: raw.timestamp))
                } else if known.contains(raw.identifier) {
                    // Hovering / breaking contact / out of range: the finger has
                    // left the surface as far as Glisse is concerned.
                    known.remove(raw.identifier)
                    converted.append(TrackpadTouch(id: raw.identifier,
                                                   x: raw.x,
                                                   y: raw.y,
                                                   phase: .ended,
                                                   pressure: raw.pressure,
                                                   timestamp: raw.timestamp))
                }
            }
        }

        // Any id we believed was down but that is absent from this frame has
        // been lifted. MultitouchSupport does not guarantee a final frame per
        // contact, so this is the reliable signal.
        let vanished = known.subtracting(seen)
        if !vanished.isEmpty {
            for id in vanished {
                converted.append(TrackpadTouch(id: id,
                                               x: 0,
                                               y: 0,
                                               phase: .ended,
                                               pressure: nil,
                                               timestamp: timestamp))
            }
            known.subtract(vanished)
        }

        knownTouchIDs[deviceKey] = known.isEmpty ? nil : known
        lock.unlock()

        // An entirely empty frame with nothing to retire carries no information.
        guard !converted.isEmpty else { return }

        handler(TrackpadFrame(deviceID: deviceKey, timestamp: timestamp, touches: converted))
    }
}
