//
//  AppSettings.swift
//  GlisseKit
//
//  The single source of truth for every preference. Value type, Codable,
//  Equatable and Sendable so it can be snapshotted and handed to the gesture
//  actor without sharing mutable state.
//

import Foundation

// MARK: - Edges & assignments

public enum TrackpadEdge: String, Codable, Sendable, CaseIterable {
    case left
    case right
}

/// What an edge controls. `none` disables that edge entirely.
public enum EdgeAssignment: String, Codable, Sendable, CaseIterable {
    case none
    case brightness
    case volume

    public var displayName: String {
        switch self {
        case .none:       return "Nothing"
        case .brightness: return "Brightness"
        case .volume:     return "Volume"
        }
    }
}

// MARK: - Modifier gating

public enum ModifierKeyChoice: String, Codable, Sendable, CaseIterable {
    case control
    case option
    case command
    case shift
    /// Fn is reported by CGEventFlags as `maskSecondaryFn`. It is reliable on
    /// Apple keyboards; on some third-party keyboards it never appears, which is
    /// why it is offered but not the default.
    case function

    public var displayName: String {
        switch self {
        case .control:  return "Control"
        case .option:   return "Option"
        case .command:  return "Command"
        case .shift:    return "Shift"
        case .function: return "Fn"
        }
    }
}

public enum ModifierMode: Codable, Sendable, Equatable {
    /// Edge gestures always eligible.
    case none
    /// Eligible only while the key is physically held.
    case hold(ModifierKeyChoice)
    /// Tapping the key flips Glisse between active and inactive.
    case toggle(ModifierKeyChoice)

    public var key: ModifierKeyChoice? {
        switch self {
        case .none: return nil
        case .hold(let k), .toggle(let k): return k
        }
    }

    public var displayName: String {
        switch self {
        case .none:            return "None"
        case .hold(let k):     return "Hold \(k.displayName)"
        case .toggle(let k):   return "Toggle with \(k.displayName)"
        }
    }
}

// MARK: - Brightness targeting

public enum BrightnessTarget: String, Codable, Sendable, CaseIterable {
    case builtIn
    case main
    case underCursor
    case allSupported

    public var displayName: String {
        switch self {
        case .builtIn:      return "Built-in Display"
        case .main:         return "Main Display"
        case .underCursor:  return "Display Under Cursor"
        case .allSupported: return "All Supported Displays"
        }
    }
}

/// What the menu bar shows. The Glissé mark is the default; the hand is kept
/// because a literal gesture glyph reads faster for some people.
public enum MenuBarIconStyle: String, Codable, Sendable, CaseIterable {
    case mark
    case hand

    public var displayName: String {
        switch self {
        case .mark: return "Glissé mark"
        case .hand: return "Hand"
        }
    }
}

// MARK: - Touch source

public enum TouchSourcePreference: String, Codable, Sendable, CaseIterable {
    /// MultitouchSupport when it works, NSTouch otherwise. Correct choice.
    case automatic
    case multitouchSupport
    case appKitTouches

    public var displayName: String {
        switch self {
        case .automatic:         return "Automatic"
        case .multitouchSupport: return "MultitouchSupport (private)"
        case .appKitTouches:     return "AppKit NSTouch (public)"
        }
    }
}

// MARK: - Settings

public struct AppSettings: Codable, Equatable, Sendable {

    // General
    public var isEnabled: Bool

    // Edge mapping. `swapSides` is expressed on top of these so the menu can
    // offer the familiar "Swap Sides" switch while the engine only ever reads
    // the resolved assignment.
    public var leftEdgeAction: EdgeAssignment
    public var rightEdgeAction: EdgeAssignment
    public var swapSides: Bool

    // Gesture shaping
    public var fineControl: Bool
    public var bottomQuarterOnly: Bool
    public var freezeCursor: Bool
    public var smartTypingDetection: Bool
    public var modifierMode: ModifierMode

    // Feedback
    public var hapticsEnabled: Bool
    /// macOS has no haptic intensity control, so "strength" selects one of the
    /// three fixed feedback patterns plus a matching tick density.
    public var hapticStrength: HapticStrength
    /// Show the macOS on-screen display while adjusting.
    ///
    /// There is no Glisse-drawn HUD; this only controls whether the OS-owned one
    /// is triggered. On macOS 26+ that requires routing the change through
    /// synthesised media keys, which needs Accessibility permission.
    public var hudEnabled: Bool
    public var menuBarIcon: MenuBarIconStyle

    // Extras
    public var threeFingerMiddleClick: Bool

