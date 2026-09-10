//
//  Logger.swift
//  GlisseKit
//
//  OSLog categories. Release builds stay quiet: anything that could fire at
//  trackpad-frame frequency goes through `Log.diagnostic`, which is a no-op
//  unless the user turns on diagnostic logging.
//

import Foundation
import OSLog

public enum Log {
    static let subsystem = Branding.bundleIdentifier

    public static let app        = Logger(subsystem: subsystem, category: "app")
    public static let lifecycle  = Logger(subsystem: subsystem, category: "lifecycle")
    public static let permissions = Logger(subsystem: subsystem, category: "permissions")
    public static let trackpad   = Logger(subsystem: subsystem, category: "trackpad")
    public static let gesture    = Logger(subsystem: subsystem, category: "gesture")
    public static let audio      = Logger(subsystem: subsystem, category: "audio")
    public static let brightness = Logger(subsystem: subsystem, category: "brightness")
    public static let ddc        = Logger(subsystem: subsystem, category: "ddc")
    public static let hud        = Logger(subsystem: subsystem, category: "hud")
    public static let haptics    = Logger(subsystem: subsystem, category: "haptics")
    public static let input      = Logger(subsystem: subsystem, category: "input")
    public static let settings   = Logger(subsystem: subsystem, category: "settings")

    /// Diagnostic logging switch. Off by default; toggled from Settings.
    ///
    /// Read from arbitrary threads (including the multitouch callback thread),
    /// so it is an atomic-ish `nonisolated(unsafe)` Bool rather than a lock —
    /// a torn read of a Bool is not a correctness problem here.
    nonisolated(unsafe) public static var diagnosticsEnabled = false

    /// High-frequency logging. Compiled in but gated at runtime, and the message
    /// is only built when diagnostics are on — important because these calls sit
    /// on the per-frame gesture path.
    @inlinable
    public static func diagnostic(_ logger: Logger, _ message: @autoclosure () -> String) {
        guard diagnosticsEnabled else { return }
        let text = message()
        logger.debug("\(text, privacy: .public)")
    }
}
