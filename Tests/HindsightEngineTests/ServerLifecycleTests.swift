import Foundation
import HindsightCatalog
import HindsightCore
import HindsightKeychain
import HindsightProtocol
import Testing
@testable import HindsightAgentKit

/// Stopping work, removing a server, and saying what needs attention.
@Suite("Stopping and removing")
struct ServerLifecycleTests {
    private func makeCore() throws -> (AgentCore, Catalog, ServerID, URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hindsight lifecycle \(UUID().uuidString)")
        let repository = base.appendingPathComponent("repos/web-01")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try Data("pretend repository".utf8)
            .write(to: repository.appendingPathComponent("config"))

        let catalog = try Catalog.open(at: base.appendingPathComponent("catalog.sqlite"))
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
            RepositoryRecord(id: "repo-web-01", serverId: id.value, path: repository.path)
        )
        let core = AgentCore(
            configuration: AgentConfiguration(
                catalogURL: base.appendingPathComponent("catalog.sqlite"),
                repositoryRoot: base.appendingPathComponent("repos"),
                sshConfigurationDirectory: base.appendingPathComponent("ssh"),
                binaryDirectory: base
            ),
            catalog: catalog,
            secrets: InMemorySecretStore([.repositoryPassword(id): "secret"]),
            version: "test"
        )
        return (core, catalog, id, repository)
    }

    @Test("removing a server keeps its backups, and the password that reads them")
    func removeKeepsBackupsByDefault() async throws {
        let (core, catalog, id, repository) = try makeCore()
        #expect(await core.handle(.removeServer(serverID: id.value, deleteBackups: false)) == .done)

        #expect(try catalog.server(id) == nil)
        // Both, or neither: a repository without its password is a pile of
        // bytes nobody can open.
        #expect(FileManager.default.fileExists(atPath: repository.path))
        #expect(await core.hasSecret(.repositoryPassword(id)))
    }

    @Test("deleting the backups removes the repository and the password together")
    func removeCanDeleteBackups() async throws {
        let (core, catalog, id, repository) = try makeCore()
        #expect(await core.handle(.removeServer(serverID: id.value, deleteBackups: true)) == .done)

        #expect(try catalog.server(id) == nil)
        #expect(!FileManager.default.fileExists(atPath: repository.path))
        #expect(!(await core.hasSecret(.repositoryPassword(id))))
    }

    @Test("refuses to remove a server it does not have")
    func refusesUnknownServer() async throws {
        let (core, _, _, _) = try makeCore()
        guard case .failed = await core.handle(.removeServer(serverID: "nope", deleteBackups: false))
        else {
            Issue.record("expected a refusal")
            return
        }
    }

    @Test("stopping work closes the job off as cancelled, not failed")
    func stopMarksJobsCancelled() async throws {
        let (core, catalog, id, _) = try makeCore()
        var job = JobRecord(id: JobID(unchecked: "job-1"), serverId: id, kind: .backup)
        job.state = .running
        job.startedAt = Date()
        try catalog.save(job)

        _ = await core.handle(.stopWork(serverID: id.value))
        let after = try catalog.job(JobID(unchecked: "job-1"))
        #expect(after?.state == .cancelled)
        #expect(after?.errorText == "Stopped.")
    }

    /// Pausing is what someone presses to stop a backup that is running, not
    /// only to stop the next one.
    @Test("pausing stops a run that is already going")
    func pausingStopsTheRunningJob() async throws {
        let (core, catalog, id, _) = try makeCore()
        var job = JobRecord(id: JobID(unchecked: "job-2"), serverId: id, kind: .backup)
        job.state = .running
        try catalog.save(job)

        _ = await core.handle(.setPaused(serverID: id.value, paused: true))
        let after = try catalog.job(JobID(unchecked: "job-2"))
        #expect(after?.state == .cancelled)
        #expect(after?.errorText?.contains("paused") == true)
    }
}

/// Why a server needs attention.
@Suite("Saying what needs attention")
struct HealthReasonTests {
    private func failedJob(kind: JobKind = .backup, error: String) -> JobRecord {
        var job = JobRecord(id: JobID(unchecked: UUID().uuidString), serverId: nil, kind: kind)
        job.state = .failed
        job.finishedAt = Date()
        job.errorText = error
        return job
    }

