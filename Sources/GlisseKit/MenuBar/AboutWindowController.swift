//
//  AboutWindowController.swift
//  GlisseKit
//
//  A small About panel, which exists mainly so the logo has somewhere to live at
//  a size where the wordmark is legible. The menu bar can only carry an 16 pt
//  glyph; this is where the mark and the name appear together.
//
//  Deliberately a plain window rather than an NSAlert: an alert would force the
//  name to be repeated as its message text, next to a wordmark already saying it.
//

import AppKit
import Foundation

@MainActor
final class AboutWindowController: NSObject {

    private var window: NSWindow?

    func show() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let size = NSSize(width: 380, height: 250)
        let container = NSView(frame: NSRect(origin: .zero, size: size))

        // Logo lockup: mark + wordmark, tinted so it tracks light and dark mode.
        let lockup = LogoArtwork.lockup(pointSize: 34, color: .labelColor)
        let logoView = NSImageView(image: lockup)
        logoView.imageScaling = .scaleProportionallyDown
        logoView.frame = NSRect(x: (size.width - lockup.size.width) / 2,
                                y: size.height - lockup.size.height - 42,
                                width: lockup.size.width,
                                height: lockup.size.height)
        container.addSubview(logoView)

        let version = NSTextField(labelWithString: "Version \(Branding.version)")
        version.font = .systemFont(ofSize: 11)
        version.textColor = .secondaryLabelColor
        version.alignment = .center
        version.frame = NSRect(x: 0, y: logoView.frame.minY - 26, width: size.width, height: 16)
        container.addSubview(version)

        let blurb = NSTextField(wrappingLabelWithString: """
            Slide along the left or right edge of the trackpad to change brightness \
            and volume.

            Personal-use utility. No accounts, no telemetry, no network access.
            """)
        blurb.font = .systemFont(ofSize: 11)
        blurb.textColor = .secondaryLabelColor
        blurb.alignment = .center
        blurb.frame = NSRect(x: 30, y: 62, width: size.width - 60, height: 62)
        container.addSubview(blurb)

        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"
        close.frame = NSRect(x: (size.width - 90) / 2, y: 20, width: 90, height: 24)
        container.addSubview(close)

        let created = NSWindow(contentRect: container.bounds,
                               styleMask: [.titled, .closable],
                               backing: .buffered,
                               defer: false)
        created.title = "About \(Branding.displayName)"
        created.contentView = container
        created.isReleasedWhenClosed = false
        created.titlebarAppearsTransparent = true
        window = created
    }

    @objc private func closeWindow() {
        window?.close()
    }
}
