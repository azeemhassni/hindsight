import Foundation
import HindsightCatalog
import HindsightCore
import HindsightKeychain
import HindsightProtocol
import Testing
@testable import HindsightAgentKit

/// A store whose reads block until released, standing in for a Keychain that
/// is waiting on securityd — a locked keychain, an access prompt, a wedged
/// daemon.
final class BlockingSecretStore: SecretStore, @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let started = DispatchSemaphore(value: 0)

    func waitUntilRead() {
        started.wait()
    }

    func release() {
        gate.signal()
    }

    func read(_ key: SecretKey) throws -> Secret {
        started.signal()
        gate.wait()
        return Secret(label: key.account, value: "unblocked")
    }

    func contains(_ key: SecretKey) -> Bool { true }
    func write(_ value: String, for key: SecretKey) throws {}
    func delete(_ key: SecretKey) throws {}
}

@Suite("The agent stays answerable", .timeLimit(.minutes(1)))
struct AgentResponsivenessTests {
    /// The bug this covers was seen, not imagined: a Keychain read waiting on
    /// an access prompt ran on the actor, so the agent answered nothing at all
    /// — the window sat on "Connecting…" while the agent was healthy.
    @Test("a Keychain read that blocks does not stop the agent answering")
    func slowSecretStoreDoesNotWedgeTheAgent() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hindsight-responsive-\(UUID().uuidString)")
        let configuration = AgentConfiguration(
            catalogURL: base.appendingPathComponent("catalog.sqlite"),
            repositoryRoot: base.appendingPathComponent("repos"),
            sshConfigurationDirectory: base.appendingPathComponent("ssh"),
            binaryDirectory: TestEnvironmentPaths.vendorBin
        )
        let catalog = try Catalog.open(at: configuration.catalogURL)
        let id = try ServerID(validating: "web-01")
        try catalog.save(
            try Server(
                id: id,
                name: "Web 01",
                endpoint: try SSHEndpoint(host: "127.0.0.1", port: 2222, user: "root"),
                authentication: .managedKey,
                privilege: .root
            )
        )
        try catalog.save(
            RepositoryRecord(
                id: "repo-web-01",
                serverId: id.value,
                path: base.appendingPathComponent("repos/web-01").path
            )
        )

        let secrets = BlockingSecretStore()
        let core = AgentCore(
            configuration: configuration,
            catalog: catalog,
            secrets: secrets,
            version: "test"
        )
        await core.start()

        // A job that needs the repository password, which will not come.
        let accepted = await core.handle(.runMaintenance(serverID: id.value))
        guard case .accepted = accepted else {
            Issue.record("expected the job to be accepted, got \(accepted)")
            return
        }
        secrets.waitUntilRead()

        // The agent must still answer while that read is stuck.
        let response = await core.handle(.status)
        guard case let .status(status) = response else {
            Issue.record("expected a status, got \(response)")
            return
        }
        #expect(status.servers.count == 1)

        // And the settings surface, which also reads the Keychain.
        let settings = await core.handle(.serverSettings(serverID: id.value))
        if case .failed = settings {
            Issue.record("settings should answer while a secret read is stuck")
        }

        secrets.release()
        await core.stop()
    }
}

/// The vendored binaries, for tests that build an agent configuration.
enum TestEnvironmentPaths {
    static var vendorBin: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("vendor/bin")
    }
}

@Suite("Jobs left behind by a stopped agent")
struct InterruptedJobTests {
    @Test("a job that was running when the agent stopped is closed off, not left running")
    func closesInterruptedJobs() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hindsight-interrupted-\(UUID().uuidString)")
        let configuration = AgentConfiguration(
            catalogURL: base.appendingPathComponent("catalog.sqlite"),
            repositoryRoot: base.appendingPathComponent("repos"),
            sshConfigurationDirectory: base.appendingPathComponent("ssh"),
            binaryDirectory: TestEnvironmentPaths.vendorBin
        )
        let catalog = try Catalog.open(at: configuration.catalogURL)
        let id = try ServerID(validating: "web-01")
        try catalog.save(
            try Server(
                id: id,
                name: "Web 01",
                endpoint: try SSHEndpoint(host: "127.0.0.1", port: 2222, user: "root"),
                authentication: .managedKey,
                privilege: .root
            )
        )
        var job = JobRecord(id: JobID(unchecked: "job-interrupted"), serverId: id, kind: .backup)
        job.state = .running
        job.startedAt = Date(timeIntervalSinceNow: -600)
        try catalog.save(job)

        let core = AgentCore(
            configuration: configuration,
            catalog: catalog,
            secrets: InMemorySecretStore(),
            version: "test"
        )
        await core.start()
        await core.stop()

        let reported = try catalog.job(JobID(unchecked: "job-interrupted"))
        #expect(reported?.state == .failed)
        #expect(reported?.finishedAt != nil)
        #expect(reported?.errorText?.contains("Interrupted") == true)
        // And the reason is in the log, which is where someone will look.
        let events = try catalog.events(for: JobID(unchecked: "job-interrupted"))
        #expect(events.contains { $0.message.contains("Interrupted") })
    }
}
