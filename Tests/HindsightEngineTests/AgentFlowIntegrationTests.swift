import Foundation
import HindsightCatalog
import HindsightCore
import HindsightKeychain
import HindsightProtocol
import HindsightSSH
import HindsightTestSupport
import Testing
@testable import HindsightAgentKit

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
        #expect(!current.coolifyTokenIsSet)
        #expect(current.keepDaily > 0)

        // 6. The logs tab, on a server that has not run anything yet: empty is
        // an answer, not a failure.
        let history = await core.handle(.jobHistory(serverID: serverID, limit: 50))
        guard case let .jobs(jobs) = history else {
            Issue.record("expected a history, got \(history)")
            return
        }
        #expect(jobs.isEmpty)

        // 7. The Coolify tab on a server with no Docker: an explanation, not an
        // error, and the catalog left empty rather than guessing.
        let coolify = await core.handle(.discoverCoolify(serverID: serverID))
        guard case let .coolifyTree(tree) = coolify else {
            Issue.record("expected a tree, got \(coolify)")
            return
        }
        #expect(tree.resources.isEmpty)
        #expect(tree.mayBeIncomplete)
        #expect(!tree.sourceExplanation.isEmpty)
    }

    @Test("refuses a per-resource backup for a resource the server does not have")
    func refusesUnknownResource() async throws {
        let (core, configuration) = try makeCore()
        let host = try #require(TestEnvironment.host)
        let port = try #require(TestEnvironment.port)
        let scanned = await core.handle(.scanHostKey(host: host, port: port))
        guard case let .hostKey(key) = scanned else {
            Issue.record("expected a host key, got \(scanned)")
            return
        }
        _ = await core.handle(
            .trustHostKey(host: host, port: port, keyType: key.keyType, base64Key: key.base64Key)
        )
        let repositoryPath = configuration.repositoryRoot.appendingPathComponent("flow2").path
        let added = await core.handle(.addServer(try draft(repositoryPath: repositoryPath)))
        guard case let .serverAdded(serverID) = added else {
            Issue.record("expected a server, got \(added)")
            return
        }

        // Queued, then failed on the server's own evidence rather than on a
        // stale catalog row: the resource list is re-read before the backup.
        let accepted = await core.handle(
            .backUpResource(serverID: serverID, resourceUUID: "does-not-exist")
        )
        guard case let .accepted(jobID) = accepted else {
            Issue.record("expected the job to be accepted, got \(accepted)")
            return
        }

        var state: String?
        for _ in 0..<60 {
            let history = await core.handle(.jobHistory(serverID: serverID, limit: 10))
            if case let .jobs(jobs) = history,
               let job = jobs.first(where: { $0.id == jobID }),
               job.isFinished {
                state = job.state
                break
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        #expect(state == "failed")

        let log = await core.handle(.jobLog(jobID: jobID))
        guard case let .jobLog(lines) = log else {
            Issue.record("expected a log, got \(log)")
            return
        }
        // The log has to say why, because that is the only place a person can
        // find out.
        #expect(lines.contains { $0.message.contains("does-not-exist") })
    }
}
