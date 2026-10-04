// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hindsight",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HindsightCore", targets: ["HindsightCore"]),
        .library(name: "HindsightProcess", targets: ["HindsightProcess"]),
        .library(name: "HindsightRestic", targets: ["HindsightRestic"]),
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
    ],
    swiftLanguageModes: [.v6]
)

extension [SwiftSetting] {
    static let common: [SwiftSetting] = [
        .enableUpcomingFeature("ExistentialAny"),
    ]
}
