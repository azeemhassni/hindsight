import Foundation
import HindsightCore
import HindsightProcess
import HindsightRestic
import HindsightTestSupport
import Testing
@testable import HindsightSSH

// A hung integration test is a failure, not a wait: the time limit turns an
// unreachable container or a wedged connection into a visible result.
@Suite(
    "SSH against the local test container",
    .enabled(if: TestEnvironment.isAvailable),
    .timeLimit(.minutes(1))
)
struct SSHIntegrationTests {
    @Test("scans and fingerprints the container's host keys")
    func scansHostKeys() async throws {
        let (client, _) = try TestEnvironment.makeClient()
        let destination = try TestEnvironment.destination(id: "scan-keys")
        let keys = try await client.scanHostKeys(host: destination.host, port: destination.port)

        #expect(!keys.isEmpty)
        #expect(keys.first?.keyType == "ssh-ed25519")
        for key in keys {
            #expect(key.fingerprint.hasPrefix("SHA256:"))
            #expect(!key.base64Key.isEmpty)
        }
    }

    @Test("does not trust a host until its key is confirmed")
    func requiresExplicitTrust() async throws {
        let (client, paths) = try TestEnvironment.makeClient()
        let destination = try TestEnvironment.destination(id: "explicit-trust")
        try SSHConfiguration(paths: paths).write(for: [destination])

        #expect(try !client.isTrusted(destination))

        // With nothing in known_hosts, StrictHostKeyChecking must refuse.
        await #expect(throws: (any Error).self) {
            try await client.run(RemoteCommand(executable: "/bin/true"), on: destination)
        }

        let keys = try await client.scanHostKeys(host: destination.host, port: destination.port)
        try client.trust(try #require(keys.first), for: destination)
        #expect(try client.isTrusted(destination))
        try await client.run(RemoteCommand(executable: "/bin/true"), on: destination)
        await client.closeControlMaster(on: destination)
    }

    @Test("runs a command and captures its output")
    func runsCommand() async throws {
        let (client, destination) = try await TestEnvironment.prepareTrustedClient(id: "run-command")
        defer { Task { await client.closeControlMaster(on: destination) } }

        let result = try await client.run(
            RemoteCommand(executable: "/bin/echo", arguments: ["hello", "from the container"]),
            on: destination
        )
        #expect(result.standardOutput == "hello from the container")
    }

    @Test("passes a secret through the environment and never through argv")
    func passesSecretSafely() async throws {
        let (client, destination) = try await TestEnvironment.prepareTrustedClient(id: "secret-safely")
        defer { Task { await client.closeControlMaster(on: destination) } }

        let secret = Secret(label: "token", value: "value with spaces and 'quotes' and $dollars")
        let result = try await client.run(
            RemoteCommand(
                executable: "/bin/sh",
                arguments: ["-c", "printf '%s' \"$MY_TOKEN\" | sha256sum | cut -d' ' -f1"],
                secretEnvironment: ["MY_TOKEN": secret]
            ),
            on: destination
        )

        // The remote side must have received the exact value; compare digests so
        // the secret itself never has to come back over the wire.
        let expected = BinaryStoreDigest.sha256(of: Data(secret.value.utf8))
        #expect(result.standardOutput == expected)
    }

    @Test("probes the container's facts in one round trip")
    func probesFacts() async throws {
        let (client, destination) = try await TestEnvironment.prepareTrustedClient(id: "probe-facts")
        defer { Task { await client.closeControlMaster(on: destination) } }

        let facts = try await client.probeFacts(on: destination)
        #expect(facts.platform.distributionID == "ubuntu")
        #expect(facts.platform.prettyName.contains("Ubuntu"))
        #expect(facts.homeDirectory == "/root")
        #expect(facts.hasNice)
        #expect(facts.hasIonice)
        #expect(facts.hasTestMarker)
        #expect(!facts.hasCoolifyDirectory)
        #expect(facts.listeningPorts.contains(22))
        #expect(!facts.mounts.isEmpty)
        #expect(facts.lowPriorityPrefix == ["nice", "-n", "19", "ionice", "-c3"])
    }

    @Test("detects passwordless sudo for an unprivileged user")
    func detectsSudo() async throws {
        let (client, destination) = try await TestEnvironment.prepareTrustedClient(
            id: "detect-sudo",
            user: "hindsight",
            privilege: .sudo
        )
        defer { Task { await client.closeControlMaster(on: destination) } }

        let facts = try await client.probeFacts(on: destination)
        #expect(facts.hasPasswordlessSudo)
        #expect(facts.homeDirectory == "/home/hindsight")

        let asRoot = try await client.run(
            RemoteCommand(executable: "/usr/bin/id", arguments: ["-un"], requiresRoot: true),
            on: destination
        )
        #expect(asRoot.standardOutput == "root")

        let asUser = try await client.run(
            RemoteCommand(executable: "/usr/bin/id", arguments: ["-un"], requiresRoot: false),
            on: destination
        )
        #expect(asUser.standardOutput == "hindsight")
    }

    @Test("uploads a file without naming its contents in argv, then verifies its digest")
    func uploadsAndVerifies() async throws {
        let (client, destination) = try await TestEnvironment.prepareTrustedClient(id: "upload-verify")
        defer { Task { await client.closeControlMaster(on: destination) } }

        let payload = Data((0..<4096).map { UInt8($0 % 251) })
        let path = "/root/.cache/hindsight/upload-test-\(UUID().uuidString)"
        try await client.upload(payload, to: path, mode: "600", on: destination)

        let digest = try await client.remoteDigest(of: path, on: destination)
        #expect(digest == BinaryStoreDigest.sha256(of: payload))

        try await client.run(RemoteCommand(executable: "/bin/rm", arguments: ["-f", path]), on: destination)
        #expect(try await client.remoteDigest(of: path, on: destination) == nil)
    }

