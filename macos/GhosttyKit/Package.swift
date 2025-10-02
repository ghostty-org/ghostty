// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "GhosttyKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "GhosttyKit",
            targets: [
                "GhosttyKit"
            ]
        ),
    ],
    targets: [
        .target(
            name: "GhosttyKit",
            dependencies: [
                "CGhosttyKit"
            ],
            linkerSettings: [
                .unsafeFlags(["-lstdc++"])
            ]
        ),
        .binaryTarget(name: "CGhosttyKit", path: "../CGhosttyKit.xcframework"),
        .testTarget(
            name: "GhosttyKitTests",
            dependencies: [
                "GhosttyKit"
            ],
            resources: [
                .copy("testdata")
            ]
        ),
    ]
)