    // Displays
    public var brightnessTarget: BrightnessTarget
    /// When set, overrides `brightnessTarget` with one specific display.
    public var pinnedDisplayID: UInt32?
    public var externalDDCEnabled: Bool

    // Tuning
    public var sensitivity: Double
    public var fineSensitivity: Double
    public var edgeWidth: Double
    public var typingSuppression: TimeInterval
    public var verticalActivationThreshold: Double
    public var horizontalRejectThreshold: Double
    /// Set true only if a machine reports an inverted raw Y axis. The default
    /// is correct for every device tested; the switch exists so the user is
    /// never stuck with a backwards slider.
    public var invertVerticalAxis: Bool

    // Advanced
    public var touchSource: TouchSourcePreference
    public var diagnosticLogging: Bool
    public var launchAtLogin: Bool

    // MARK: Resolved mapping

    /// Assignment for an edge after applying `swapSides`.
    public func assignment(for edge: TrackpadEdge) -> EdgeAssignment {
        let physical: TrackpadEdge = swapSides ? (edge == .left ? .right : .left) : edge
        return physical == .left ? leftEdgeAction : rightEdgeAction
    }

    /// Sensitivity currently in force.
    public var activeSensitivity: Double {
        fineControl ? fineSensitivity : sensitivity
    }

    // MARK: Defaults

    public static let `default` = AppSettings(
        isEnabled: true,

        leftEdgeAction: .brightness,
        rightEdgeAction: .volume,
        swapSides: false,

        fineControl: false,
        bottomQuarterOnly: false,
        freezeCursor: false,
        smartTypingDetection: true,
        modifierMode: .none,

        hapticsEnabled: true,
        hapticStrength: .medium,
        hudEnabled: true,
        menuBarIcon: .mark,

        threeFingerMiddleClick: false,

        brightnessTarget: .builtIn,
        pinnedDisplayID: nil,
        externalDDCEnabled: true,

        // Tuned so one full sweep of the trackpad's short edge covers slightly
        // more than the whole range: comfortable without feeling twitchy.
        sensitivity: 1.4,
        fineSensitivity: 0.4,
        edgeWidth: 0.08,
        // 700 ms, not the 500 ms first tried. Measured on hardware: pauses between
        // words routinely exceed half a second, so a 500 ms window lapses before a
        // palm brushes the edge and the feature appears to do nothing. 700 ms
        // covers ordinary typing rhythm while still letting a deliberate
        // type-then-adjust feel immediate.
        typingSuppression: 0.7,
        verticalActivationThreshold: 0.011,
        horizontalRejectThreshold: 0.045,
        invertVerticalAxis: false,

        touchSource: .automatic,
        diagnosticLogging: false,
        launchAtLogin: true
    )

    // MARK: Validation

    /// Clamps every tunable into a sane band. Applied on load so a hand-edited
    /// or corrupted defaults plist cannot produce a NaN sensitivity or a 90%
    /// edge width that makes the whole trackpad a slider.
    public func validated() -> AppSettings {
        var s = self
        s.sensitivity = clamp(sanitized(s.sensitivity, fallback: 1.4), 0.2, 6.0)
        s.fineSensitivity = clamp(sanitized(s.fineSensitivity, fallback: 0.4), 0.05, 3.0)
        s.edgeWidth = clamp(sanitized(s.edgeWidth, fallback: 0.08), 0.04, 0.15)
        s.typingSuppression = clamp(sanitized(s.typingSuppression, fallback: 0.7), 0.0, 2.0)
        s.verticalActivationThreshold =
            clamp(sanitized(s.verticalActivationThreshold, fallback: 0.011), 0.002, 0.08)
        s.horizontalRejectThreshold =
            clamp(sanitized(s.horizontalRejectThreshold, fallback: 0.045), 0.01, 0.5)
        return s
    }
}

// MARK: - ModifierMode codable

// Hand-rolled so the stored representation is a stable, readable pair of
// strings rather than Swift's synthesised enum-with-payload encoding.
extension ModifierMode {
    private enum Kind: String, Codable { case none, hold, toggle }
    private enum CodingKeys: String, CodingKey { case kind, key }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .none
        let key = try? c.decode(ModifierKeyChoice.self, forKey: .key)
        switch kind {
        case .none:   self = .none
        case .hold:   self = key.map { .hold($0) } ?? .none
        case .toggle: self = key.map { .toggle($0) } ?? .none
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try c.encode(Kind.none, forKey: .kind)
        case .hold(let k):
            try c.encode(Kind.hold, forKey: .kind)
            try c.encode(k, forKey: .key)
        case .toggle(let k):
            try c.encode(Kind.toggle, forKey: .kind)
            try c.encode(k, forKey: .key)
        }
    }
}
