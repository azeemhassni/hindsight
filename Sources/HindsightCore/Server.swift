import Foundation

public struct SSHEndpoint: Hashable, Sendable, Codable {
    public var host: String
    public var port: Int
    public var user: String

    public init(host: String, port: Int = 22, user: String) throws {
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty else { throw ValidationError.emptySSHHost }
        guard !user.trimmingCharacters(in: .whitespaces).isEmpty else { throw ValidationError.emptySSHUser }
        guard (1...65535).contains(port) else { throw ValidationError.invalidPort(port) }
        self.host = host
        self.port = port
        self.user = user
    }
}

public enum SSHAuthentication: Hashable, Sendable, Codable {
    /// An ed25519 key pair Hindsight generated; the private key lives in the Keychain.
    case managedKey
    /// A key the user already had. Referenced by path and never copied.
    case existingKey(path: String)
}

public enum Privilege: String, Hashable, Sendable, Codable, CaseIterable {
    case root
    case sudo
}

public enum Architecture: String, Hashable, Sendable, Codable, CaseIterable {
    case x86_64
    case aarch64

    public init?(unameMachine: String) {
        switch unameMachine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "x86_64", "amd64": self = .x86_64
        case "aarch64", "arm64": self = .aarch64
        default: return nil
        }
    }
}

public struct Platform: Hashable, Sendable, Codable {
    public var distributionID: String
    public var versionID: String
    public var prettyName: String
    public var kernelRelease: String
    public var architecture: Architecture

    public init(
        distributionID: String,
        versionID: String,
        prettyName: String,
        kernelRelease: String,
        architecture: Architecture
    ) {
        self.distributionID = distributionID
        self.versionID = versionID
        self.prettyName = prettyName
        self.kernelRelease = kernelRelease
        self.architecture = architecture
    }
}

public struct Server: Identifiable, Hashable, Sendable, Codable {
    public let id: ServerID
    public var name: String
    public var endpoint: SSHEndpoint
    public var authentication: SSHAuthentication
    public var privilege: Privilege
    /// Discovered during onboarding and refreshed on each run, so it is absent
    /// until a server has been reached at least once.
    public var platform: Platform?
    public var coolifyVersion: String?

    public init(
        id: ServerID,
        name: String,
        endpoint: SSHEndpoint,
        authentication: SSHAuthentication,
        privilege: Privilege,
        platform: Platform? = nil,
        coolifyVersion: String? = nil
    ) throws {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw ValidationError.emptyServerName }
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.authentication = authentication
        self.privilege = privilege
        self.platform = platform
        self.coolifyVersion = coolifyVersion
    }

    public var isCoolifyServer: Bool { coolifyVersion != nil }
}
