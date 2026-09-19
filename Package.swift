// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NotchMusic",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "NotchMusic", targets: ["NotchMusic"])
    ],
    targets: [
        .executableTarget(
            name: "NotchMusic",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Combine"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("IOKit"),
                .linkedFramework("Accelerate")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
