//
//  TouchSource.swift
//  GlisseKit
//
//  Two independent ways to observe trackpad contacts, behind one protocol.
//
//  Primary   MultitouchSupportTouchSource — private framework, no permission
//            needed, lowest latency, sees every contact.
//  Fallback  AppKitTouchSource — public NSTouch data lifted off a CGEventTap.
//            Needs Accessibility, but survives Apple removing MTTouch.
//
//  TrackpadManager picks one, and can swap at runtime if the primary reports a
//  layout failure.
//

import Foundation

public protocol TouchSource: AnyObject {
    var identifier: String { get }
    var isRunning: Bool { get }
    var devices: [TrackpadDevice] { get }

    /// Called on an arbitrary background thread, potentially at ~125 Hz per
    /// device. Must not block.
    var frameHandler: ((TrackpadFrame) -> Void)? { get set }

    /// Reports that this source has become unusable and the manager should try
    /// another one.
    var failureHandler: ((TrackpadError) -> Void)? { get set }

    func start() throws
    func stop()
    /// Full teardown and re-enumeration. Called on wake and on device hot-plug.
    func restart() throws

    func diagnosticsDescription() -> String
}
