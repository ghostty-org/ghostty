// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ghostties-cli",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "gt", targets: ["gt"]),
        .executable(name: "ghostties-mcp", targets: ["ghostties-mcp"]),
        .library(name: "GhosttiesCore", targets: ["GhosttiesCore"]),
        .library(name: "GhosttiesMCPClient", targets: ["GhosttiesMCPClient"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", "1.3.0"..<"2.0.0")
    ],
    targets: [
        .target(
            name: "GhosttiesCore",
            path: "Sources/GhosttiesCore"
        ),
        .target(
            name: "GhosttiesMCPClient",
            dependencies: ["GhosttiesCore"],
            path: "Sources/GhosttiesMCPClient"
        ),
        .executableTarget(
            name: "gt",
            dependencies: [
                "GhosttiesCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/gt"
        ),
        .executableTarget(
            name: "ghostties-mcp",
            dependencies: ["GhosttiesCore"],
            path: "Sources/ghostties-mcp",
            exclude: ["README.md"]
        ),
        .testTarget(
            name: "GhosttiesMCPClientTests",
            dependencies: ["GhosttiesMCPClient"],
            path: "Tests/GhosttiesMCPClientTests"
        )
    ]
)
