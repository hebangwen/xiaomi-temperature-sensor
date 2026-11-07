// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MiSensor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MiSensorCore", targets: ["MiSensorCore"])
    ],
    targets: [
        .target(
            name: "MiSensorCore",
            path: "Sources/MiSensorCore"
        ),
        .executableTarget(
            name: "MiSensorCoreTests",
            dependencies: ["MiSensorCore"],
            path: "Tests/MiSensorCoreTests"
        )
    ]
)
