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
            name: "OnDeviceCaptionKit"
        ),
        .testTarget(
            name: "OnDeviceCaptionKitTests",
            dependencies: ["OnDeviceCaptionKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
