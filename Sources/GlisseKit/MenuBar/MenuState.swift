//
//  MenuState.swift
//  GlisseKit
//
//  Everything the menu bar needs to draw itself, in one value type. Keeps the
//  menu builder free of logic and makes "why is the icon dimmed" answerable by
//  looking at one struct.
//

import Foundation

public struct MenuState: Equatable {
    public var settings: AppSettings

    /// Whether gestures are actually running right now, which is not the same as
    /// `settings.isEnabled`: a toggle-mode modifier or a missing touch source can
    /// hold it off.
    public var isActive: Bool
    public var isToggledOff: Bool

    public var touchSourceName: String
    public var trackpadCount: Int
    public var accessibilityGranted: Bool
    public var launchAtLoginState: LoginItemManager.State

    public var audioDeviceName: String
    public var volumeControlAvailable: Bool
    public var controllableDisplays: [DisplayTarget]
    public var hudProviderName: String

    /// Non-nil when something is wrong that the user can act on.
    public var problem: String?

    public init(settings: AppSettings,
                isActive: Bool,
                isToggledOff: Bool,
                touchSourceName: String,
                trackpadCount: Int,
                accessibilityGranted: Bool,
                launchAtLoginState: LoginItemManager.State,
                audioDeviceName: String,
                volumeControlAvailable: Bool,
                controllableDisplays: [DisplayTarget],
                hudProviderName: String,
                problem: String?) {
        self.settings = settings
        self.isActive = isActive
        self.isToggledOff = isToggledOff
        self.touchSourceName = touchSourceName
        self.trackpadCount = trackpadCount
        self.accessibilityGranted = accessibilityGranted
        self.launchAtLoginState = launchAtLoginState
        self.audioDeviceName = audioDeviceName
        self.volumeControlAvailable = volumeControlAvailable
        self.controllableDisplays = controllableDisplays
        self.hudProviderName = hudProviderName
        self.problem = problem
    }

    /// SF Symbol used when the hand style is chosen, or when something is wrong.
    public static let handSymbolName = "hand.draw.fill"
    public static let warningSymbolName = "exclamationmark.triangle"

    /// Nil when the drawn Glissé mark should be used instead of an SF Symbol.
    public var statusSymbolName: String? {
        guard trackpadCount > 0 else { return Self.warningSymbolName }
        return settings.menuBarIcon == .hand ? Self.handSymbolName : nil
    }

    /// The status item is drawn dimmed rather than hidden when inactive, so the
    /// state is visible without being loud.
    public var statusIconIsDimmed: Bool {
        !settings.isEnabled || isToggledOff || trackpadCount == 0
    }
}
