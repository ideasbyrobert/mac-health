// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mac-health",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "mac-health", targets: ["MacHealthCLI"]),
        .library(name: "MacHealthKit", targets: ["MacHealthKit"]),
        .library(name: "EnergyLab", targets: ["EnergyLab"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "MacHealthKit",
            dependencies: [],
            path: "Sources/MacHealthKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The wait-for graph, energy sampling, and pathology classification.
        // Kept separate from MacHealthKit because it answers a different
        // question: not "is this machine faulty" but "where is work waiting".
        .target(
            name: "EnergyLab",
            dependencies: ["MacHealthKit"],
            path: "Sources/EnergyLab",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Real processes that misbehave in one precisely named way each, so the
        // lab measures observed behaviour rather than a simulation of it.
        .executableTarget(
            name: "chaos-worker",
            dependencies: [],
            path: "Sources/ChaosWorker"
        ),
        // Built into a real .app bundle by `make app`; SwiftPM alone produces a
        // bare executable with no bundle identity.
        .executableTarget(
            name: "EnergyLabApp",
            dependencies: ["MacHealthKit", "EnergyLab"],
            path: "Sources/EnergyLabApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MacHealthCLI",
            dependencies: ["MacHealthKit", "EnergyLab"],
            path: "Sources/MacHealthCLI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MacHealthKitTests",
            dependencies: ["MacHealthKit", "EnergyLab"],
            path: "Tests/MacHealthKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
