// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OnDeviceCaptionKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "OnDeviceCaptionKit", targets: ["OnDeviceCaptionKit"]),
    ],
    targets: [
        .target(
            name: "OnDeviceCaptionKit",
            swiftSettings: [
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        .testTarget(
            name: "OnDeviceCaptionKitTests",
            dependencies: ["OnDeviceCaptionKit"],
            swiftSettings: [
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
