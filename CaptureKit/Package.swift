// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CaptureKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "CaptureKit", targets: ["CaptureKit"]),
    ],
    targets: [
        .target(
            name: "CaptureKit",
            path: "Sources/CaptureKit",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "CaptureKitTests",
            dependencies: ["CaptureKit"],
            path: "Tests/CaptureKitTests"
        ),
    ]
)
