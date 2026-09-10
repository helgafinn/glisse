//
//  LoginItemManager.swift
//  GlisseKit
//
//  Launch at login via SMAppService (macOS 13+). No helper-app bundle, no
//  deprecated LSSharedFileList, no login-items shell scripting.
//
//  The reported state is the *real* registration state, including the
//  `requiresApproval` case that happens when the user has toggled the app off in
//  System Settings > General > Login Items. Pretending that is "enabled" would
//  make the checkbox lie.
//

import Foundation
import ServiceManagement

@MainActor
public final class LoginItemManager {

    public enum State: Equatable {
        case enabled
        case disabled
        case requiresApproval
        case unavailable(String)

        public var isEnabled: Bool { self == .enabled }

        public var displayName: String {
            switch self {
            case .enabled:          return "Enabled"
            case .disabled:         return "Disabled"
            case .requiresApproval: return "Needs approval in System Settings"
            case .unavailable(let reason): return "Unavailable (\(reason))"
            }
        }
    }

    public init() {}

    /// SMAppService.mainApp only works for a real bundle. Running the raw
    /// executable (as `swift run` does) must not crash or claim success.
    private var isBundled: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// True when the bundle sits somewhere a login item would keep working.
    ///
    /// A registration pointing into a build directory breaks the moment the
    /// project is cleaned, and leaves a broken entry in System Settings.
    public var isInInstalledLocation: Bool {
        guard isBundled else { return false }
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let installed = [
            "/Applications/",
            NSHomeDirectory() + "/Applications/",
        ]
        return installed.contains { path.hasPrefix($0) }
    }

    public var state: State {
        guard isBundled else {
            return .unavailable("not running from an .app bundle")
        }
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .disabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            // Measured on macOS 27.0: an app that has *never* been registered
            // reports .notFound, not .notRegistered — the latter only appears
            // after an explicit unregister. Treating .notFound as unavailable
            // would permanently disable the Launch at Login checkbox, so it is
            // reported as simply "off" and registration is still offered.
            return .disabled
        @unknown default:
            return .unavailable("unknown status")
        }
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool) -> Result<State, Error> {
        guard isBundled else {
            let error = NSError(
                domain: "xyz.glisse.login",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Launch at Login needs \(Branding.displayName) to be running from its .app bundle."])
            return .failure(error)
        }

        do {
            if enabled {
                // Registering while already registered throws; treat that as success.
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            let resulting = state
            Log.app.info("launch at login -> \(resulting.displayName, privacy: .public)")
            return .success(resulting)
        } catch {
            Log.app.error("launch at login change failed: \(error.localizedDescription, privacy: .public)")
            return .failure(error)
        }
    }

    /// Opens the Login Items pane so the user can approve a blocked registration.
    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    public func diagnosticsDescription() -> String {
        """
        Launch at login
          bundled          : \(isBundled)
          state            : \(state.displayName)
        """
    }
}
