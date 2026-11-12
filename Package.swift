// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Orol",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Orol",
            path: "Sources/Orol",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
                .linkedFramework("Speech"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(
            name: "orol-hook",
            path: "Sources/orol-hook"
        ),
    ]
)
