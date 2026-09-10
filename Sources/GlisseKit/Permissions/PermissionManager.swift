//
//  PermissionManager.swift
//  GlisseKit
//
//  Accessibility permission, handled without nagging.
//
//  What actually needs it:
//    * typing suppression (keyboard event tap)
//    * toggle-mode modifier detection
//    * three-finger middle click (posting events)
//    * the AppKit fallback touch source
//
//  What does NOT need it: the primary edge gesture path. MultitouchSupport, Core
//  Audio and DisplayServices all work untrusted. So Glisse is useful on first
//  launch before the user has granted anything, and the permission is presented
//  as an upgrade rather than a gate.
//
//  Polling policy: `AXIsProcessTrusted()` has no notification, so it is polled —
//  but only while a request is outstanding, at 1 Hz, and the timer is torn down
//  the moment it flips. No background polling in steady state.
//

import AppKit
import ApplicationServices
import Foundation
import Security

public enum PermissionError: LocalizedError, Equatable {
    case accessibilityNotGranted
    case eventTapDenied

    public var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return "Accessibility permission has not been granted to Glisse."
        case .eventTapDenied:
            return "macOS refused to create an event tap. Accessibility permission is required."
        }
    }
}

@MainActor
public final class PermissionManager {

    public enum AccessibilityState: Equatable {
        case granted
        case notGranted

        public var isGranted: Bool { self == .granted }
        public var displayName: String {
            self == .granted ? "Granted" : "Not Granted"
        }
    }

    public private(set) var accessibility: AccessibilityState = .notGranted

    /// Fired on the main actor when the state changes.
    public var onAccessibilityChanged: ((AccessibilityState) -> Void)?

    private var pollTimer: DispatchSourceTimer?
    private var pollInterval: TimeInterval?
    /// Set by the owner when a feature is blocked on the permission, so a bounded
    /// watch can step down to an indefinite one instead of giving up.
    public var wantsIndefiniteWatch = false
    /// Set once the user has been shown the request. Prevents re-prompting on
    /// every launch after a deliberate refusal.
    private var hasPromptedThisSession = false

