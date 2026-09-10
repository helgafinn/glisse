//
//  DDCBrightnessBackend.swift
//  GlisseKit
//
//  External-monitor brightness over DDC/CI (VCP 0x10).
//
//  Monitors are the least reliable thing this app talks to. Docks, HDMI
//  adapters, DisplayLink, long cables and sleeping panels all produce silent
//  failures, and a monitor that is NAKing every request must not be hammered at
//  trackpad-frame frequency. Three protections, all here:
//
//    1. Capability probe once per display, cached. If the monitor never answers
//       a VCP 0x10 read it is marked unsupported and left alone.
//    2. Native maximum is read from the monitor, not assumed to be 100.
//    3. Circuit breaker: consecutive failures open the circuit for a cooling
//       period, then allow a single trial write. Repeated failure re-opens it
//       with a longer delay.
//
//  Writes are coalesced by DDCScheduler, never issued from the gesture thread.
//

import CoreGraphics
import GlissePrivate
import Foundation

public final class DDCBrightnessBackend: @unchecked Sendable {

    /// VCP feature code for luminance.
    private static let vcpBrightness: UInt8 = 0x10

    private struct CircuitState {
        var consecutiveFailures = 0
        var openedUntil: TimeInterval = 0
        var backoffIndex = 0
    }

    /// Exponential-ish cooling periods. Capped so a monitor that recovers after
    /// a dock reconnect is retried within a minute rather than never.
    private static let backoffSchedule: [TimeInterval] = [2, 5, 15, 30, 60]
    private static let failuresBeforeOpening = 3

    private let lock = NSLock()
    private var circuits: [CGDirectDisplayID: CircuitState] = [:]
    /// Last value written, per display. Used to skip redundant writes.
    private var lastWritten: [CGDirectDisplayID: UInt16] = [:]
    private var cachedMaximum: [CGDirectDisplayID: UInt16] = [:]

    public init() {}

    public static var isAvailable: Bool { GLDDCBridge.isAvailable }

    // MARK: Capability probe

