// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hindsight",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HindsightCore", targets: ["HindsightCore"]),
        .library(name: "HindsightProcess", targets: ["HindsightProcess"]),
        .library(name: "HindsightRestic", targets: ["HindsightRestic"]),
        .library(name: "HindsightSSH", targets: ["HindsightSSH"]),
        .library(name: "HindsightCatalog", targets: ["HindsightCatalog"]),
        .library(name: "HindsightEngine", targets: ["HindsightEngine"]),
        .library(name: "HindsightSchedule", targets: ["HindsightSchedule"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(
            name: "HindsightCore",
            swiftSettings: .common
        ),
        .target(
            name: "HindsightProcess",
            dependencies: ["HindsightCore"],
            swiftSettings: .common
        ),
        .target(
            name: "HindsightRestic",
            dependencies: ["HindsightCore", "HindsightProcess"],
            swiftSettings: .common
        ),
        .target(
            name: "HindsightSSH",
            dependencies: ["HindsightCore", "HindsightProcess", "HindsightRestic"],
            swiftSettings: .common
        ),
        .target(
            name: "HindsightCatalog",
            dependencies: [
                "HindsightCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: .common
        ),
        .target(
            name: "HindsightSchedule",
            dependencies: ["HindsightCore"],
            swiftSettings: .common
        ),
        .target(
            name: "HindsightEngine",
            dependencies: [
                "HindsightCore",
                "HindsightProcess",
                "HindsightRestic",
                "HindsightSSH",
                "HindsightCatalog",
                "HindsightSchedule",
            ],
            swiftSettings: .common
        ),
        .target(
            name: "HindsightTestSupport",
            dependencies: ["HindsightCore", "HindsightProcess", "HindsightRestic", "HindsightSSH"],
            swiftSettings: .common
        ),
        .testTarget(
            name: "HindsightCoreTests",
            dependencies: ["HindsightCore"],
            swiftSettings: .common
        ),
        .testTarget(
            name: "HindsightProcessTests",
            dependencies: ["HindsightProcess", "HindsightCore"],
            swiftSettings: .common
        ),
        .testTarget(
            name: "HindsightResticTests",
            dependencies: ["HindsightRestic", "HindsightTestSupport"],
            swiftSettings: .common
        ),
        .testTarget(
            name: "HindsightSSHTests",
            dependencies: ["HindsightSSH", "HindsightTestSupport"],
            swiftSettings: .common
        ),
        .testTarget(
            name: "HindsightCatalogTests",
            dependencies: ["HindsightCatalog"],
            swiftSettings: .common
        ),
        .testTarget(
            name: "HindsightScheduleTests",
            dependencies: ["HindsightSchedule", "HindsightRestic", "HindsightTestSupport"],
            swiftSettings: .common
        ),
        .testTarget(
            name: "HindsightEngineTests",
            dependencies: ["HindsightEngine", "HindsightTestSupport"],
            swiftSettings: .common
        ),
    ],
    swiftLanguageModes: [.v6]
)

extension [SwiftSetting] {
    static let common: [SwiftSetting] = [
        .enableUpcomingFeature("ExistentialAny"),
    ]
}
