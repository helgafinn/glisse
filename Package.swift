// swift-tools-version: 6.0
//
// Glisse — native macOS trackpad edge volume & brightness controller.
//
// Build system notes
// ------------------
// SwiftPM is used instead of an .xcodeproj so the project builds with either a
// full Xcode install *or* the Command Line Tools alone. `make` wraps this
// package and assembles a real LSUIElement .app bundle (see Makefile).
//
// Xcode users can simply `open Package.swift`.
//
// Language mode: .v5.
// The Swift 6.4 compiler is used, but strict Swift 6 data-race checking is not
// enabled for the AppKit/C-interop layers: raw MultitouchSupport callbacks,
// CGEventTap callbacks and the OSD bridge all cross non-Sendable C boundaries
// that cannot be annotated without wrapping every Apple type. Isolation is
// instead enforced explicitly and narrowly:
//   * `GestureCoordinator`, `DisplayManager`, `DDCScheduler` are actors.
//   * Everything that touches AppKit is `@MainActor`.
//   * Raw-callback code paths only touch immutable value types + one lock.
// `GlisseKit` still compiles with `-warn-concurrency` style diagnostics off
// but the pure gesture core is `Sendable` end to end and unit tested.

import PackageDescription

let package = Package(
    name: "Glisse",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Glisse", targets: ["Glisse"]),
        .library(name: "GlisseKit", targets: ["GlisseKit"]),
    ],
    targets: [
        // ------------------------------------------------------------------
        // Private / unsafe C & Objective-C bridges.
        //
        // Nothing here is linked against a private framework at build time —
        // every private symbol is resolved with dlopen/dlsym at runtime so a
        // removed symbol degrades to a feature being unavailable instead of a
        // launch-time dyld abort.
        // ------------------------------------------------------------------
        .target(
            name: "GlissePrivate",
            path: "Sources/GlissePrivate",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include")
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
            ]
        ),

        // ------------------------------------------------------------------
        // All application logic. A library (not the executable) so the test
        // target can import it.
        // ------------------------------------------------------------------
        .target(
            name: "GlisseKit",
            dependencies: ["GlissePrivate"],
            path: "Sources/GlisseKit",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Combine"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),

        // ------------------------------------------------------------------
        // Thin executable shim.
        // ------------------------------------------------------------------
        .executableTarget(
            name: "Glisse",
            dependencies: ["GlisseKit"],
            path: "Sources/Glisse",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),

        .testTarget(
            name: "GlisseTests",
            dependencies: ["GlisseKit"],
            path: "Tests/GlisseTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
