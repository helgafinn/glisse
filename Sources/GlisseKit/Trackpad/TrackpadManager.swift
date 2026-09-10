//
//  TrackpadManager.swift
//  GlisseKit
//
//  Owns the active touch source, picks between the private and public paths, and
//  recovers from the things that break trackpad utilities: sleep, lid close,
//  Bluetooth reconnect, and Apple changing a private struct.
//
//  Frames are handed straight through to the consumer on the source's own thread.
//  This class deliberately does no queue hopping: the coordinator owns the serial
//  processing queue, and adding a second hop here would only add latency.
//

import Foundation

public final class TrackpadManager: @unchecked Sendable {

    public enum SourceKind: String, Equatable {
        case multitouchSupport
        case appKit
        case none
    }

    private let lock = NSLock()
    private var source: TouchSource?
    private var kind: SourceKind = .none
    /// Set when MultitouchSupport has proven itself unusable this session, so a
    /// restart does not keep retrying a broken path.
    private var multitouchBlacklisted = false

    private var preference: TouchSourcePreference = .automatic

    /// Called on the source's thread, at up to ~125 Hz per device.
    public var frameHandler: ((TrackpadFrame) -> Void)?
    /// Called when the active source changes, so the UI can say which is in use.
    public var onSourceChanged: ((SourceKind) -> Void)?
    /// Called when no source could be started at all.
    public var onUnavailable: ((TrackpadError) -> Void)?

    public init() {}

    deinit {
        stop()
    }

    // MARK: State

    public var activeSourceKind: SourceKind {
        lock.lock(); defer { lock.unlock() }
        return kind
    }

    public var activeSourceName: String {
        lock.lock(); defer { lock.unlock() }
        return source?.identifier ?? "None"
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return source?.isRunning ?? false
    }

    public var devices: [TrackpadDevice] {
        lock.lock(); defer { lock.unlock() }
        return source?.devices ?? []
    }

    /// Device the haptic actuator should target: the built-in trackpad if there
    /// is one, otherwise whatever reports a usable device id.
    public var actuatorDeviceID: UInt64 {
        let all = devices
        if let builtIn = all.first(where: { $0.isBuiltIn && $0.numericID != 0 }) {
            return builtIn.numericID
        }
        return all.first(where: { $0.numericID != 0 })?.numericID ?? 0
    }

    public func setPreference(_ newPreference: TouchSourcePreference) {
        lock.lock()
        let changed = newPreference != preference
        preference = newPreference
        let running = source?.isRunning ?? false
        lock.unlock()

        guard changed else { return }
        if running {
            stop()
            start()
        }
    }

    // MARK: Lifecycle

    public func start() {
        lock.lock()
        if source?.isRunning == true {
            lock.unlock()
            return
        }
        let order = candidateOrder()
        lock.unlock()

        var lastError: TrackpadError = .noSourceAvailable("no candidates")

        for candidate in order {
            do {
                try startCandidate(candidate)
                return
            } catch let error as TrackpadError {
                lastError = error
                Log.trackpad.warning("""
                    touch source \(candidate.rawValue, privacy: .public) unavailable: \
                    \(error.localizedDescription, privacy: .public)
                    """)
            } catch {
                lastError = .noSourceAvailable(error.localizedDescription)
            }
        }

        lock.lock(); kind = .none; source = nil; lock.unlock()
        onSourceChanged?(.none)
        onUnavailable?(lastError)
    }

    private func candidateOrder() -> [SourceKind] {
        switch preference {
        case .multitouchSupport:
            return [.multitouchSupport]
        case .appKitTouches:
            return [.appKit]
        case .automatic:
            return multitouchBlacklisted ? [.appKit] : [.multitouchSupport, .appKit]
        }
    }

    private func startCandidate(_ candidate: SourceKind) throws {
        let created: TouchSource
        switch candidate {
        case .multitouchSupport:
            guard MultitouchSupportTouchSource.isAvailable else {
                throw TrackpadError.multitouchUnavailable(MultitouchSupportTouchSource.unavailableReason)
            }
            created = MultitouchSupportTouchSource()
        case .appKit:
            created = AppKitTouchSource()
        case .none:
            throw TrackpadError.noSourceAvailable("none")
        }

        created.frameHandler = { [weak self] frame in
            self?.frameHandler?(frame)
        }
        created.failureHandler = { [weak self] error in
            self?.handleSourceFailure(kind: candidate, error: error)
        }

        try created.start()

        lock.lock()
        source?.stop()
        source = created
        kind = candidate
        lock.unlock()

        Log.trackpad.info("""
            touch source: \(created.identifier, privacy: .public), \
            \(created.devices.count, privacy: .public) device(s)
            """)
        onSourceChanged?(candidate)
    }

    public func stop() {
        lock.lock()
        let current = source
        source = nil
        kind = .none
        lock.unlock()
        current?.frameHandler = nil
        current?.failureHandler = nil
        current?.stop()
    }

    /// Tear down and rebuild. Used on wake and on trackpad hot-plug, where
    /// retained device references can be stale even though they look valid.
    public func restart(reason: String) {
        Log.trackpad.info("restarting touch source: \(reason, privacy: .public)")

        lock.lock()
        let current = source
        lock.unlock()

        if let current {
            do {
                try current.restart()
                Log.trackpad.info("touch source restarted in place")
                return
            } catch {
                Log.trackpad.warning("""
                    in-place restart failed (\(error.localizedDescription, privacy: .public)); \
                    rebuilding
                    """)
            }
        }

        stop()
        start()
    }

    // MARK: Failure handling

    /// MultitouchSupport told us it cannot parse its own frames. Blacklist it for
    /// this session and fall back to the public source rather than feeding the
    /// gesture engine garbage.
    private func handleSourceFailure(kind failedKind: SourceKind, error: TrackpadError) {
        Log.trackpad.error("""
            touch source \(failedKind.rawValue, privacy: .public) failed: \
            \(error.localizedDescription, privacy: .public)
            """)

        if failedKind == .multitouchSupport {
            lock.lock(); multitouchBlacklisted = true; lock.unlock()
        }

        stop()
        start()
    }

    // MARK: Diagnostics

    public func diagnosticsDescription() -> String {
        lock.lock()
        let current = source
        let currentKind = kind
        let blacklisted = multitouchBlacklisted
        let currentPreference = preference
        lock.unlock()

        var text = "Trackpad manager\n"
        text += "  preference       : \(currentPreference.displayName)\n"
        text += "  active source    : \(currentKind.rawValue)\n"
        text += "  MT blacklisted   : \(blacklisted)\n"
        text += "  MT available     : \(MultitouchSupportTouchSource.isAvailable)"
        if !MultitouchSupportTouchSource.isAvailable {
            text += " (\(MultitouchSupportTouchSource.unavailableReason))"
        }
        text += "\n\n"
        if let current {
            text += current.diagnosticsDescription()
        }
        return text
    }
}
