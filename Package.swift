// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UsageBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "UsageBar", targets: ["UsageBar"]),
        .library(name: "UsageBarCore", targets: ["UsageBarCore"]),
    ],
    targets: [
        .target(
            name: "UsageBarCore",
            path: "Sources/UsageBarCore"
        ),
        .executableTarget(
            name: "UsageBar",
            dependencies: ["UsageBarCore"],
            path: "Sources/UsageBar",
            resources: [
                .copy("Logos"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "UsageBarCoreTests",
            dependencies: ["UsageBarCore"],
            path: "Tests/UsageBarCoreTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
