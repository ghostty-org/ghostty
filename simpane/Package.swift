// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SimPane",
    // Deliberately not raised to the Ghostty app's own minimum: keeping the
    // package at the same floor as Ghostty's Xcode target means Phase 4 can
    // vendor it without touching MACOSX_DEPLOYMENT_TARGET, and gate the pane
    // itself with @available instead.
    platforms: [.macOS(.v13)],
    products: [
        // The library Ghostty consumes.
        .library(name: "SimPaneKit", targets: ["SimPaneKit"]),
        .executable(name: "simdump", targets: ["SimDump"]),
        .executable(name: "SimPanePOC", targets: ["SimPanePOC"]),
    ],
    targets: [
        // ObjC dispatch + exception-catching glue. Required because CoreSimulator
        // hands back ROCK XPC proxies that KVC and -respondsToSelector: cannot
        // interrogate correctly.
        .target(name: "SimPaneObjC"),

        // Pure logic with no private-API or AppKit dependency: the Indigo wire
        // format, coordinate mapping, and the keycode table. Kept separate so it
        // can be unit-tested without a simulator.
        .target(name: "SimPaneCore"),

        // The reusable library. Everything that touches a private framework lives
        // in Private/PrivateSim.swift; the rest is ordinary AppKit and Foundation.
        .target(name: "SimPaneKit", dependencies: ["SimPaneCore", "SimPaneObjC"]),

        // Phase 0 recon tool. Dumps the live private-API surface of
        // CoreSimulator/SimulatorKit on the machine it runs on. Kept in-tree so
        // the selector inventory can be re-derived after an Xcode update.
        .executableTarget(name: "SimDump", dependencies: ["SimPaneObjC"]),

        // Proof that the library's public API is sufficient, and the harness the
        // reliability diagnostics run in. Holds no private API of its own.
        .executableTarget(name: "SimPanePOC", dependencies: ["SimPaneKit", "SimPaneCore"]),

        .testTarget(name: "SimPaneCoreTests", dependencies: ["SimPaneCore"]),
        .testTarget(name: "SimPaneKitTests", dependencies: ["SimPaneKit"]),
    ]
)
