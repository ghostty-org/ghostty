// swift-tools-version: 5.9
import PackageDescription

let libPath = "/Users/hue/Documents/ghostty-kanban/demo/libghostty-internal.a"

let package = Package(
    name: "GhosttyDemo",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "GhosttyDemo",
            dependencies: ["GhosttyRuntime"]
        ),
        .target(
            name: "GhosttyRuntime",
            dependencies: ["GhosttyKit", "GhosttyObjC"],
            path: "Sources/GhosttyRuntime"
        ),
        .target(
            name: "GhosttyObjC",
            path: "Sources/GhosttyObjC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "GhosttyKit",
            publicHeadersPath: "include",
            cSettings: [.define("GHOSTTY_STATIC")],
            linkerSettings: [
                .unsafeFlags([libPath]),
                .unsafeFlags(["-framework", "Cocoa"]),
                .unsafeFlags(["-framework", "Metal"]),
                .unsafeFlags(["-framework", "MetalKit"]),
                .unsafeFlags(["-framework", "Carbon"]),
                .unsafeFlags(["-framework", "CoreGraphics"]),
                .unsafeFlags(["-framework", "CoreVideo"]),
                .unsafeFlags(["-framework", "IOSurface"]),
                .unsafeFlags(["-framework", "IOKit"]),
                .unsafeFlags(["-framework", "UniformTypeIdentifiers"]),
                .unsafeFlags(["-framework", "UserNotifications"]),
                .unsafeFlags(["-lc++"]),
                .unsafeFlags(["-lz"]),
            ]
        )
    ]
)
