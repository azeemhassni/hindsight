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
        .library(name: "HindsightProtocol", targets: ["HindsightProtocol"]),
        .library(name: "HindsightKeychain", targets: ["HindsightKeychain"]),
        .library(name: "HindsightCoolify", targets: ["HindsightCoolify"]),
        .library(name: "HindsightRestore", targets: ["HindsightRestore"]),
        .library(name: "HindsightUI", targets: ["HindsightUI"]),
        .executable(name: "hindsight-agent", targets: ["hindsight-agent"]),
        .executable(name: "hindsight-demo-catalog", targets: ["hindsight-demo-catalog"]),
        .library(name: "HindsightAgentKit", targets: ["HindsightAgentKit"]),
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
            name: "HindsightUI",
            dependencies: [
                "HindsightCore",
                "HindsightCatalog",
                "HindsightCoolify",
                "HindsightProtocol",
                "HindsightRestore",
                "HindsightSchedule",
            ],
            swiftSettings: .common
        ),
        .target(
            name: "HindsightRestore",
            dependencies: [
                "HindsightCore",
                "HindsightCoolify",
                "HindsightProcess",
                "HindsightRestic",
                "HindsightSSH",
            ],
            swiftSettings: .common
        ),
        .target(
            name: "HindsightCoolify",
            dependencies: ["HindsightCore", "HindsightProcess", "HindsightSSH"],
            swiftSettings: .common
        ),
        .target(
            name: "HindsightKeychain",
            dependencies: ["HindsightCore"],
            swiftSettings: .common
        ),
        .target(
            name: "HindsightProtocol",
            dependencies: ["HindsightCore"],
            swiftSettings: .common
        ),
        .executableTarget(
            name: "hindsight-demo-catalog",
            dependencies: ["HindsightCatalog", "HindsightCore"],
            path: "scripts",
            sources: ["demo-catalog.swift"],
            swiftSettings: .common
        ),
        .executableTarget(
            name: "hindsight-agent",
            dependencies: ["HindsightAgentKit"],
            swiftSettings: .common
        ),
        .target(
            name: "HindsightAgentKit",
            dependencies: [
                "HindsightCore",
                "HindsightCatalog",
                "HindsightEngine",
                "HindsightProtocol",
                "HindsightRestic",
                "HindsightSSH",
                "HindsightSchedule",
                "HindsightKeychain",
            ],
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
                "HindsightCoolify",
                "HindsightRestore",
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
            name: "HindsightUITests",
            dependencies: ["HindsightUI"],
            swiftSettings: .common
        ),
        .testTarget(
            name: "HindsightRestoreTests",
            dependencies: ["HindsightRestore", "HindsightTestSupport"],
            swiftSettings: .common
        ),
        .testTarget(
            name: "HindsightCoolifyTests",
            dependencies: ["HindsightCoolify", "HindsightTestSupport"],
            swiftSettings: .common
        ),
        .testTarget(
            name: "HindsightKeychainTests",
            dependencies: ["HindsightKeychain"],
            swiftSettings: .common
        ),
        .testTarget(
            name: "HindsightProtocolTests",
            dependencies: ["HindsightProtocol"],
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
