// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ControlTower",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "ControlTower", targets: ["ControlTower"]),
        .executable(name: "ct", targets: ["ControlTowerCLI"]),
        .library(name: "ControlTowerCore", targets: ["ControlTowerCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.6.0"),
    ],
    targets: [
        // Core library (cross-platform where possible)
        .target(
            name: "ControlTowerCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        // macOS menu bar app
        .executableTarget(
            name: "ControlTower",
            dependencies: [
                "ControlTowerCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/ControlTower",
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .define("ENABLE_SPARKLE"),
            ]
        ),

        // CLI tool
        .executableTarget(
            name: "ControlTowerCLI",
            dependencies: [
                "ControlTowerCore",
            ],
            path: "Sources/ControlTowerCLI"
        ),

        // Tests
        .testTarget(
            name: "ControlTowerCoreTests",
            dependencies: ["ControlTowerCore"],
            path: "Tests/ControlTowerCoreTests"
        ),
    ]
)
