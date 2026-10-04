import Foundation
import HindsightCatalog
import HindsightCore
import HindsightKeychain
import HindsightProtocol
import Testing
@testable import HindsightAgentKit

@Suite("Job history over the protocol")
struct AgentHistoryTests {
    private func core(_ catalog: Catalog) -> AgentCore {
        AgentCore(
            configuration: .fallback,
            catalog: catalog,
            secrets: InMemorySecretStore(),
            version: "test"
        )
    }

    private func server(in catalog: Catalog, id: String = "web-01") throws -> Server {
        let server = try Server(
            id: try ServerID(validating: id),
            name: "Web 01",
            endpoint: try SSHEndpoint(host: "198.51.100.1", user: "root"),
            authentication: .managedKey,
            privilege: .root
        )
        try catalog.save(server)
        return server
    }

    @Test("reports a finished backup with its numbers")
    func reportsFinishedJob() async throws {
        let catalog = try Catalog.inMemory()
        let server = try server(in: catalog)
        var record = JobRecord(id: JobID(unchecked: "job-1"), serverId: server.id, kind: .backup)
        record.state = .succeeded
        record.startedAt = Date(timeIntervalSince1970: 100)
        record.finishedAt = Date(timeIntervalSince1970: 160)
        record.bytesAdded = 4096
        record.bytesProcessed = 8192
        try catalog.save(record)

        let response = await core(catalog).handle(.jobHistory(serverID: server.id.value, limit: 10))
        guard case let .jobs(reports) = response else {
            Issue.record("expected jobs, got \(response)")
            return
        }
        let job = try #require(reports.first)
        #expect(job.id == "job-1")
        #expect(job.kind == "backup")
        #expect(job.succeeded)
        #expect(job.isFinished)
        #expect(job.bytesAdded == 4096)
    }

    @Test("a per-resource run says so, so it is not read as a whole-server backup")
    func marksResourceRuns() async throws {
        let catalog = try Catalog.inMemory()
        let server = try server(in: catalog)
        try catalog.save(
            JobRecord(
                id: JobID(unchecked: "job-2"),
                serverId: server.id,
                kind: .backup,
                resourceUUID: "q78pdwdw3qpsm2zdmyqfu6wf"
            )
        )

        let response = await core(catalog).handle(.jobHistory(serverID: server.id.value, limit: 10))
        guard case let .jobs(reports) = response else {
            Issue.record("expected jobs, got \(response)")
            return
        }
        #expect(reports.first?.resourceUUID == "q78pdwdw3qpsm2zdmyqfu6wf")
    }

    @Test("carries the log lines a run recorded, in order and with their level")
    func returnsLogLines() async throws {
        let catalog = try Catalog.inMemory()
        let server = try server(in: catalog)
        let jobID = JobID(unchecked: "job-3")
        try catalog.save(JobRecord(id: jobID, serverId: server.id, kind: .backup))
        try catalog.append("phase: connecting", to: jobID)
        try catalog.append("could not read /proc/1", level: .warning, to: jobID)

        let response = await core(catalog).handle(.jobLog(jobID: jobID.value))
        guard case let .jobLog(lines) = response else {
            Issue.record("expected a log, got \(response)")
            return
        }
        #expect(lines.map(\.message) == ["phase: connecting", "could not read /proc/1"])
        #expect(lines.map(\.level) == ["info", "warning"])
        #expect(lines.map(\.sequence) == [1, 2])
    }

    @Test("refuses an id that is not a server id rather than reporting nothing")
    func refusesBadServerID() async throws {
        let response = await core(try Catalog.inMemory())
            .handle(.jobHistory(serverID: "not a server id", limit: 10))
        guard case let .failed(message) = response else {
            Issue.record("expected a failure, got \(response)")
            return
        }
        #expect(message.contains("not a server id"))
    }

    @Test("clamps an absurd limit rather than reading the whole table")
    func clampsLimit() async throws {
        let catalog = try Catalog.inMemory()
        let server = try server(in: catalog)
        for index in 0..<5 {
            try catalog.save(
                JobRecord(id: JobID(unchecked: "job-\(index)"), serverId: server.id, kind: .backup)
            )
        }
        for limit in [-5, 0, 100_000] {
            let response = await core(catalog)
                .handle(.jobHistory(serverID: server.id.value, limit: limit))
            guard case let .jobs(reports) = response else {
                Issue.record("expected jobs, got \(response)")
                return
            }
            #expect(reports.count <= 5)
        }
    }
}

