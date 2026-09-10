//
//  AppKitTouchSource.swift
//  GlisseKit
//
//  Public-API fallback touch source.
//
//  `NSTouch` is documented and stable, but AppKit only hands touches to the
//  focused application. To see them from a background utility the events are
//  intercepted with a CGEventTap on gesture events and re-inflated with
//  `NSEvent(cgEvent:)`, which preserves the attached touches because it is the
//  same underlying event object.
//
//  Trade-offs versus MultitouchSupport, honestly stated:
//    * requires Accessibility permission (MultitouchSupport does not),
//    * only sees events the window server routes, so it can miss contacts while
//      certain full-screen apps or secure input fields are frontmost,
//    * slightly higher latency.
//
//  It exists so that if Apple ever changes MTTouch, Glisse degrades instead
//  of dying.
//

import AppKit
import Foundation

public final class AppKitTouchSource: TouchSource {

    public let identifier = "AppKit NSTouch"

    public var frameHandler: ((TrackpadFrame) -> Void)?
    public var failureHandler: ((TrackpadError) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?

    private let lock = NSLock()
    /// NSTouch identities are opaque objects; map them to stable small integers.
    private var identityToID: [NSObject: Int32] = [:]
    private var nextTouchID: Int32 = 1
    private var discoveredDevices: [String: TrackpadDevice] = [:]

    public private(set) var isRunning = false

    public init() {}

    deinit {
        stop()
    }

    public var devices: [TrackpadDevice] {
        lock.lock()
        defer { lock.unlock() }
        return Array(discoveredDevices.values)
    }

    // MARK: Lifecycle

    public func start() throws {
        guard !isRunning else { return }
        guard AXIsProcessTrusted() else {
            throw TrackpadError.accessibilityRequired
        }

        // NSEventTypeGesture (29) is the event that carries NSTouch data for
        // indirect (trackpad) contacts. Mouse-moved is included because a
        // single finger dragging the pointer also carries touches.
        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << 29) |                                   // NSEventTypeGesture
            (1 << CGEventType.leftMouseDragged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let source = Unmanaged<AppKitTouchSource>.fromOpaque(refcon).takeUnretainedValue()
            source.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,          // never modifies or swallows events
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw TrackpadError.eventTapCreationFailed
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        tapRunLoop = CFRunLoopGetMain()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true

        Log.trackpad.info("AppKit touch source started (event tap)")
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource, let loop = tapRunLoop {
            CFRunLoopRemoveSource(loop, source, .commonModes)
        }
        runLoopSource = nil
        tapRunLoop = nil
        eventTap = nil
        isRunning = false

        lock.lock()
        identityToID.removeAll()
        discoveredDevices.removeAll()
        lock.unlock()
    }

    public func restart() throws {
        stop()
        try start()
    }

    public func diagnosticsDescription() -> String {
        var text = "AppKit NSTouch source\n"
        text += "  running          : \(isRunning ? "yes" : "no")\n"
        text += "  accessibility    : \(AXIsProcessTrusted() ? "granted" : "NOT granted")\n"
        lock.lock()
        let devs = discoveredDevices.values.sorted { $0.id < $1.id }
        lock.unlock()
        text += "  devices seen     : \(devs.count)\n"
        for device in devs {
            text += "    - \(device.name) [\(device.id)] builtIn=\(device.isBuiltIn)\n"
        }
        return text
    }

    // MARK: Event handling

    private func handle(type: CGEventType, event: CGEvent) {
        // A tap that gets disabled (timeout or user revoking permission) must be
        // re-armed or the source is silently dead.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                Log.trackpad.warning("AppKit touch tap was disabled; re-enabled")
            }
            return
        }

        guard let handler = frameHandler else { return }
        guard let nsEvent = NSEvent(cgEvent: event) else { return }

        let touches = nsEvent.touches(matching: .touching, in: nil)
        let ended = nsEvent.touches(matching: .ended, in: nil)
        let cancelled = nsEvent.touches(matching: .cancelled, in: nil)
        guard !touches.isEmpty || !ended.isEmpty || !cancelled.isEmpty else { return }

        // Group by device: two trackpads must not share a session.
        var byDevice: [String: [TrackpadTouch]] = [:]
        let timestamp = nsEvent.timestamp

        func append(_ touch: NSTouch, phase: TouchPhase) {
            guard touch.type == .indirect else { return }   // ignore Touch Bar etc.
            let deviceKey = deviceIdentifier(for: touch)
            let position = touch.normalizedPosition          // origin lower-left
            let id = stableID(for: touch, releasing: !phase.isActive)
            byDevice[deviceKey, default: []].append(
                TrackpadTouch(id: id,
                              x: position.x,
                              y: position.y,
                              phase: phase,
                              pressure: nil,
                              timestamp: timestamp)
            )
        }

        for touch in touches {
            append(touch, phase: touch.phase == .began ? .began
                                : touch.phase == .stationary ? .stationary : .moved)
        }
        for touch in ended { append(touch, phase: .ended) }
        for touch in cancelled { append(touch, phase: .cancelled) }

        for (deviceKey, deviceTouches) in byDevice where !deviceTouches.isEmpty {
            handler(TrackpadFrame(deviceID: deviceKey,
                                  timestamp: timestamp,
                                  touches: deviceTouches))
        }
    }

    private func deviceIdentifier(for touch: NSTouch) -> String {
        let deviceObject = touch.device as? NSObject
        let key: String
        if let deviceObject {
            key = "ns-\(UInt(bitPattern: ObjectIdentifier(deviceObject).hashValue))"
        } else {
            key = "ns-default"
        }

        lock.lock()
        if discoveredDevices[key] == nil {
            let size = touch.deviceSize
            discoveredDevices[key] = TrackpadDevice(
                id: key,
                // NSTouch cannot tell us whether the device is built in. A
                // built-in Mac trackpad is ~16 cm wide; a Magic Trackpad ~16 cm
                // too, so guessing would be worse than admitting ignorance.
                name: "Trackpad",
                isBuiltIn: true,
                widthMM: size.width > 0 ? size.width : nil,
                heightMM: size.height > 0 ? size.height : nil
            )
        }
        lock.unlock()
        return key
    }

    private func stableID(for touch: NSTouch, releasing: Bool) -> Int32 {
        guard let identity = touch.identity as? NSObject else { return 0 }
        lock.lock()
        defer { lock.unlock() }

        if let existing = identityToID[identity] {
            if releasing { identityToID.removeValue(forKey: identity) }
            return existing
        }
        let assigned = nextTouchID
        nextTouchID = nextTouchID == Int32.max ? 1 : nextTouchID + 1
        if !releasing {
            identityToID[identity] = assigned
        }
        return assigned
    }
}
