// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PlayerKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "PlayerKit", targets: ["PlayerKit"]),
    ],
    targets: [
        .target(
            name: "PlayerKit",
            path: "Sources/PlayerKit",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "PlayerKitTests",
            dependencies: ["PlayerKit"],
            path: "Tests/PlayerKitTests"
        ),
    ]
)
