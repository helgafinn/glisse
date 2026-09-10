//
//  BrightnessController.swift
//  GlisseKit
//
//  Routes brightness reads and writes to whichever backend a display actually
//  supports, and keeps slow displays off the gesture thread.
//
//  Timing model:
//    * DisplayServices writes are fast (measured well under a millisecond) and
//      happen synchronously so the panel tracks the finger.
//    * DDC writes take tens of milliseconds and are pushed onto a serial queue
//      with trailing-edge coalescing, so a monitor sees a handful of writes
//      during a sweep and always lands on the final value.
//

import CoreGraphics
import Foundation

public protocol BrightnessControlling: AnyObject {
    func currentBrightness(for display: DisplayTarget) throws -> Double
    func setBrightness(_ value: Double, for display: DisplayTarget) throws
}

public final class BrightnessController: BrightnessControlling, @unchecked Sendable {

    private let builtInBackend: DisplayServicesBrightnessBackend
    private let ddcBackend: DDCBrightnessBackend

    /// Serialises I2C. Monitors cannot handle concurrent transactions and two
    /// displays on one bus will corrupt each other's replies.
    private let ddcQueue = DispatchQueue(label: "xyz.glisse.ddc", qos: .userInitiated)
    private let ddcCoalescers: NSMapTable<NSNumber, Coalescer> = .strongToStrongObjects()
    private let coalescerLock = NSLock()

    /// Cached last-known value per display so a gesture does not have to read
    /// hardware on every frame (a DDC read is ~50 ms).
    private let cacheLock = NSLock()
    private var valueCache: [CGDirectDisplayID: Double] = [:]

    public init(builtInBackend: DisplayServicesBrightnessBackend,
                ddcBackend: DDCBrightnessBackend) {
        self.builtInBackend = builtInBackend
        self.ddcBackend = ddcBackend
    }

    // MARK: Read

    public func currentBrightness(for display: DisplayTarget) throws -> Double {
        switch display.capabilities.backend {
        case .displayServices, .coreDisplay, .ioDisplay:
            let value = try builtInBackend.currentBrightness(for: display.id)
            store(value, for: display.id)
            return value

        case .ddc:
            // Prefer the cache: reading DDC mid-gesture would stall for ~50 ms.
            if let cached = cached(for: display.id) { return cached }
            let value = try ddcBackend.currentBrightness(for: display.id)
            store(value, for: display.id)
            return value

        case .unsupported:
            throw BrightnessControlError.unsupportedDisplay(display.id)
        }
    }

    /// Value to start a gesture from. Never throws: a gesture must not die
    /// because a monitor was slow, so an unknown value becomes 0.5.
    public func brightnessForGestureStart(_ display: DisplayTarget) -> Double {
        if let value = try? currentBrightness(for: display) { return value }
        return cached(for: display.id) ?? 0.5
    }

    // MARK: Write

    public func setBrightness(_ value: Double, for display: DisplayTarget) throws {
        let target = clamp01(value)
        store(target, for: display.id)

        switch display.capabilities.backend {
        case .displayServices, .coreDisplay, .ioDisplay:
            try builtInBackend.setBrightness(target, for: display.id)

        case .ddc:
            // Fire and forget with coalescing. The gesture thread must not wait
            // on I2C.
            coalescer(for: display.id).submit { [weak self] in
                guard let self else { return }
                do {
                    try self.ddcBackend.setBrightness(target, for: display.id)
                } catch {
                    Log.diagnostic(Log.ddc, "DDC write failed for \(display.id): \(error.localizedDescription)")
                }
            }

        case .unsupported:
            throw BrightnessControlError.unsupportedDisplay(display.id)
        }
    }

    /// Called when a gesture ends: makes sure the last coalesced DDC write lands
    /// instead of being cancelled.
    public func flushPendingWrites() {
        coalescerLock.lock()
        let enumerator = ddcCoalescers.objectEnumerator()
        var pending: [Coalescer] = []
        while let object = enumerator?.nextObject() as? Coalescer {
            pending.append(object)
        }
        coalescerLock.unlock()
        pending.forEach { $0.flush() }
    }

    /// Primes the de-duplication caches at the start of a gesture.
    public func prepareForGesture(on displays: [DisplayTarget]) {
        for display in displays where display.capabilities.backend == .ddc {
            let value = brightnessForGestureStart(display)
            ddcBackend.primeCache(displayID: display.id, normalizedValue: value)
        }
    }

    public func invalidateCaches() {
        cacheLock.lock()
        valueCache.removeAll()
        cacheLock.unlock()

        coalescerLock.lock()
        let enumerator = ddcCoalescers.objectEnumerator()
        var pending: [Coalescer] = []
        while let object = enumerator?.nextObject() as? Coalescer {
            pending.append(object)
        }
        ddcCoalescers.removeAllObjects()
        coalescerLock.unlock()
        pending.forEach { $0.cancel() }
    }

    // MARK: Helpers

    private func coalescer(for displayID: CGDirectDisplayID) -> Coalescer {
        coalescerLock.lock()
        defer { coalescerLock.unlock() }
        let key = NSNumber(value: displayID)
        if let existing = ddcCoalescers.object(forKey: key) {
            return existing
        }
        // 18 ms: fast enough to feel live, slow enough that a monitor sees at
        // most ~55 writes a second even during a frantic sweep.
        let created = Coalescer(interval: 0.018, queue: ddcQueue)
        ddcCoalescers.setObject(created, forKey: key)
        return created
    }

    private func cached(for displayID: CGDirectDisplayID) -> Double? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return valueCache[displayID]
    }

    private func store(_ value: Double, for displayID: CGDirectDisplayID) {
        cacheLock.lock()
        valueCache[displayID] = value
        cacheLock.unlock()
    }
}
