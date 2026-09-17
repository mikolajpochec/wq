// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "WindowQueue",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WindowQueue",
            path: "Sources/WindowQueue",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WindowQueueTests",
            dependencies: ["WindowQueue"],
            path: "Tests/WindowQueueTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