    @Test("installs the pinned restic binary and refuses a tampered one")
    func installsRestic() async throws {
        let (client, destination) = try await TestEnvironment.prepareTrustedClient(id: "install-restic")
        defer { Task { await client.closeControlMaster(on: destination) } }

        let facts = try await client.probeFacts(on: destination)
        let binary = try PinnedBinaries.restic(for: facts.platform.architecture)
        let store = BinaryStore(directory: TestEnvironment.vendorBinDirectory())
        let installer = RemoteBinaryInstaller(client: client, store: store)

        let path = try await installer.ensureInstalled(binary, on: destination, facts: facts)
        #expect(path == "/root/.cache/hindsight/restic-\(binary.version)")

        // It must run on the server, which is the real proof the upload is intact.
        let version = try await client.run(
            RemoteCommand(executable: path, arguments: ["version"]),
            on: destination
        )
        #expect(version.standardOutput.contains("restic \(binary.version)"))

        // A second install is a no-op because the digest already matches.
        try await installer.verifyInstalled(binary, on: destination, facts: facts)

        // Tamper with the cached binary: the next verification must fail closed.
        // Replaced rather than appended to, because appending to a file another
        // test may be executing fails with ETXTBSY — and replacement is what a
        // real tamper would look like anyway.
        let quoted = ShellQuoting.quote(path)
        try await client.run(
            RemoteCommand(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "cp \(quoted) \(quoted).tampered && printf 'x' >> \(quoted).tampered "
                        + "&& mv -f \(quoted).tampered \(quoted)",
                ]
            ),
            on: destination
        )
        await #expect(throws: SSHError.self) {
            try await installer.verifyInstalled(binary, on: destination, facts: facts)
        }

        // And installing again repairs it.
        try await installer.ensureInstalled(binary, on: destination, facts: facts)
        try await installer.verifyInstalled(binary, on: destination, facts: facts)
    }

    @Test("allocates a reverse port chosen by the server and carries traffic through it")
    func reverseForwardCarriesTraffic() async throws {
        let (client, destination) = try await TestEnvironment.prepareTrustedClient(id: "reverse-forward")
        defer { Task { await client.closeControlMaster(on: destination) } }

        let listener = try LocalTestListener(responding: "hindsight-tunnel-ok")
        defer { listener.stop() }

        try await client.withReverseForward(toLocalPort: listener.port, on: destination) { remotePort in
            #expect(remotePort > 0)

            // bash, not sh: /dev/tcp is a bash feature and Ubuntu's /bin/sh is dash.
            let fetched = try await client.run(
                RemoteCommand(
                    executable: "/bin/bash",
                    arguments: [
                        "-c",
                        "exec 3<>/dev/tcp/127.0.0.1/\(remotePort); printf 'ping\\n' >&3; head -1 <&3",
                    ]
                ),
                on: destination
            )
            #expect(fetched.standardOutput == "hindsight-tunnel-ok")
        }
    }

    @Test("fails hard when the stored host key does not match the server")
    func failsOnHostKeyChange() async throws {
        let (client, paths) = try TestEnvironment.makeClient()
        let destination = try TestEnvironment.destination(id: "host-key-change")
        try SSHConfiguration(paths: paths).write(for: [destination])

        // Pin a different key for this host. That is indistinguishable, from
        // ssh's side, from the server being rebuilt or the connection being
        // intercepted — and it leaves the shared container untouched, so this
        // test cannot break the others.
        let wrongKey = try await TestEnvironment.generateUnrelatedHostKey()
        try client.trust(wrongKey, for: destination)

        do {
            try await client.run(
                RemoteCommand(executable: "/bin/true"),
                on: destination,
                timeout: .seconds(30)
            )
            Issue.record("expected the mismatched host key to be refused")
        } catch let error as SSHError {
            guard case .hostKeyChanged = error else {
                Issue.record("expected hostKeyChanged, got \(error)")
                return
            }
            #expect("\(error)".contains("has changed"))
            #expect("\(error)".contains("intercepted"))
        }

        // Re-confirming the real key is a deliberate act, and then it works.
        try client.forgetHostKeys(for: destination)
        let keys = try await client.scanHostKeys(host: destination.host, port: destination.port)
        try client.trust(try #require(keys.first), for: destination)
        try await client.run(RemoteCommand(executable: "/bin/true"), on: destination)
        await client.closeControlMaster(on: destination)
    }

    @Test("recovers from a control socket whose master is gone")
    func recoversFromStaleControlSocket() async throws {
        let (client, destination) = try await TestEnvironment.prepareTrustedClient(id: "stale-socket")
        defer { Task { await client.closeControlMaster(on: destination) } }

        let socketPath = try client.paths.controlPath(forToken: destination.controlToken)
        try? FileManager.default.removeItem(atPath: socketPath)
        FileManager.default.createFile(atPath: socketPath, contents: Data())

        // A leftover socket must not wedge a backup: the client notices the
        // master is gone, clears it, and reconnects.
        try await client.openControlMaster(on: destination)
        #expect(await client.controlMasterIsRunning(on: destination))
    }
}
