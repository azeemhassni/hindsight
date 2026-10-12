import Foundation
import HindsightCatalog
import HindsightCore
import HindsightKeychain
import HindsightProtocol
import HindsightRestic
import HindsightSSH
import HindsightTestSupport
import Testing
@testable import HindsightAgentKit
@testable import HindsightEngine

/// The requests the interface makes, against the local Docker container.
///
/// Every button in the window ends up in `AgentCore.handle(_:)`, so this drives
/// that surface in the order a person moves through it: scan, trust, probe,
/// add, then read back what was recorded. Nothing here can reach a real
/// server — the container is on 127.0.0.1 and carries the test marker.
@Suite(
    "What the interface asks the agent, end to end",
    .enabled(if: TestEnvironment.isAvailable),
    .timeLimit(.minutes(5)),
    .serialized
)
struct AgentFlowIntegrationTests {
    private func makeCore() throws -> (AgentCore, AgentConfiguration) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hindsight-agentflow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let configuration = AgentConfiguration(
            catalogURL: base.appendingPathComponent("catalog.sqlite"),
            repositoryRoot: base.appendingPathComponent("repos"),
            sshConfigurationDirectory: base.appendingPathComponent("ssh"),
            binaryDirectory: TestEnvironment.vendorBinDirectory()
        )
        let core = AgentCore(
            configuration: configuration,
            catalog: try Catalog.open(at: configuration.catalogURL),
            // Never the real Keychain: a test must not leave credentials on the
            // machine it ran on.
            secrets: InMemorySecretStore(),
            version: "test"
        )
        return (core, configuration)
    }

    private func draft(repositoryPath: String) throws -> AddServerDraft {
        AddServerDraft(
            name: "Local test box",
            host: try #require(TestEnvironment.host),
            port: try #require(TestEnvironment.port),
            user: "root",
            identityFile: TestEnvironment.keyPath,
            repositoryPath: repositoryPath
        )
    }

    @Test("walks the whole add-a-server flow the wizard walks")
    func addsAServer() async throws {
        let (core, configuration) = try makeCore()
        let host = try #require(TestEnvironment.host)
        let port = try #require(TestEnvironment.port)

        // 1. The fingerprint the person is asked to compare.
        let scanned = await core.handle(.scanHostKey(host: host, port: port))
        guard case let .hostKey(key) = scanned else {
            Issue.record("expected a host key, got \(scanned)")
            return
        }
        #expect(key.fingerprint.hasPrefix("SHA256:"))
        #expect(!key.base64Key.isEmpty)

        // 2. Confirming it is what writes known_hosts.
        #expect(
            await core.handle(
                .trustHostKey(host: host, port: port, keyType: key.keyType, base64Key: key.base64Key)
            ) == .done
        )

        // 3. The probe that answers both the access and the detection step.
        let repositoryPath = configuration.repositoryRoot.appendingPathComponent("flow").path
        let probed = await core.handle(.probeServer(try draft(repositoryPath: repositoryPath)))
        guard case let .probe(report) = probed else {
            Issue.record("expected a probe, got \(probed)")
            return
        }
        #expect(!report.prettyName.isEmpty)
        #expect(["x86_64", "aarch64"].contains(report.architecture))
        // The marker file is what the destructive-operation guard looks for,
        // and the wizard surfaces it so a test box is obvious.
        #expect(report.isTestTarget)

        // 4. Creating the server.
        let added = await core.handle(.addServer(try draft(repositoryPath: repositoryPath)))
        guard case let .serverAdded(serverID) = added else {
            Issue.record("expected a server, got \(added)")
            return
        }

        // 5. What the settings tab reads back.
        let settings = await core.handle(.serverSettings(serverID: serverID))
        guard case let .settings(current) = settings else {
            Issue.record("expected settings, got \(settings)")
            return
        }
        #expect(current.repositoryPath.contains(serverID))
        #expect(current.keepDaily > 0)

        // 6. The logs tab, on a server that has not run anything yet: empty is
        // an answer, not a failure.
        let history = await core.handle(.jobHistory(serverID: serverID, limit: 50))
        guard case let .jobs(jobs) = history else {
            Issue.record("expected a history, got \(history)")
            return
        }
        #expect(jobs.isEmpty)
    }
}

