//
//  HUDCoordinator.swift
//  GlisseKit
//
//  Decides how the native macOS HUD gets shown, and rate limits it.
//
//  Glisse has no HUD of its own. There are exactly two mechanisms, both
//  OS-owned:
//
//    .osdInjection   Write the precise value, then ask the private OSD to display
//                    it. Available on macOS 13–15. Best of both: continuous values
//                    and the system HUD.
//
//    .mediaKeys      Let macOS perform the change by synthesising the machine's
//                    own media keys, which makes it draw its own HUD. The only
//                    thing that works on macOS 26+. Steps of 1/64.
//
//    .none           No HUD. The value is still written precisely. Used when the
//                    user turns the display off, when Accessibility is missing, or
//                    when brightness is aimed at a display the media keys cannot
//                    address (a specific or external screen).
//
//  The choice is per-gesture, because it depends on what is being adjusted.
//

import CoreGraphics
import Foundation

public enum HUDMechanism: Equatable, Sendable {
    case osdInjection
    case mediaKeys
    case none

    public var displayName: String {
        switch self {
        case .osdInjection: return "System OSD (direct)"
        case .mediaKeys:    return "System HUD (media keys)"
        case .none:         return "No HUD"
        }
    }
}

public final class HUDCoordinator: @unchecked Sendable {

    private let native = NativeSystemHUDProvider()
    private let mediaKeys: MediaKeyController

    private let lock = NSLock()
    private var throttle = Throttler(interval: 1.0 / 60.0)
    private var pendingFinal: (() -> Void)?
    private var _isEnabled = true

    public init(mediaKeys: MediaKeyController) {
        self.mediaKeys = mediaKeys
    }

    /// Master switch. When off, values are still written; nothing is displayed.
    public var isEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isEnabled }
        set { lock.lock(); _isEnabled = newValue; lock.unlock() }
    }

    // MARK: Mechanism selection

    /// - Parameter canUseMediaKeys: false when the change cannot be delegated to
    ///   the system, e.g. brightness aimed at a specific or external display.
    public func mechanism(canUseMediaKeys: Bool) -> HUDMechanism {
        guard isEnabled else { return .none }
        if native.isAvailable { return .osdInjection }
        if canUseMediaKeys, mediaKeys.isAvailable { return .mediaKeys }
        return .none
    }

    /// True when the only route to a HUD needs Accessibility and does not have it.
    /// Lets the UI explain why no HUD is appearing instead of staying silent.
    public var needsAccessibilityForHUD: Bool {
        guard isEnabled else { return false }
        return !native.isAvailable && !mediaKeys.isAvailable
    }

    // MARK: OSD injection (macOS 13–15)

    public func showVolume(level: Double, muted: Bool, force: Bool = false) {
        guard isEnabled, native.isAvailable else { return }
        let action = { self.native.showVolume(level: clamp01(level), muted: muted) }
        emit(action, force: force)
    }

    public func showBrightness(level: Double,
                               display: CGDirectDisplayID?,
                               force: Bool = false) {
        guard isEnabled, native.isAvailable else { return }
        let action = { self.native.showBrightness(level: clamp01(level), display: display) }
        emit(action, force: force)
    }

    private func emit(_ action: @escaping () -> Void, force: Bool) {
        lock.lock()
        let allowed = force || throttle.allow(now: MonotonicClock.now())
        if allowed {
            pendingFinal = nil
        } else {
            pendingFinal = action
        }
        lock.unlock()

        if allowed { action() }
    }

    /// Gesture finished: push the last suppressed value so the HUD ends on the
    /// true final level.
    public func gestureDidEnd() {
        lock.lock()
        let trailing = pendingFinal
        pendingFinal = nil
        throttle.reset()
        lock.unlock()
        trailing?()
    }

    public func reset() {
        lock.lock()
        pendingFinal = nil
        throttle.reset()
        lock.unlock()
    }

    /// Drops any private-framework connection. Call on wake.
    public func invalidateConnections() {
        native.invalidateConnections()
        reset()
    }

    public var activeRouteName: String { native.activeRouteName }

    public func diagnosticsDescription() -> String {
        var text = native.diagnosticsDescription()
        text += "  HUD enabled      : \(isEnabled)\n"
        text += "  mechanism (volume): \(mechanism(canUseMediaKeys: true).displayName)\n"
        text += "  native route     : \(activeRouteName)\n"
        if needsAccessibilityForHUD {
            text += "  note             : grant Accessibility to get the system HUD\n"
        }
        text += "\n" + mediaKeys.diagnosticsDescription() + "\n"
        return text
    }
}