@Suite("Settings read back")
struct AgentSettingsReportTests {
    @Test("reports what is in force, and only whether a token is set")
    func reportsCurrentSettings() async throws {
        let catalog = try Catalog.inMemory()
        let id = try ServerID(validating: "web-01")
        try catalog.save(
            try Server(
                id: id,
                name: "Web 01",
                endpoint: try SSHEndpoint(host: "198.51.100.1", user: "root"),
                authentication: .managedKey,
                privilege: .root
            )
        )
        try catalog.save(
            RepositoryRecord(
                id: "repo-web-01",
                serverId: id.value,
                path: "/Volumes/Backups/web-01",
                checkRotationDivisor: 6,
                bandwidthLimitKiB: 2048
            )
        )
        let secrets = InMemorySecretStore([.coolifyToken(id): "secret-token"])
        let core = AgentCore(
            configuration: .fallback,
            catalog: catalog,
            secrets: secrets,
            version: "test"
        )

        let response = await core.handle(.serverSettings(serverID: id.value))
        guard case let .settings(report) = response else {
            Issue.record("expected settings, got \(response)")
            return
        }
        #expect(report.repositoryPath == "/Volumes/Backups/web-01")
        #expect(report.checkRotationDivisor == 6)
        #expect(report.bandwidthLimitKiB == 2048)
        // Set, but never the value: the token stays in the Keychain.
        #expect(report.coolifyTokenIsSet)
        #expect(!"\(report)".contains("secret-token"))
    }

    @Test("a bandwidth limit survives a save and reaches the backup command")
    func appliesBandwidthLimit() async throws {
        let catalog = try Catalog.inMemory()
        let id = try ServerID(validating: "web-01")
        try catalog.save(
            try Server(
                id: id,
                name: "Web 01",
                endpoint: try SSHEndpoint(host: "198.51.100.1", user: "root"),
                authentication: .managedKey,
                privilege: .root
            )
        )
        try catalog.save(
            RepositoryRecord(id: "repo-web-01", serverId: id.value, path: "/tmp/repo")
        )
        let core = AgentCore(
            configuration: .fallback,
            catalog: catalog,
            secrets: InMemorySecretStore(),
            version: "test"
        )

        var update = ServerSettingsUpdate(serverID: id.value)
        update.bandwidthLimitKiB = 512
        #expect(await core.handle(.updateServerSettings(update)) == .done)
        #expect(try catalog.repository(forServer: id)?.bandwidthLimitKiB == 512)

        // The profile is what carries it into restic's arguments.
        let profile = try BackupProfile(
            includePaths: ["/"],
            excludePatterns: [],
            bandwidthLimitKiBPerSecond: try catalog.repository(forServer: id)?.bandwidthLimitKiB
        )
        #expect(profile.bandwidthLimitKiBPerSecond == 512)
    }
}

@Suite("Finding the vendored binaries")
struct BundledBinaryDirectoryTests {
    private func makeBundle(
        _ layout: [String],
        vendoredIn: String?
    ) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hindsight-bundle-\(UUID().uuidString)")
        for path in layout {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(path),
                withIntermediateDirectories: true
            )
        }
        if let vendoredIn {
            try Data("x".utf8).write(
                to: root.appendingPathComponent(vendoredIn)
                    .appendingPathComponent("restic-0.19.1-darwin_arm64")
            )
        }
        return root
    }

    /// The agent is a small bundle nested inside the app, and the binaries are
    /// shipped once — in the outer bundle. Looking only at its own Resources is
    /// how a signed install ended up reporting "restic is not in
    /// …/HindsightAgent.app/Contents/Resources".
    @Test("looks in the enclosing app bundle when nested inside one")
    func findsBinariesInTheEnclosingBundle() throws {
        let root = try makeBundle(
            [
                "Hindsight.app/Contents/Resources",
                "Hindsight.app/Contents/Library/LaunchAgents/HindsightAgent.app/Contents/Resources",
            ],
            vendoredIn: "Hindsight.app/Contents/Resources"
        )
        let agent = root.appendingPathComponent(
            "Hindsight.app/Contents/Library/LaunchAgents/HindsightAgent.app"
        )
        let found = AgentConfiguration.bundledBinaryDirectory(for: agent)
        #expect(found?.path == root.appendingPathComponent("Hindsight.app/Contents/Resources").path)
    }

    @Test("prefers its own Resources when the binaries are there")
    func prefersItsOwnResources() throws {
        let root = try makeBundle(
            ["Standalone.app/Contents/Resources"],
            vendoredIn: "Standalone.app/Contents/Resources"
        )
        let bundle = root.appendingPathComponent("Standalone.app")
        #expect(
            AgentConfiguration.bundledBinaryDirectory(for: bundle)?.path
                == bundle.appendingPathComponent("Contents/Resources").path
        )
    }

    @Test("says nothing rather than pointing at a directory with no binaries in it")
    func refusesAnEmptyDirectory() throws {
        let root = try makeBundle(["Lonely.app/Contents/Resources"], vendoredIn: nil)
        #expect(AgentConfiguration.bundledBinaryDirectory(for: root.appendingPathComponent("Lonely.app")) == nil)
    }
}
