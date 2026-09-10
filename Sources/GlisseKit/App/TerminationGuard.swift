//
//  TerminationGuard.swift
//  GlisseKit
//
//  Makes SIGTERM / SIGINT / SIGHUP run the same clean shutdown as Quit.
//
//  This matters specifically because of cursor freeze. `applicationWillTerminate`
//  is not called for a signal, and the default SIGTERM disposition kills the
//  process without running `atexit` handlers — so `pkill Glisse` (or a
//  `killall` during development, or an installer replacing the app) while the
//  pointer was detached would leave the Mac looking frozen until the user logged
//  out.
//
//  Signals are handled through DispatchSource rather than a C signal handler, so
//  the cleanup runs on a normal thread and is free to take locks and call
//  CoreGraphics.
//

import Foundation

@MainActor
public final class TerminationGuard {

    private var sources: [DispatchSourceSignal] = []
    private let handler: () -> Void
    private var hasRun = false

    /// - Parameter handler: cleanup to run before the process exits. Must be
    ///   idempotent, because Quit can race a signal.
    public init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    public func install() {
        let signals: [Int32] = [SIGTERM, SIGINT, SIGHUP]
        for number in signals {
            // Disable the default disposition so the process is not torn down
            // before the DispatchSource gets a chance to fire.
            signal(number, SIG_IGN)

            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.runCleanupAndExit(signal: number)
                }
            }
            source.resume()
            sources.append(source)
        }
        Log.lifecycle.info("termination guard installed")
    }

    private func runCleanupAndExit(signal number: Int32) {
        guard !hasRun else { return }
        hasRun = true
        Log.lifecycle.info("received signal \(number, privacy: .public); cleaning up")
        handler()
        // Flush the log before the process disappears.
        exit(0)
    }

    /// Called from the normal Quit path so a later signal cannot double-run.
    public func markCleanupComplete() {
        hasRun = true
    }
}
