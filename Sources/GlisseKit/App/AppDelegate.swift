//
//  AppDelegate.swift
//  GlisseKit
//

import AppKit
import Foundation

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {

    private let coordinator = AppCoordinator()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory: no Dock icon, no app menu. LSUIElement in Info.plist covers
        // the bundled case; this covers running the bare executable too.
        NSApp.setActivationPolicy(.accessory)
        coordinator.start()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutDown()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Settings and diagnostics windows are incidental; the app lives in the
        // menu bar.
        false
    }
}
