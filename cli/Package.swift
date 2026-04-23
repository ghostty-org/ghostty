// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "gt",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "gt", targets: ["gt"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", "1.3.0"..<"2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "gt",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/gt"
        )
    ]
)
