// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "check-accessibility",
    platforms: [
        .macOS(.v13),
    ],
    targets: [
        .executableTarget(
            name: "check-accessibility",
            path: "Sources"
        ),
    ]
)