    @Test("names the failure, not just that there was one")
    func namesTheFailure() {
        let reason = AgentCore.healthReason(
            lastBackupAt: Date(timeIntervalSinceNow: -7200),
            lastCheckPassed: true,
            recentJobs: [failedJob(error: "Could not connect to 198.51.100.1: timed out")]
        )
        #expect(reason?.contains("backup failed") == true)
        #expect(reason?.contains("timed out") == true)
    }

    @Test("keeps a long error to one readable line")
    func trimsLongErrors() {
        let reason = AgentCore.healthReason(
            lastBackupAt: nil,
            lastCheckPassed: true,
            recentJobs: [failedJob(error: String(repeating: "x", count: 400) + "\nsecond line")]
        )
        #expect((reason?.count ?? 0) < 220)
        #expect(reason?.contains("second line") == false)
    }

    @Test("says when a check failed, when nothing has run, and when it is late")
    func coversTheOtherCauses() {
        #expect(
            AgentCore.healthReason(lastBackupAt: Date(), lastCheckPassed: false, recentJobs: [])?
                .contains("integrity check") == true
        )
        #expect(
            AgentCore.healthReason(lastBackupAt: nil, lastCheckPassed: nil, recentJobs: [])?
                .contains("never been backed up") == true
        )
        #expect(
            AgentCore.healthReason(
                lastBackupAt: Date(timeIntervalSinceNow: -5 * 86400),
                lastCheckPassed: true,
                recentJobs: []
            )?.contains("5 days ago") == true
        )
    }

    @Test("says nothing when there is nothing to say")
    func silentWhenHealthy() {
        #expect(
            AgentCore.healthReason(
                lastBackupAt: Date(timeIntervalSinceNow: -3600),
                lastCheckPassed: true,
                recentJobs: []
            ) == nil
        )
    }
}

/// Which authentication a machine gets when it is recorded.
@Suite("Authentication for a restore target")
struct RestoreTargetAuthenticationTests {
    /// Its own directories: adding a machine writes an ssh configuration, and
    /// a test must never write into the installed one.
    private func makeCore() throws -> (AgentCore, Catalog) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hindsight-target-auth-\(UUID().uuidString)")
        let configuration = AgentConfiguration(
            catalogURL: base.appendingPathComponent("catalog.sqlite"),
            repositoryRoot: base.appendingPathComponent("repos"),
            sshConfigurationDirectory: base.appendingPathComponent("ssh"),
            binaryDirectory: base.appendingPathComponent("bin")
        )
        let catalog = try Catalog.open(at: configuration.catalogURL)
        let core = AgentCore(
            configuration: configuration,
            catalog: catalog,
            secrets: InMemorySecretStore(),
            version: "test"
        )
        return (core, catalog)
    }

    private func draft(identityFile: String?) -> AddServerDraft {
        AddServerDraft(
            name: "Replacement",
            host: "198.51.100.20",
            port: 22,
            user: "root",
            identityFile: identityFile,
            repositoryPath: nil
        )
    }

    /// Onboarding generates a key and installs it. A restore target already
    /// exists and already trusts something, and Hindsight's generated key is
    /// not it — so offering that key is offering the one that cannot work.
    @Test("a restore target with no key named lets ssh decide")
    func noKeyMeansSystemDefault() async throws {
        let (core, catalog) = try makeCore()
        let id = try await core.addRestoreTarget(draft(identityFile: nil))

        let server = try #require(try catalog.server(id))
        #expect(server.authentication == .systemDefault)
        // And it is a destination, not something that gets backed up.
        #expect(try catalog.repository(forServer: id) == nil)
    }

    @Test("a named key is used as it was given")
    func namedKeyIsUsed() async throws {
        let (core, catalog) = try makeCore()
        let id = try await core.addRestoreTarget(draft(identityFile: "/Users/me/.ssh/deploy"))

        let server = try #require(try catalog.server(id))
        #expect(server.authentication == .existingKey(path: "/Users/me/.ssh/deploy"))
    }

    /// Unchanged: a server being backed up is still given a key of its own.
    @Test("onboarding still generates a managed key")
    func onboardingIsUnchanged() async throws {
        let (core, catalog) = try makeCore()
        let id = try await core.addServer(draft(identityFile: nil))

        let server = try #require(try catalog.server(id))
        #expect(server.authentication == .managedKey)
        #expect(try catalog.repository(forServer: id) != nil)
    }
}
