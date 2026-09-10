//
//  MenuBuilder.swift
//  GlisseKit
//
//  Builds a plain NSMenu. No custom views, no oversized panel — the spec asks
//  for something that feels like it came with macOS, and that means a normal
//  menu with checkmarks and submenus.
//

import AppKit
import Foundation

@MainActor
public protocol MenuActionHandling: AnyObject {
    func toggleEnabled()
    func setEdgeAssignment(_ assignment: EdgeAssignment, for edge: TrackpadEdge)
    func toggleFineControl()
    func toggleSwapSides()
    func toggleBottomQuarter()
    func toggleFreezeCursor()
    func toggleHaptics()
    func setHapticStrength(_ strength: HapticStrength)
    func toggleNativeHUD()
    func toggleThreeFingerMiddleClick()
    func toggleSmartTyping()
    func setModifierMode(_ mode: ModifierMode)
    func setBrightnessTarget(_ target: BrightnessTarget)
    func pinDisplay(_ displayID: UInt32?)
    func toggleLaunchAtLogin()
    func openPermissions()
    func openSettings()
    func openDiagnostics()
    func showAbout()
    func quit()
}

@MainActor
public final class MenuBuilder {

    private weak var handler: MenuActionHandling?

    public init(handler: MenuActionHandling) {
        self.handler = handler
    }

    public func buildMenu(state: MenuState) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // ---- Header -------------------------------------------------------
        let header = NSMenuItem(title: Branding.displayName, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if let problem = state.problem {
            let warning = NSMenuItem(title: problem, action: nil, keyEquivalent: "")
            warning.isEnabled = false
            warning.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                    accessibilityDescription: nil)
            menu.addItem(warning)
        }

        menu.addItem(.separator())

