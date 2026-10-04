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
            dependencies: ["HindsightRestic"],
            swiftSettings: .common
        ),
        .testTarget(
            name: "HindsightSSHTests",
            dependencies: ["HindsightSSH"],
            swiftSettings: .common
        ),
        .testTarget(
            name: "HindsightCatalogTests",
            dependencies: ["HindsightCatalog"],
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
