// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OpenBar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenBarCore", targets: ["OpenBarCore"]),
        .executable(name: "OpenBar", targets: ["OpenBar"]),
    ],
    targets: [
        .target(
            name: "OpenBarCore",
            path: "Sources/OpenBarCore"
        ),
        .executableTarget(
            name: "OpenBar",
            dependencies: ["OpenBarCore"],
            path: "Sources/OpenBar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Combine"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Security"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .executableTarget(
            name: "OpenBarCoreChecks",
            dependencies: ["OpenBarCore"],
            path: "Tests/OpenBarCoreChecks"
        ),
    ],
    swiftLanguageModes: [.v5]
)
