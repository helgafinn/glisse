//
//  Branding.swift
//  GlisseKit
//
//  The user-facing name lives here and nowhere else.
//
//  The executable, SwiftPM product, module and bundle identifier all stay ASCII
//  ("Glisse") because they double as the process name and as filesystem paths.
//  Only what a person reads carries the accent.
//

import Foundation

public enum Branding {
    /// Shown in the menu, alerts, window titles and diagnostics.
    public static let displayName = "Glissé"

    /// Bundle identifier, also the OSLog subsystem.
    public static let bundleIdentifier = "xyz.glisse.Glisse"

    /// Domain a previous release stored preferences under. Settings are migrated
    /// from it once, so renaming the app does not silently reset the user's
    /// configuration.
    public static let legacyDefaultsDomain = "xyz.edgeslide.EdgeSlide"

    public static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
