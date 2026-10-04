import Foundation
import HindsightCore
import HindsightProcess
import HindsightSSH

/// Access to the local Docker integration environment.
///
/// Lives in a source target rather than a test target so every test module can
/// use the same definition of "a safe local target", and so the rule that tests
/// never reach a real server is stated in exactly one place.
///
/// Every value comes from the environment variables `scripts/testenv.sh`
/// exports. There is no fallback to a configured server: a test that cannot
/// find the local environment is skipped, never redirected somewhere real.
public enum TestEnvironment {
    public static var host: String? { value("HINDSIGHT_TEST_SSH_HOST") }
    public static var port: Int? { value("HINDSIGHT_TEST_SSH_PORT").flatMap(Int.init) }
    public static var keyPath: String? { value("HINDSIGHT_TEST_SSH_KEY") }

    public static var isAvailable: Bool {
        guard let host, let port, let keyPath else { return false }
        guard NetworkPolicy.isLocalTestAddress(host) else { return false }
        guard FileManager.default.fileExists(atPath: keyPath) else { return false }
        return canConnect(host: host, port: port)
    }

    public static var allowsDestructiveOperations: Bool {
        isAvailable && value("HINDSIGHT_ALLOW_DESTRUCTIVE_TESTS") == "1"
    }

    public static func destination(
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
    public static func makeClient() throws -> (SSHClient, SSHPaths) {
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
    public static func prepareTrustedClient(
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


extension TestEnvironment {
    /// The repository root for a test, under the system temporary directory.
    public static func temporaryRepositoryRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hindsight-repos-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func vendorBinDirectory(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("vendor/bin")
    }

    public static func repositoryRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    public static func server(id: String, host: String? = nil) throws -> Server {
        try Server(
            id: ServerID(validating: id),
            name: "Test container",
            endpoint: SSHEndpoint(host: host ?? self.host ?? "127.0.0.1", port: port ?? 2222, user: "root"),
            authentication: .existingKey(path: keyPath ?? ""),
            privilege: .root
        )
    }
}

extension TestEnvironment {
    /// A valid ed25519 public key that belongs to no server in this test run.
    ///
    /// Pinning this as a host key reproduces exactly what ssh sees when a
    /// server is rebuilt or a connection is intercepted, without disturbing the
    /// shared container.
    public static func generateUnrelatedHostKey() async throws -> HostKey {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hindsight-wrongkey-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keyFile = directory.appendingPathComponent("id_ed25519")

        try await ProcessRunner().run(
            Command(
                path: "/usr/bin/ssh-keygen",
                arguments: ["-q", "-t", "ed25519", "-N", "", "-C", "unrelated", "-f", keyFile.path]
            )
        )
        let publicKey = try String(contentsOf: keyFile.appendingPathExtension("pub"), encoding: .utf8)
        let fields = publicKey.split(separator: " ").map(String.init)
        return HostKey(host: "placeholder", keyType: fields[0], base64Key: fields[1], fingerprint: "")
    }
}

/// The local Coolify virtual machine, provisioned by
/// `scripts/coolify-testenv.sh`.
public enum CoolifyTestEnvironment {
    public static var host: String? {
        guard let value = ProcessInfo.processInfo.environment["HINDSIGHT_TEST_COOLIFY_HOST"],
              !value.isEmpty
        else { return nil }
        return value
    }

    public static var token: String? {
        guard let value = ProcessInfo.processInfo.environment["HINDSIGHT_TEST_COOLIFY_TOKEN"],
              !value.isEmpty
        else { return nil }
        return value
    }

    /// Requires an explicit opt-in as well as a reachable VM.
    ///
    /// The virtual machine and the Docker environment share one hypervisor, and
    /// running both test suites at once makes connections to the VM fail in
    /// ways that look like Hindsight bugs. These tests are run deliberately,
    /// with `make test-coolify`.
    public static var isAvailable: Bool {
        guard ProcessInfo.processInfo.environment["HINDSIGHT_TEST_COOLIFY"] == "1" else { return false }
        guard let host, TestEnvironment.keyPath != nil else { return false }
        // The same rule as everywhere else: a private address only.
        return NetworkPolicy.isLocalTestAddress(host)
    }

    public static var hasToken: Bool { isAvailable && token != nil }

    public static func destination(id: String = "coolify-vm") throws -> SSHDestination {
        SSHDestination(
            serverID: try ServerID(validating: id),
            host: host ?? "127.0.0.1",
            port: 22,
            user: "root",
            identityFile: TestEnvironment.keyPath ?? "",
            privilege: .root
        )
    }

    /// A client that trusts the VM's current host key, in a throwaway
    /// configuration directory.
    public static func prepareTrustedClient(id: String = "coolify-vm") async throws -> (SSHClient, SSHDestination) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hindsight-coolify-\(UUID().uuidString)")
        let paths = SSHPaths(
            configurationDirectory: base.appendingPathComponent("ssh"),
            preferredControlDirectory: base.appendingPathComponent("cm")
        )
        try paths.prepare()
        let client = SSHClient(paths: paths, policy: NetworkPolicy(mode: .localTestTargetsOnly))
        let destination = try destination(id: id)
        try SSHConfiguration(paths: paths).write(for: [destination])

        let keys = try await client.scanHostKeys(host: destination.host, port: destination.port)
        guard let preferred = keys.first else {
            throw SSHError.noHostKeyOfSupportedType(host: destination.host)
        }
        try client.trust(preferred, for: destination)
        return (client, destination)
    }
}