    /// Blocking; can take ~100 ms per monitor. Call off the main thread.
    public func probeCapabilities(for displayID: CGDirectDisplayID) -> DisplayCapabilities {
        guard GLDDCBridge.isAvailable else { return .unsupported }
        guard !(CGDisplayIsBuiltin(displayID) != 0) else { return .unsupported }
        guard let link = GLDDCLink.makeLink(display: displayID) else {
            Log.ddc.info("no DDC channel for display \(displayID, privacy: .public)")
            return .unsupported
        }

        var current: UInt16 = 0
        var maximum: UInt16 = 0

        // Monitors commonly ignore the first request after waking.
        for attempt in 0..<3 {
            if link.readVCPCode(Self.vcpBrightness, outCurrent: &current, outMax: &maximum) {
                guard maximum > 0 else { continue }
                lock.lock()
                cachedMaximum[displayID] = maximum
                lock.unlock()
                Log.ddc.info("""
                    display \(displayID, privacy: .public) supports DDC brightness \
                    (current \(current, privacy: .public)/\(maximum, privacy: .public), \
                    match \(link.matchStrategy, privacy: .public))
                    """)
                return DisplayCapabilities(canControlBrightness: true,
                                           backend: .ddc,
                                           ddcMaximum: maximum,
                                           ddcMatchStrategy: link.matchStrategy)
            }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.05) }
        }

        Log.ddc.info("display \(displayID, privacy: .public) did not answer DDC VCP 0x10")
        return .unsupported
    }

    // MARK: Read

    public func currentBrightness(for displayID: CGDirectDisplayID) throws -> Double {
        guard let link = GLDDCLink.makeLink(display: displayID) else {
            throw DDCError.noChannel(displayID)
        }
        var current: UInt16 = 0
        var maximum: UInt16 = 0
        guard link.readVCPCode(Self.vcpBrightness, outCurrent: &current, outMax: &maximum),
              maximum > 0 else {
            noteFailure(displayID)
            throw DDCError.readFailed(displayID)
        }
        noteSuccess(displayID)
        lock.lock(); cachedMaximum[displayID] = maximum; lock.unlock()
        return DDCScaling.normalized(native: current, maximum: maximum)
    }

    // MARK: Write

    /// Blocking. Call from DDCScheduler's queue only.
    public func setBrightness(_ value: Double, for displayID: CGDirectDisplayID) throws {
        guard isCircuitClosed(displayID) else {
            throw DDCError.circuitOpen(displayID)
        }
        guard let link = GLDDCLink.makeLink(display: displayID) else {
            noteFailure(displayID)
            throw DDCError.noChannel(displayID)
        }

        lock.lock()
        let maximum = cachedMaximum[displayID] ?? 100
        let previous = lastWritten[displayID]
        lock.unlock()

        let native = DDCScaling.native(normalized: value, maximum: maximum)

        // De-duplicate: no point telling a monitor to stay where it is.
        if let previous, previous == native {
            return
        }

        guard link.writeVCPCode(Self.vcpBrightness, value: native) else {
            noteFailure(displayID)
            throw DDCError.writeFailed(displayID)
        }

        lock.lock(); lastWritten[displayID] = native; lock.unlock()
        noteSuccess(displayID)
    }

    /// Seeds the de-duplication cache so the first write of a gesture is not
    /// skipped and does not have to re-read the monitor.
    public func primeCache(displayID: CGDirectDisplayID, normalizedValue: Double) {
        lock.lock()
        let maximum = cachedMaximum[displayID] ?? 100
        lastWritten[displayID] = DDCScaling.native(normalized: normalizedValue, maximum: maximum)
        lock.unlock()
    }

    // MARK: Circuit breaker

    private func isCircuitClosed(_ displayID: CGDirectDisplayID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let state = circuits[displayID] else { return true }
        if state.openedUntil == 0 { return true }
        return MonotonicClock.now() >= state.openedUntil
    }

    private func noteSuccess(_ displayID: CGDirectDisplayID) {
        lock.lock()
        if var state = circuits[displayID], state.consecutiveFailures > 0 || state.openedUntil > 0 {
            state.consecutiveFailures = 0
            state.openedUntil = 0
            state.backoffIndex = 0
            circuits[displayID] = state
            lock.unlock()
            Log.ddc.info("display \(displayID, privacy: .public) DDC recovered")
            return
        }
        lock.unlock()
    }

    private func noteFailure(_ displayID: CGDirectDisplayID) {
        lock.lock()
        var state = circuits[displayID] ?? CircuitState()
        state.consecutiveFailures += 1

        var opened = false
        if state.consecutiveFailures >= Self.failuresBeforeOpening {
            let delay = Self.backoffSchedule[min(state.backoffIndex, Self.backoffSchedule.count - 1)]
            state.openedUntil = MonotonicClock.now() + delay
            state.backoffIndex = min(state.backoffIndex + 1, Self.backoffSchedule.count - 1)
            state.consecutiveFailures = 0
            opened = true
        }
        circuits[displayID] = state
        let backoff = state.backoffIndex
        lock.unlock()

        if opened {
            Log.ddc.warning("""
                display \(displayID, privacy: .public) DDC suspended after repeated failures \
                (backoff step \(backoff, privacy: .public))
                """)
        }
    }

    /// Called on wake and display reconfiguration: drop channels and let the
    /// circuit breaker start fresh.
    public func invalidate() {
        GLDDCBridge.invalidateAllLinks()
        lock.lock()
        circuits.removeAll()
        lastWritten.removeAll()
        cachedMaximum.removeAll()
        lock.unlock()
        Log.ddc.info("DDC links invalidated")
    }

    public func diagnosticsDescription() -> String {
        var text = GLDDCBridge.diagnosticsDescription()
        lock.lock()
        let circuitCount = circuits.filter { $0.value.openedUntil > MonotonicClock.now() }.count
        let maxima = cachedMaximum
        lock.unlock()
        text += "  suspended links  : \(circuitCount)\n"
        for (id, maximum) in maxima.sorted(by: { $0.key < $1.key }) {
            text += "  display \(id) VCP max: \(maximum)\n"
        }
        return text
    }
}
