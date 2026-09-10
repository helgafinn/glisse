//
//  AppLifecycleObserver.swift
//  GlisseKit
//
//  Watches every system event that historically breaks trackpad/display
//  utilities, and reports them as intentions rather than raw notifications.
//
//  This is mandatory, not defensive polish. MultitouchSupport device references
//  go stale across sleep, DDC I2C endpoints die when a dock re-negotiates, and
//  Core Audio hands out a new device ID when AirPods connect. Without this the
//  app "stops working until you quit and reopen it", which is the single most
//  common complaint about this category of utility.
//

import AppKit
import Foundation
import IOKit
import IOKit.pwr_mgt

@MainActor
public final class AppLifecycleObserver {

    public enum Event: Equatable, Sendable {
        case willSleep
        case didWake
        case screensDidSleep
        case screensDidWake
        case screenLocked
        case screenUnlocked
        case displayConfigurationChanged
        case appDidBecomeActive
        case appDidResignActive
        case sessionBecameActive
        case sessionResignedActive
    }

    public var onEvent: ((Event) -> Void)?

    private var tokens: [NSObjectProtocol] = []
    private var distributedTokens: [NSObjectProtocol] = []

    public init() {}

    deinit {
        // NotificationCenter observers are removed automatically on dealloc for
        // block-based tokens only if we hold them; do it explicitly.
        for token in tokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        for token in distributedTokens {
            DistributedNotificationCenter.default().removeObserver(token)
        }
    }

    public func start() {
        let workspace = NSWorkspace.shared.notificationCenter

        observe(workspace, NSWorkspace.willSleepNotification, .willSleep)
        observe(workspace, NSWorkspace.didWakeNotification, .didWake)
        observe(workspace, NSWorkspace.screensDidSleepNotification, .screensDidSleep)
        observe(workspace, NSWorkspace.screensDidWakeNotification, .screensDidWake)
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification, .sessionBecameActive)
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionResignedActive)

        // Screen lock / unlock has no public constant.
        observeDistributed("com.apple.screenIsLocked", .screenLocked)
        observeDistributed("com.apple.screenIsUnlocked", .screenUnlocked)

        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.emit(.appDidBecomeActive) }
        })
        tokens.append(center.addObserver(forName: NSApplication.didResignActiveNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.emit(.appDidResignActive) }
        })
        // NSApplication.didChangeScreenParametersNotification fires for
        // resolution, arrangement and scale changes that CGDisplayReconfiguration
        // does not always cover.
        tokens.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.emit(.displayConfigurationChanged) }
        })

        Log.lifecycle.info("lifecycle observer started")
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ event: Event) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.emit(event) }
        }
        tokens.append(token)
    }

    private func observeDistributed(_ name: String, _ event: Event) {
        let token = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.emit(event) }
        }
        distributedTokens.append(token)
    }

    private func emit(_ event: Event) {
        Log.lifecycle.info("event: \(String(describing: event), privacy: .public)")
        onEvent?(event)
    }
}
