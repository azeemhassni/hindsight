import Foundation
import HindsightCore
@testable import HindsightSSH

/// Access to the local Docker integration environment.
///
/// Every value comes from the environment variables `scripts/testenv.sh`
/// exports. There is no fallback to a configured server: a test that cannot
/// find the local environment is skipped, never redirected somewhere real.
enum TestEnvironment {
    static var host: String? { value("HINDSIGHT_TEST_SSH_HOST") }
    static var port: Int? { value("HINDSIGHT_TEST_SSH_PORT").flatMap(Int.init) }
    static var keyPath: String? { value("HINDSIGHT_TEST_SSH_KEY") }

    static var isAvailable: Bool {
        guard let host, let port, let keyPath else { return false }
        guard NetworkPolicy.isLocalTestAddress(host) else { return false }
        guard FileManager.default.fileExists(atPath: keyPath) else { return false }
        return canConnect(host: host, port: port)
    }

    static var allowsDestructiveOperations: Bool {
        isAvailable && value("HINDSIGHT_ALLOW_DESTRUCTIVE_TESTS") == "1"
    }

    static func destination(
        id: String = "testenv",
        user: String = "root",
        privilege: Privilege = .root
    ) throws -> SSHDestination {
        SSHDestination(
            serverID: try ServerID(validating: id),
            host: host ?? "127.0.0.1",
            port: port ?? 2222,
            user: user,
            identityFile: keyPath ?? "",
            privilege: privilege
        )
    }

    /// A client wired to a throwaway configuration directory, so a test never
    /// reads or writes the real one.
    static func makeClient() throws -> (SSHClient, SSHPaths) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hindsight-itest-\(UUID().uuidString)")
        let paths = SSHPaths(
            configurationDirectory: base.appendingPathComponent("ssh"),
            preferredControlDirectory: base.appendingPathComponent("cm")
        )
        try paths.prepare()
        return (SSHClient(paths: paths, policy: NetworkPolicy(mode: .localTestTargetsOnly)), paths)
    }

    /// Trusts the container's current host key and writes the ssh config.
    ///
    /// Each test passes its own `id` so that each gets its own connection-sharing
    /// socket. Sharing one would let tests interfere: a multiplexed session skips
    /// host key checking, and tearing down a shared master would wedge whichever
    /// test was mid-command.
    static func prepareTrustedClient(
        id: String,
        user: String = "root",
        privilege: Privilege = .root
    ) async throws -> (SSHClient, SSHDestination) {
        let (client, paths) = try makeClient()
        let destination = try destination(id: id, user: user, privilege: privilege)
        try SSHConfiguration(paths: paths).write(for: [destination])
        let keys = try await client.scanHostKeys(host: destination.host, port: destination.port)
        guard let preferred = keys.first else {
            throw SSHError.noHostKeyOfSupportedType(host: destination.host)
        }
        try client.trust(preferred, for: destination)
        return (client, destination)
    }

    private static func value(_ key: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[key], !raw.isEmpty else { return nil }
        return raw
    }

    private static func canConnect(host: String, port: Int) -> Bool {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { return false }
        defer { close(socketDescriptor) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr(host == "localhost" ? "127.0.0.1" : host)

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(socketDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