        // ---- Enabled ------------------------------------------------------
        let enabled = item("Enabled", #selector(MenuTarget.enabledToggled))
        enabled.state = state.settings.isEnabled ? .on : .off
        menu.addItem(enabled)

        if state.isToggledOff {
            let note = NSMenuItem(
                title: "Paused — press \(state.settings.modifierMode.key?.displayName ?? "the modifier") to resume",
                action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }

        menu.addItem(.separator())

        // ---- Edge assignments --------------------------------------------
        let controls = NSMenuItem(title: "Controls", action: nil, keyEquivalent: "")
        controls.isEnabled = false
        menu.addItem(controls)

        menu.addItem(edgeSubmenuItem(title: "Left Edge",
                                     edge: .left,
                                     current: state.settings.assignment(for: .left)))
        menu.addItem(edgeSubmenuItem(title: "Right Edge",
                                     edge: .right,
                                     current: state.settings.assignment(for: .right)))

        menu.addItem(.separator())

        // ---- Switches -----------------------------------------------------
        menu.addItem(toggle("Fine Control", state.settings.fineControl, #selector(MenuTarget.fineToggled)))
        menu.addItem(toggle("Swap Sides", state.settings.swapSides, #selector(MenuTarget.swapToggled)))
        menu.addItem(toggle("Bottom Quarter Only", state.settings.bottomQuarterOnly,
                            #selector(MenuTarget.bottomQuarterToggled)))
        menu.addItem(toggle("Freeze Cursor While Adjusting", state.settings.freezeCursor,
                            #selector(MenuTarget.freezeCursorToggled)))
        menu.addItem(hapticSubmenuItem(state: state))

        let hudItem = toggle("macOS On-Screen Display", state.settings.hudEnabled,
                             #selector(MenuTarget.hudToggled))
        hudItem.toolTip = state.accessibilityGranted
            ? "Mechanism: \(state.hudProviderName)"
            : "Needs Accessibility permission — \(Branding.displayName) shows the system display, "
              + "not one of its own, and the only way to trigger it is to let macOS "
              + "perform the change."
        menu.addItem(hudItem)

        let typing = toggle("Pause While Typing", state.settings.smartTypingDetection,
                            #selector(MenuTarget.smartTypingToggled))
        if !state.accessibilityGranted {
            typing.isEnabled = false
            typing.toolTip = "Requires Accessibility permission"
        }
        menu.addItem(typing)

        let middleClick = toggle("Three-Finger Tap = Middle Click",
                                 state.settings.threeFingerMiddleClick,
                                 #selector(MenuTarget.middleClickToggled))
        if !state.accessibilityGranted {
            middleClick.isEnabled = false
            middleClick.toolTip = "Requires Accessibility permission"
        }
        menu.addItem(middleClick)

        menu.addItem(.separator())

        // ---- Modifier -----------------------------------------------------
        menu.addItem(modifierSubmenuItem(current: state.settings.modifierMode,
                                         accessibilityGranted: state.accessibilityGranted))

        // ---- Brightness target -------------------------------------------
        menu.addItem(brightnessTargetSubmenuItem(state: state))

        menu.addItem(.separator())

        // ---- System -------------------------------------------------------
        let login = toggle("Launch at Login",
                           state.launchAtLoginState.isEnabled,
                           #selector(MenuTarget.launchAtLoginToggled))
        if case .unavailable(let reason) = state.launchAtLoginState {
            login.isEnabled = false
            login.toolTip = reason
        }
        if state.launchAtLoginState == .requiresApproval {
            login.toolTip = "Approve \(Branding.displayName) in System Settings > General > Login Items"
        }
        menu.addItem(login)

        let permissions = item("Permissions\u{2026}", #selector(MenuTarget.permissionsOpened))
        permissions.image = NSImage(
            systemSymbolName: state.accessibilityGranted ? "checkmark.shield" : "exclamationmark.shield",
            accessibilityDescription: nil)
        menu.addItem(permissions)

        menu.addItem(item("Settings\u{2026}", #selector(MenuTarget.settingsOpened), key: ","))
        menu.addItem(item("Diagnostics\u{2026}", #selector(MenuTarget.diagnosticsOpened)))

        menu.addItem(.separator())
        menu.addItem(item("About \(Branding.displayName)", #selector(MenuTarget.aboutShown)))
        menu.addItem(item("Quit \(Branding.displayName)", #selector(MenuTarget.quitSelected), key: "q"))

        // One target object retained by the menu keeps the selectors alive.
        let target = MenuTarget(handler: handler)
        assign(target: target, in: menu)
        menu.esRetainedTarget = target

        return menu
    }

    // MARK: Submenus

    private func edgeSubmenuItem(title: String,
                                 edge: TrackpadEdge,
                                 current: EdgeAssignment) -> NSMenuItem {
        let item = NSMenuItem(title: "\(title): \(current.displayName)", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for assignment in [EdgeAssignment.brightness, .volume, .none] {
            let option = NSMenuItem(title: assignment.displayName,
                                    action: edge == .left
                                        ? #selector(MenuTarget.leftAssignmentChosen(_:))
                                        : #selector(MenuTarget.rightAssignmentChosen(_:)),
                                    keyEquivalent: "")
            option.state = assignment == current ? .on : .off
            option.representedObject = assignment.rawValue
            submenu.addItem(option)
        }
        item.submenu = submenu
        return item
    }

    private func hapticSubmenuItem(state: MenuState) -> NSMenuItem {
        let enabled = state.settings.hapticsEnabled
        let label = enabled ? state.settings.hapticStrength.displayName : "Off"
        let item = NSMenuItem(title: "Haptic Feedback: \(label)", action: nil, keyEquivalent: "")

        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let off = NSMenuItem(title: "Off",
                             action: #selector(MenuTarget.hapticsOffChosen),
                             keyEquivalent: "")
        off.state = enabled ? .off : .on
        submenu.addItem(off)
        submenu.addItem(.separator())

        for strength in HapticStrength.allCases {
            let option = NSMenuItem(title: strength.displayName,
                                    action: #selector(MenuTarget.hapticStrengthChosen(_:)),
                                    keyEquivalent: "")
            option.state = (enabled && state.settings.hapticStrength == strength) ? .on : .off
            option.representedObject = strength.rawValue
            submenu.addItem(option)
        }

        item.submenu = submenu
        return item
    }

    private func modifierSubmenuItem(current: ModifierMode,
                                     accessibilityGranted: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: "Modifier: \(current.displayName)", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let none = NSMenuItem(title: "None",
                              action: #selector(MenuTarget.modifierChosen(_:)),
                              keyEquivalent: "")
        none.state = current == .none ? .on : .off
        none.representedObject = "none"
        submenu.addItem(none)

        submenu.addItem(.separator())
        for key in ModifierKeyChoice.allCases {
            let option = NSMenuItem(title: "Hold \(key.displayName)",
                                    action: #selector(MenuTarget.modifierChosen(_:)),
                                    keyEquivalent: "")
            option.state = current == .hold(key) ? .on : .off
            option.representedObject = "hold:\(key.rawValue)"
            submenu.addItem(option)
        }

        submenu.addItem(.separator())
        for key in ModifierKeyChoice.allCases {
            let option = NSMenuItem(title: "Toggle with \(key.displayName)",
                                    action: #selector(MenuTarget.modifierChosen(_:)),
                                    keyEquivalent: "")
            option.state = current == .toggle(key) ? .on : .off
            option.representedObject = "toggle:\(key.rawValue)"
            if !accessibilityGranted {
                option.isEnabled = false
                option.toolTip = "Toggle mode requires Accessibility permission"
            }
            submenu.addItem(option)
        }

        item.submenu = submenu
        return item
    }

    private func brightnessTargetSubmenuItem(state: MenuState) -> NSMenuItem {
        let pinned = state.settings.pinnedDisplayID
        let currentTitle: String = {
            if let pinned, let display = state.controllableDisplays.first(where: { $0.id == pinned }) {
                return display.name
            }
            return state.settings.brightnessTarget.displayName
        }()

        let item = NSMenuItem(title: "Brightness Target: \(currentTitle)",
                              action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        for target in BrightnessTarget.allCases {
            let option = NSMenuItem(title: target.displayName,
                                    action: #selector(MenuTarget.brightnessTargetChosen(_:)),
                                    keyEquivalent: "")
            option.state = (pinned == nil && state.settings.brightnessTarget == target) ? .on : .off
            option.representedObject = target.rawValue
            submenu.addItem(option)
        }

        if !state.controllableDisplays.isEmpty {
            submenu.addItem(.separator())
            let header = NSMenuItem(title: "Specific Display", action: nil, keyEquivalent: "")
            header.isEnabled = false
            submenu.addItem(header)

            for display in state.controllableDisplays {
                let option = NSMenuItem(
                    title: "\(display.name)  (\(display.capabilities.backend.displayName))",
                    action: #selector(MenuTarget.displayPinned(_:)),
                    keyEquivalent: "")
                option.state = pinned == display.id ? .on : .off
                option.representedObject = NSNumber(value: display.id)
                submenu.addItem(option)
            }
        }

        item.submenu = submenu
        return item
    }

    // MARK: Item helpers

    private func item(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        NSMenuItem(title: title, action: selector, keyEquivalent: key)
    }

    private func toggle(_ title: String, _ isOn: Bool, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.state = isOn ? .on : .off
        return item
    }

    private func assign(target: MenuTarget, in menu: NSMenu) {
        for item in menu.items {
            if item.action != nil { item.target = target }
            if let submenu = item.submenu { assign(target: target, in: submenu) }
        }
    }
}

// MARK: - Selector target

/// Menu items need an Objective-C target. Keeping it separate means the builder
/// stays a pure function of `MenuState`.
@MainActor
final class MenuTarget: NSObject {
    private weak var handler: MenuActionHandling?

    init(handler: MenuActionHandling?) {
        self.handler = handler
    }

    @objc func enabledToggled() { handler?.toggleEnabled() }
    @objc func fineToggled() { handler?.toggleFineControl() }
    @objc func swapToggled() { handler?.toggleSwapSides() }
    @objc func bottomQuarterToggled() { handler?.toggleBottomQuarter() }
    @objc func freezeCursorToggled() { handler?.toggleFreezeCursor() }
    @objc func hapticsToggled() { handler?.toggleHaptics() }

    @objc func hapticsOffChosen() {
        handler?.toggleHaptics()
    }

    @objc func hapticStrengthChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let strength = HapticStrength(rawValue: raw) else { return }
        handler?.setHapticStrength(strength)
    }
    @objc func hudToggled() { handler?.toggleNativeHUD() }
    @objc func smartTypingToggled() { handler?.toggleSmartTyping() }
    @objc func middleClickToggled() { handler?.toggleThreeFingerMiddleClick() }
    @objc func launchAtLoginToggled() { handler?.toggleLaunchAtLogin() }
    @objc func permissionsOpened() { handler?.openPermissions() }
    @objc func settingsOpened() { handler?.openSettings() }
    @objc func diagnosticsOpened() { handler?.openDiagnostics() }
    @objc func aboutShown() { handler?.showAbout() }
    @objc func quitSelected() { handler?.quit() }

    @objc func leftAssignmentChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let assignment = EdgeAssignment(rawValue: raw) else { return }
        handler?.setEdgeAssignment(assignment, for: .left)
    }

    @objc func rightAssignmentChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let assignment = EdgeAssignment(rawValue: raw) else { return }
        handler?.setEdgeAssignment(assignment, for: .right)
    }

    @objc func modifierChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        if raw == "none" {
            handler?.setModifierMode(.none)
            return
        }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let key = ModifierKeyChoice(rawValue: parts[1]) else { return }
        handler?.setModifierMode(parts[0] == "hold" ? .hold(key) : .toggle(key))
    }

    @objc func brightnessTargetChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let target = BrightnessTarget(rawValue: raw) else { return }
        handler?.pinDisplay(nil)
        handler?.setBrightnessTarget(target)
    }

    @objc func displayPinned(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        handler?.pinDisplay(number.uint32Value)
    }
}

// MARK: - Keeping the target alive

private var esMenuTargetKey: UInt8 = 0

extension NSMenu {
    /// The menu is rebuilt on every open, so the target has to be owned by the
    /// menu rather than by the builder.
    var esRetainedTarget: AnyObject? {
        get { objc_getAssociatedObject(self, &esMenuTargetKey) as AnyObject? }
        set { objc_setAssociatedObject(self, &esMenuTargetKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }
}