@Suite("Where backups are written")
struct RepositoryLocationTests {
    /// The location is chosen during onboarding and recorded in the catalog.
    /// A plan that derived it from the agent's default root instead wrote
    /// backups under Application Support while prune, check and restore worked
    /// on the empty directory the person had picked — found by installing the
    /// app and watching `du` report nothing where the backups were supposed to
    /// be.
    @Test("a plan backs up to the repository the catalog records")
    func planUsesTheRecordedRepository() throws {
        let server = try TestEnvironment.server(id: "web-01")
        let chosen = URL(fileURLWithPath: "/Volumes/Backups/Hindsight/web-01")
        let plan = BackupPlan(
            server: server,
            destination: try TestEnvironment.destination(id: "web-01"),
            repositoryRoot: chosen.deletingLastPathComponent(),
            repositoryPassword: Secret(label: "repo", value: "x"),
            repositoryName: chosen.lastPathComponent
        )
        #expect(plan.repositoryURL.path == chosen.path)
        #expect(plan.repositoryRoot.path == "/Volumes/Backups/Hindsight")
    }

    @Test("the server reaches the same repository through the tunnel")
    func restServerAddressesTheSameDirectory() async throws {
        let root = try TestEnvironment.temporaryRepositoryRoot()
        let credential = RestServerCredential.generate(username: "web-01")
        let server = RestServer(
            configuration: RestServer.Configuration(
                repositoryRoot: root,
                credential: credential,
                htpasswdFile: root.appendingPathComponent(".htpasswd"),
                executable: try BinaryStore(directory: TestEnvironment.vendorBinDirectory())
                    .verifiedURL(for: try PinnedBinaries.hostRestServer)
            )
        )
        // The directory name, not the server id: they are the same by
        // convention and must stay addressable even when they are not.
        let url = await server.repositoryURL(remotePort: 1234, repositoryName: "chosen-name")
        #expect(url.hasSuffix("/chosen-name/"))
    }

    @Test("a server's repository name defaults to its id")
    func defaultsToTheServerID() throws {
        let plan = BackupPlan(
            server: try TestEnvironment.server(id: "web-01"),
            destination: try TestEnvironment.destination(id: "web-01"),
            repositoryRoot: URL(fileURLWithPath: "/tmp/repos"),
            repositoryPassword: Secret(label: "repo", value: "x")
        )
        #expect(plan.repositoryURL.path == "/tmp/repos/web-01")
    }
}

@Suite("The managed ssh config")
struct SSHConfigurationRefreshTests {
    /// Written before anything that uses ssh, not only during onboarding. A
    /// server added after the last write had no stanza, and every job for it
    /// failed with "could not resolve hostname hs-…" — which reads like a DNS
    /// fault and is not one.
    @Test("covers every server, including ones added since the last write")
    func coversEveryServer() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hindsight sshconfig \(UUID().uuidString)")
        let configuration = AgentConfiguration(
            catalogURL: base.appendingPathComponent("catalog.sqlite"),
            repositoryRoot: base.appendingPathComponent("repos"),
            sshConfigurationDirectory: base.appendingPathComponent("ssh"),
            binaryDirectory: TestEnvironment.vendorBinDirectory()
        )
        let catalog = try Catalog.open(at: configuration.catalogURL)
        let core = AgentCore(
            configuration: configuration,
            catalog: catalog,
            secrets: InMemorySecretStore(),
            version: "test"
        )

        for name in ["web-01", "web-02"] {
            try catalog.save(
                try Server(
                    id: try ServerID(validating: name),
                    name: name,
                    endpoint: try SSHEndpoint(host: "127.0.0.1", port: 2222, user: "root"),
                    authentication: .managedKey,
                    privilege: .root
                )
            )
        }

        await core.refreshSSHConfiguration()
        let text = try String(
            contentsOf: configuration.sshConfigurationDirectory
                .appendingPathComponent("config"),
            encoding: .utf8
        )
        #expect(text.contains("Host hs-web-01"))
        #expect(text.contains("Host hs-web-02"))
        // And the path it writes contains a space, so the quoting holds here too.
        #expect(text.contains("\"\(configuration.sshConfigurationDirectory.path)/known_hosts\""))
    }

    @Test("writes one stanza per server, because ssh takes the first match")
    func writesOneStanzaPerServer() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hindsight dupe \(UUID().uuidString)")
        let paths = SSHPaths(
            configurationDirectory: base.appendingPathComponent("ssh"),
            preferredControlDirectory: base.appendingPathComponent("cm")
        )
        try paths.prepare()
        let destination = try TestEnvironment.destination(id: "web-01")
        let text = try SSHConfiguration(paths: paths)
            .render(for: [destination, destination, destination])
        #expect(text.components(separatedBy: "Host hs-web-01").count - 1 == 1)
    }
}
