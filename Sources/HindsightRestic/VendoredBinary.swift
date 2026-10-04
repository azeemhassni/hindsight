import Foundation
import HindsightCore

public enum VendoredTool: String, Hashable, Sendable, CaseIterable {
    case restic
    case restServer = "rest-server"
}

public enum VendoredPlatform: String, Hashable, Sendable, CaseIterable {
    case linuxAMD64 = "linux_amd64"
    case linuxARM64 = "linux_arm64"
    case darwinAMD64 = "darwin_amd64"
    case darwinARM64 = "darwin_arm64"

    public init(linux architecture: Architecture) {
        switch architecture {
        case .x86_64: self = .linuxAMD64
        case .aarch64: self = .linuxARM64
        }
    }

    public static var host: VendoredPlatform {
        #if arch(arm64)
        .darwinARM64
        #else
        .darwinAMD64
        #endif
    }

    public var isLinux: Bool {
        self == .linuxAMD64 || self == .linuxARM64
    }
}

public struct PinnedBinary: Hashable, Sendable {
    public let tool: VendoredTool
    public let version: String
    public let platform: VendoredPlatform
    public let archiveName: String
    public let archiveSHA256: String
    public let binarySHA256: String

    public init(
        tool: VendoredTool,
        version: String,
        platform: VendoredPlatform,
        archiveName: String,
        archiveSHA256: String,
        binarySHA256: String
    ) {
        self.tool = tool
        self.version = version
        self.platform = platform
        self.archiveName = archiveName
        self.archiveSHA256 = archiveSHA256
        self.binarySHA256 = binarySHA256
    }

    /// The name used both in `vendor/bin` and in the app's resources, so the
    /// same lookup works in tests and in the shipped bundle.
    public var fileName: String { "\(tool.rawValue)-\(version)-\(platform.rawValue)" }

    /// Where the binary is cached on a VPS. The version is in the name so that
    /// a Hindsight upgrade cannot silently run an older cached restic.
    public var remoteCachePath: String { ".cache/hindsight/\(tool.rawValue)-\(version)" }
}

public enum PinnedBinaries {
    public static func find(_ tool: VendoredTool, for platform: VendoredPlatform) throws -> PinnedBinary {
        guard let binary = all.first(where: { $0.tool == tool && $0.platform == platform }) else {
            throw BinaryStoreError.noPinnedBinary(tool: tool.rawValue, platform: platform.rawValue)
        }
        return binary
    }

    public static func restic(for architecture: Architecture) throws -> PinnedBinary {
        try find(.restic, for: VendoredPlatform(linux: architecture))
    }

    public static var hostRestic: PinnedBinary {
        get throws { try find(.restic, for: .host) }
    }

    public static var hostRestServer: PinnedBinary {
        get throws { try find(.restServer, for: .host) }
    }
}
