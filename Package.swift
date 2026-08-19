// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "mac-health",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "mac-health", targets: ["MacHealth"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "MacHealth",
            dependencies: [],
            path: "Sources/MacHealth"
        )
    ]
)
