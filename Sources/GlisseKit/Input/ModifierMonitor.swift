//
//  ModifierMonitor.swift
//  GlisseKit
//
//  Decides whether the modifier requirement is currently satisfied.
//
//  Hold mode needs no permission at all: `NSEvent.modifierFlags` is a static
//  snapshot of the current hardware state, readable by any app, and it is
//  sampled synchronously when a gesture is about to begin. That is both cheaper
//  and more accurate than tracking flagsChanged events.
//
//  Toggle mode does need the keyboard tap, because it has to notice a key press
//  the user makes while Glisse is in the background. When Accessibility is
//  missing, toggle mode reports "unavailable" instead of silently behaving like
//  `.none`.
//

import AppKit
import Foundation

public final class ModifierMonitor: @unchecked Sendable {

    private let lock = NSLock()
    private var mode: ModifierMode = .none
    private var toggleIsActive = true
    /// Flags at the previous flagsChanged, so a press can be distinguished from
    /// a release.
    private var previousFlags: NSEvent.ModifierFlags = []

    /// Fired when toggle state flips, so the menu bar icon can update.
    public var onToggleStateChanged: ((Bool) -> Void)?

    public init() {}

    // MARK: Configuration

    public func setMode(_ newMode: ModifierMode) {
        lock.lock()
        let changed = newMode != mode
        mode = newMode
        if changed {
            // Entering toggle mode starts active, so the feature is not
            // mysteriously off right after being chosen.
            toggleIsActive = true
            previousFlags = []
        }
        let active = toggleIsActive
        lock.unlock()
        if changed, case .toggle = newMode {
            onToggleStateChanged?(active)
        }
    }

    // MARK: Evaluation

    /// Synchronous, permission-free, called once per new contact.
    public func isSatisfied() -> Bool {
        lock.lock()
        let currentMode = mode
        let active = toggleIsActive
        lock.unlock()

        switch currentMode {
        case .none:
            return true
        case .hold(let key):
            return NSEvent.modifierFlags.contains(Self.flag(for: key))
        case .toggle:
            return active
        }
    }

    /// True when the mode is toggle and Glisse is currently toggled off.
    public var isToggledOff: Bool {
        lock.lock(); defer { lock.unlock() }
        if case .toggle = mode { return !toggleIsActive }
        return false
    }

    public var requiresKeyboardTap: Bool {
        lock.lock(); defer { lock.unlock() }
        if case .toggle = mode { return true }
        return false
    }

    // MARK: Toggle detection

    /// Fed from KeyboardMonitor. Flips the toggle on a *press* of the chosen
    /// modifier, ignoring the matching release so one tap is one flip.
    public func handleFlagsChanged(_ flags: NSEvent.ModifierFlags) {
        lock.lock()
        guard case .toggle(let key) = mode else {
            previousFlags = flags
            lock.unlock()
            return
        }
        let flag = Self.flag(for: key)
        let wasDown = previousFlags.contains(flag)
        let isDown = flags.contains(flag)
        previousFlags = flags

        guard isDown, !wasDown else {
            lock.unlock()
            return
        }
        toggleIsActive.toggle()
        let active = toggleIsActive
        lock.unlock()

        Log.input.info("modifier toggle -> \(active ? "active" : "inactive", privacy: .public)")
        onToggleStateChanged?(active)
    }

    /// Manual flip, from the menu.
    public func setToggleActive(_ active: Bool) {
        lock.lock()
        guard case .toggle = mode else { lock.unlock(); return }
        let changed = toggleIsActive != active
        toggleIsActive = active
        lock.unlock()
        if changed { onToggleStateChanged?(active) }
    }

    static func flag(for key: ModifierKeyChoice) -> NSEvent.ModifierFlags {
        switch key {
        case .control:  return .control
        case .option:   return .option
        case .command:  return .command
        case .shift:    return .shift
        case .function: return .function
        }
    }
}
