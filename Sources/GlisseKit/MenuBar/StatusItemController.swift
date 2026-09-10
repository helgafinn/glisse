//
//  StatusItemController.swift
//  GlisseKit
//
//  The menu bar presence. Rebuilds the menu lazily when it is about to open, so
//  nothing is recomputed while the app sits idle.
//

import AppKit
import Foundation

@MainActor
public final class StatusItemController: NSObject, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private let builder: MenuBuilder
    private var stateProvider: () -> MenuState

    public init(handler: MenuActionHandling, stateProvider: @escaping () -> MenuState) {
        self.builder = MenuBuilder(handler: handler)
        self.stateProvider = stateProvider
        super.init()
    }

    public func install() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.behavior = []
        statusItem = item

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        refresh()
        Log.app.info("status item installed")
    }

    public func remove() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    /// Updates the icon. Cheap; safe to call on every settings change.
    public func refresh() {
        guard let button = statusItem?.button else { return }
        let state = stateProvider()

        let image: NSImage?
        if let symbol = state.statusSymbolName {
            let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            image = NSImage(systemSymbolName: symbol,
                            accessibilityDescription: Branding.displayName)?
                .withSymbolConfiguration(configuration)
            image?.isTemplate = true
        } else {
            // The drawn mark. A template image, so macOS handles light, dark and
            // the highlighted state while the menu is open.
            image = LogoArtwork.menuBarImage(pointSize: 17)
            image?.accessibilityDescription = Branding.displayName
        }
        button.image = image
        // Dimmed rather than hidden: the state is visible without being loud.
        button.alphaValue = state.statusIconIsDimmed ? 0.45 : 1.0
        button.toolTip = tooltip(for: state)
    }

    private func tooltip(for state: MenuState) -> String {
        var lines = [Branding.displayName]
        if !state.settings.isEnabled {
            lines.append("Disabled")
        } else if state.isToggledOff {
            lines.append("Paused (modifier toggle)")
        } else if state.trackpadCount == 0 {
            lines.append("No trackpad detected")
        } else {
            lines.append("Left: \(state.settings.assignment(for: .left).displayName)")
            lines.append("Right: \(state.settings.assignment(for: .right).displayName)")
        }
        if let problem = state.problem {
            lines.append(problem)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: NSMenuDelegate

    public func menuNeedsUpdate(_ menu: NSMenu) {
        let state = stateProvider()
        let rebuilt = builder.buildMenu(state: state)

        menu.removeAllItems()
        // Items cannot belong to two menus, so move them across.
        for item in rebuilt.items {
            rebuilt.removeItem(item)
            menu.addItem(item)
        }
        menu.esRetainedTarget = rebuilt.esRetainedTarget
        refresh()
    }
}
