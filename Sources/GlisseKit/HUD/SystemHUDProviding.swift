//
//  SystemHUDProviding.swift
//  GlisseKit
//
//  Glisse draws no HUD of its own. The only HUD it ever shows is the one macOS
//  owns, so its appearance always matches the user's macOS version.
//
//  There are two ways to get it, and which one applies depends on the OS:
//
//    macOS 13–15  The private OSD interface still renders, so the exact value can
//                 be written directly and the HUD asked to display it. That is
//                 what `NativeSystemHUDProvider` does, through this protocol.
//
//    macOS 26+    That interface draws nothing (see GLOSDBridge.m). The only thing
//                 that still produces the OS-owned HUD is the event a Mac keyboard
//                 sends, so the *value change itself* goes through synthesised
//                 media keys — macOS performs the change and draws its own HUD.
//                 See MediaKeyController. Nothing goes through this protocol then.
//

import CoreGraphics
import Foundation

public protocol SystemHUDProviding: AnyObject {
    /// False when this provider cannot drive the system HUD on this OS.
    var isAvailable: Bool { get }
    var name: String { get }

    func showVolume(level: Double, muted: Bool)
    func showBrightness(level: Double)

    /// Optional display targeting, for machines with more than one screen.
    func showBrightness(level: Double, display: CGDirectDisplayID?)
}

public extension SystemHUDProviding {
    func showBrightness(level: Double) {
        showBrightness(level: level, display: nil)
    }
}

public enum HUDProviderError: LocalizedError {
    case nativeUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .nativeUnavailable(let detail):
            return "The native macOS HUD cannot be driven: \(detail)"
        }
    }
}
