import CryptoKit
import Foundation
import HindsightCore

public struct SSHDestination: Hashable, Sendable {
    public let serverID: ServerID
    public let host: String
    public let port: Int
    public let user: String
    public let identityFile: String
    public let privilege: Privilege

    public init(
        serverID: ServerID,
        host: String,
        port: Int,
        user: String,
        identityFile: String,
        privilege: Privilege
    ) {
        self.serverID = serverID
        self.host = host
        self.port = port
        self.user = user
        self.identityFile = identityFile
        self.privilege = privilege
    }

    public init(server: Server, identityFile: String) {
        self.init(
            serverID: server.id,
            host: server.endpoint.host,
            port: server.endpoint.port,
            user: server.endpoint.user,
            identityFile: identityFile,
            privilege: server.privilege
        )
    }

    /// The alias used in the managed ssh config.
    public var configAlias: String { "hs-\(serverID.value)" }

    /// How this host appears in `known_hosts`. OpenSSH brackets the host and
    /// appends the port for anything other than 22.
    public var knownHostsHost: String {
        port == 22 ? host : "[\(host)]:\(port)"
    }

    /// A short, stable token for the connection-sharing socket name.
    ///
    /// OpenSSH's own `%C` is a full 64-character hash, which overruns the
    /// 104-byte `sockaddr_un` limit once it sits inside an Application Support
    /// path. Ten hex characters keep collisions negligible and the path short.
    public var controlToken: String {
        let material = "\(serverID.value)\u{0}\(user)@\(host):\(port)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(10).description
    }
}
