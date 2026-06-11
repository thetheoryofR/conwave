// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioSyncKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AudioSyncKit", targets: ["AudioSyncKit"]),
    ],
    targets: [
        .target(
            name: "AudioSyncKit",
            dependencies: [],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "AudioSyncKitTests",
            dependencies: ["AudioSyncKit"]
        ),
    ]
)
