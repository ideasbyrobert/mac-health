// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mac-health",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "mac-health", targets: ["MacHealthCLI"]),
        .library(name: "MacHealthKit", targets: ["MacHealthKit"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "MacHealthKit",
            dependencies: [],
            path: "Sources/MacHealthKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MacHealthCLI",
            dependencies: ["MacHealthKit"],
            path: "Sources/MacHealthCLI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MacHealthKitTests",
            dependencies: ["MacHealthKit"],
            path: "Tests/MacHealthKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
