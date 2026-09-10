//
//  DiagnosticsWindowController.swift
//  GlisseKit
//
//  A plain monospaced text dump: touch source state, resolved MTTouch layout,
//  live gesture numbers, audio device, display backends, HUD provider.
//
//  This is the window that answers "why did it not trigger" and "which backend
//  is my monitor using". It refreshes while visible and stops the moment it is
//  closed, so it costs nothing when not in use.
//

import AppKit
import Foundation

@MainActor
final class DiagnosticsWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var textView: NSTextView?
    private var timer: DispatchSourceTimer?
    private let textProvider: () -> String

    init(textProvider: @escaping () -> String) {
        self.textProvider = textProvider
        super.init()
    }

    func show() {
        if window == nil { build() }
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        startRefreshing()
    }

    private func build() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 620, height: 520))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.autoresizingMask = [.width]
        scroll.documentView = text
        textView = text

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 560))
        scroll.frame = NSRect(x: 0, y: 40, width: 620, height: 520)
        scroll.autoresizingMask = [.width, .height]
        container.addSubview(scroll)

        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyToClipboard))
        copyButton.frame = NSRect(x: 12, y: 8, width: 90, height: 24)
        copyButton.bezelStyle = .rounded
        container.addSubview(copyButton)

        let hint = NSTextField(labelWithString: "Refreshes twice a second while this window is open.")
        hint.frame = NSRect(x: 112, y: 12, width: 400, height: 18)
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        container.addSubview(hint)

        let created = NSWindow(contentRect: container.bounds,
                               styleMask: [.titled, .closable, .resizable, .miniaturizable],
                               backing: .buffered,
                               defer: false)
        created.title = "\(Branding.displayName) Diagnostics"
        created.contentView = container
        created.isReleasedWhenClosed = false
        created.delegate = self
        created.center()
        window = created
    }

    func reload() {
        guard let textView else { return }
        // Refresh while visible, and once on first build so the window is never
        // shown empty. (Written out explicitly: `a ?? b || c` parses as
        // `a ?? (b || c)`, which is not what this means.)
        let isVisible = window?.isVisible ?? false
        guard isVisible || textView.string.isEmpty else { return }
        // Preserve the scroll position so a reader is not yanked to the top.
        let visibleRect = textView.enclosingScrollView?.contentView.bounds
        textView.string = textProvider()
        if let visibleRect {
            textView.enclosingScrollView?.contentView.scroll(to: visibleRect.origin)
            textView.enclosingScrollView?.reflectScrolledClipView(
                textView.enclosingScrollView!.contentView)
        }
    }

    private func startRefreshing() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 0.5, repeating: 0.5)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true else {
                    self?.stopRefreshing()
                    return
                }
                self.reload()
            }
        }
        timer = source
        source.resume()
    }

    private func stopRefreshing() {
        timer?.cancel()
        timer = nil
    }

    @objc private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(textView?.string ?? "", forType: .string)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        stopRefreshing()
    }
}