    private let promptedKey = "permissions.hasPromptedForAccessibility"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refresh()
    }

    // MARK: State

    @discardableResult
    public func refresh() -> AccessibilityState {
        let state: AccessibilityState = AXIsProcessTrusted() ? .granted : .notGranted
        let changed = state != accessibility
        accessibility = state
        if changed {
            Log.permissions.info("accessibility -> \(state.displayName, privacy: .public)")
            onAccessibilityChanged?(state)
        }
        return state
    }

    public var hasEverPrompted: Bool {
        defaults.bool(forKey: promptedKey)
    }

    // MARK: Requesting

    /// Shows the system prompt. Safe to call repeatedly; macOS only shows the
    /// sheet once per app version, after which it does nothing, which is why
    /// `openSystemSettings` exists as the follow-up.
    public func requestAccessibility() {
        guard !accessibility.isGranted else { return }

        hasPromptedThisSession = true
        defaults.set(true, forKey: promptedKey)

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)

        beginWatching()
    }

    /// Opens the exact pane, not just System Settings' front page.
    ///
    /// The pane identifier changed: `com.apple.preference.security` is the old
    /// one, `com.apple.settings.PrivacySecurity.extension` is the ExtensionKit
    /// bundle that actually ships on macOS 26+ (verified present on 27.0, and it
    /// advertises a `privacy-accessibility` anchor). Both are tried, newest first.
    public func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                break
            }
        }
        beginWatching()
    }

    /// Apple renamed this pane in macOS 27: "Privacy & Security" became
    /// "Device Control and Data Access". Telling the user to look for the wrong
    /// name is worse than not telling them at all.
    public static var settingsPaneName: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
            ? "Device Control and Data Access"
            : "Privacy & Security"
    }

    /// Only prompt unprompted users; a user who said no is left alone until they
    /// use the Permissions… menu item.
    public func requestIfNeverAskedBefore() {
        guard !accessibility.isGranted else { return }
        guard !hasEverPrompted else {
            Log.permissions.info("accessibility not granted; not re-prompting (already asked once)")
            return
        }
        requestAccessibility()
    }

    // MARK: Watching

    /// Polls until the state flips, then stops. Used after opening System
    /// Settings so dependent features come alive without an app restart.
    ///
    /// `timeout` exists so a one-off request does not poll forever. For the case
    /// where a feature is switched on and is *waiting* on permission, use
    /// `watchIndefinitely()` — a fixed deadline there means a user who grants the
    /// permission ten minutes later sees nothing happen, which reads as the app
    /// being broken.
    public func beginWatching(timeout: TimeInterval = 300) {
        startPolling(interval: 1.0, deadline: MonotonicClock.now() + timeout)
    }

    /// Polls slowly for as long as the permission is missing. Costs one
    /// `AXIsProcessTrusted()` call every few seconds, and stops the moment it is
    /// granted.
    public func watchIndefinitely() {
        wantsIndefiniteWatch = true
        guard !accessibility.isGranted else { return }
        startPolling(interval: 2.0, deadline: nil)
    }

    private func startPolling(interval: TimeInterval, deadline: TimeInterval?) {
        // A shorter interval wins: an explicit request should react fast.
        if let existing = pollInterval, existing <= interval, pollTimer != nil { return }
        stopWatching()
        pollInterval = interval

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let previous = self.accessibility
            let current = self.refresh()
            if current != previous {
                self.stopWatching()
                return
            }
            if let deadline, MonotonicClock.now() > deadline {
                // Do not simply stop: a bounded watch expiring must not leave the
                // app permanently blind to a permission granted later. Step down
                // to the slow indefinite watch instead.
                self.stopWatching()
                if !self.accessibility.isGranted, self.wantsIndefiniteWatch {
                    self.watchIndefinitely()
                }
            }
        }
        pollTimer = timer
        timer.resume()
        Log.permissions.info("""
            watching for accessibility changes every \
            \(Int(interval), privacy: .public)s\(deadline == nil ? " (no deadline)" : "")
            """)
    }

    public func stopWatching() {
        pollTimer?.cancel()
        pollTimer = nil
        pollInterval = nil
    }

    // MARK: Explanations

    public static var accessibilityRationale: String {
        """
        Granting Accessibility enables:
          •  the real macOS volume / brightness display while you slide
          •  pausing edge gestures while you type
          •  toggle-style modifier activation
          •  the three-finger middle click

        Edge sliding, volume and brightness all work without it — you just get no \
        on-screen display.

        Where to find it:
          System Settings ▸ \(settingsPaneName) ▸ Accessibility
        then add Glisse with + and switch it on.
        """
    }

    /// Describes how this build is signed, and whether that identity is stable.
    ///
    /// Worth surfacing because of a genuinely confusing failure mode: an ad-hoc
    /// signature's designated requirement is a cdhash, which changes on every
    /// rebuild. macOS then shows the app switched ON in the Accessibility list
    /// while refusing to trust the running binary, because the stored entry
    /// belongs to a previous build. The remedy is to remove that row and re-add
    /// the current bundle, or to sign with a stable identity.
    public static func codeSignatureSummary() -> String {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else {
            return "unknown (could not read own code object)"
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else {
            return "unknown (no static code)"
        }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else {
            return "unsigned or unreadable"
        }

        // kSecCodeSignatureAdhoc
        let signatureFlags = (dictionary[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        let isAdhoc = (signatureFlags & 0x0000_0002) != 0
        let identifier = (dictionary[kSecCodeInfoIdentifier as String] as? String) ?? "?"

        var hash = "?"
        if let unique = dictionary[kSecCodeInfoUnique as String] as? Data {
            hash = unique.prefix(10).map { String(format: "%02x", $0) }.joined()
        }

        var text = "\(identifier) · cdhash \(hash)"
        if isAdhoc {
            text += " · ad-hoc (identity changes on every rebuild)"
        } else if let authority = (dictionary[kSecCodeInfoCertificates as String] as? [Any])?.first,
                  let certificate = authority as! SecCertificate? {
            let name = SecCertificateCopySubjectSummary(certificate) as String? ?? "certificate"
            text += " · signed by \(name) (stable identity)"
        } else {
            text += " · signed (stable identity)"
        }
        return text
    }

    public func diagnosticsDescription() -> String {
        """
        Permissions
          accessibility    : \(accessibility.displayName)
          prompted before  : \(hasEverPrompted)
          watching         : \(pollTimer != nil)\(pollInterval.map { " every \(Int($0))s" } ?? "")
          code signature   : \(Self.codeSignatureSummary())
          settings pane    : \(Self.settingsPaneName) ▸ Accessibility
        """
    }
}
