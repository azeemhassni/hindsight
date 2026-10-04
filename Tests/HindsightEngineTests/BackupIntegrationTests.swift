import Foundation
import HindsightCatalog
import HindsightCore
import HindsightProcess
import HindsightRestic
import HindsightSSH
import HindsightTestSupport
import Testing
@testable import HindsightEngine

/// Backups against the local Docker container. Nothing here can reach a real
/// server: the network policy only admits local addresses, and the container
/// carries the test marker.
@Suite(
    "Backup against the local test container",
    .enabled(if: TestEnvironment.isAvailable),
    .timeLimit(.minutes(5)),
    .serialized
)
struct BackupIntegrationTests {
    struct Fixture {
        let engine: BackupEngine
        let client: SSHClient
        let destination: SSHDestination
        let plan: BackupPlan
        let localClient: ResticClient
    }

    /// A narrow profile: the test needs a real backup, not the whole container.
    static func testProfile() throws -> BackupProfile {
        try BackupProfile(
            includePaths: ["/srv/hindsight-dataset", "/etc/hostname"],
            excludePatterns: ["**/lost+found"],
            oneFileSystem: false
        )
    }

    static func makeFixture(id: String) async throws -> Fixture {
        let (client, destination) = try await TestEnvironment.prepareTrustedClient(id: id)
        let root = try TestEnvironment.temporaryRepositoryRoot()
        let password = Secret(label: "repo/\(id)", value: "test-" + UUID().uuidString)
        let store = BinaryStore(directory: TestEnvironment.vendorBinDirectory())

        let plan = BackupPlan(
            server: try TestEnvironment.server(id: id),
            destination: destination,
            profile: try testProfile(),
            repositoryRoot: root,
            repositoryPassword: password
        )

        return Fixture(
            engine: BackupEngine(client: client, binaryStore: store, locks: RepositoryLockManager()),
            client: client,
            destination: destination,
            plan: plan,
            localClient: ResticClient(
                executable: try store.verifiedURL(for: try PinnedBinaries.hostRestic),
                location: .local(plan.repositoryURL),
                password: password
            )
        )
    }

    static func collect(
        _ stream: AsyncThrowingStream<BackupEvent, any Error>
    ) async throws -> (outcome: BackupOutcome, events: [BackupEvent]) {
        var events: [BackupEvent] = []
        var outcome: BackupOutcome?
        for try await event in stream {
            events.append(event)
            if case let .finished(value) = event { outcome = value }
        }
        guard let outcome else { throw BackupEngineError.noSummaryFromRestic }
        return (outcome, events)
    }

    @Test("backs up a server, and stock restic can read the result")
    func firstBackup() async throws {
        let fixture = try await Self.makeFixture(id: "backup-first")
        defer { Task { await fixture.client.closeControlMaster(on: fixture.destination) } }

        let (outcome, _) = try await Self.collect(fixture.engine.run(fixture.plan))

        let snapshot = try #require(outcome.filesystemSnapshot)
        #expect(outcome.filesNew > 0)
        #expect(outcome.bytesProcessed > 0)
        #expect(outcome.bytesAdded > 0)
        #expect(snapshot.tags.contains(.hindsight))
        #expect(snapshot.tags.contains(.profile("full")))

        // The repository must be readable by plain restic, with no Hindsight
        // involved. That is the promise the recovery kit makes.
        let listed = try await fixture.localClient.snapshots()
        #expect(listed.contains { $0.id == snapshot.id.value })
        #expect(listed.contains { Set($0.tags ?? []).contains(.profile("metadata")) })
    }

    @Test("a second backup of unchanged data adds almost nothing")
    func incrementalBackupIsSmall() async throws {
        let fixture = try await Self.makeFixture(id: "backup-incr")
        defer { Task { await fixture.client.closeControlMaster(on: fixture.destination) } }

        let (first, _) = try await Self.collect(fixture.engine.run(fixture.plan))
        let (second, _) = try await Self.collect(fixture.engine.run(fixture.plan))

        #expect(first.bytesAdded > 0)
        // Only new chunks cross the wire; a repeat run should be a rounding
        // error next to the first.
        #expect(second.bytesAdded < first.bytesAdded / 100)
        #expect(second.filesUnmodified > 0)
        #expect(second.filesNew == 0)
    }

    @Test("an incremental backup after a change adds about the size of the change")
    func incrementalBackupTracksChanges() async throws {
        let fixture = try await Self.makeFixture(id: "backup-change")
        defer { Task { await fixture.client.closeControlMaster(on: fixture.destination) } }

        let (first, _) = try await Self.collect(fixture.engine.run(fixture.plan))

        let path = "/srv/hindsight-dataset/uploads/new-file.bin"
        try await fixture.client.run(
            RemoteCommand(
                executable: "/bin/sh",
                arguments: ["-c", "head -c 8000000 /dev/urandom > \(ShellQuoting.quote(path))"],
                requiresRoot: true
            ),
            on: fixture.destination
        )
        defer {
            Task {
                try? await fixture.client.run(
                    RemoteCommand(executable: "/bin/rm", arguments: ["-f", path], requiresRoot: true),
                    on: fixture.destination
                )
            }
        }

        let (second, _) = try await Self.collect(fixture.engine.run(fixture.plan))

        #expect(second.filesNew >= 1)
        // Random data does not compress, so the increment should be close to
        // the 8 MB added, and nowhere near the whole dataset again.
        #expect(second.bytesAdded > 6_000_000)
        #expect(second.bytesAdded < 12_000_000)
        // The run read the whole dataset again but stored only the new file.
        #expect(second.bytesProcessed > second.bytesAdded)
        #expect(second.bytesProcessed >= first.bytesProcessed)
    }

    @Test("reports progress while the backup is running, not only at the end")
    func reportsProgress() async throws {
        let fixture = try await Self.makeFixture(id: "backup-progress")
        defer { Task { await fixture.client.closeControlMaster(on: fixture.destination) } }

        let path = "/srv/hindsight-dataset/uploads/progress.bin"
        try await fixture.client.run(
            RemoteCommand(
                executable: "/bin/sh",
                arguments: ["-c", "head -c 600000000 /dev/urandom > \(ShellQuoting.quote(path))"],
                requiresRoot: true
            ),
            on: fixture.destination,
            timeout: .seconds(120)
        )
        defer {
            Task {
                try? await fixture.client.run(
                    RemoteCommand(executable: "/bin/rm", arguments: ["-f", path], requiresRoot: true),
                    on: fixture.destination
                )
            }
        }

        let (_, events) = try await Self.collect(fixture.engine.run(fixture.plan))

        let progress = events.compactMap { event -> BackupProgress? in
            if case let .progress(value) = event { return value }
            return nil
        }
        #expect(!progress.isEmpty, "no progress was reported during a 600 MB backup")
        #expect(progress.contains { ($0.bytesDone ?? 0) > 0 })
        #expect(progress.allSatisfy { $0.percentDone >= 0 && $0.percentDone <= 1 })
    }

    @Test("records the server's metadata as its own snapshot")
    func recordsMetadata() async throws {
        let fixture = try await Self.makeFixture(id: "backup-metadata")
        defer { Task { await fixture.client.closeControlMaster(on: fixture.destination) } }

        let (outcome, _) = try await Self.collect(fixture.engine.run(fixture.plan))
        let metadata = try #require(outcome.metadataSnapshot)
        #expect(metadata.kind == .metadata)

        let listing = try await fixture.localClient.list(snapshot: metadata.id)
        let names = Set(listing.map(\.name))
        for expected in [
            "packages.txt",
            "systemd-units.txt",
            "os-release",
            "mounts.json",
            "hindsight-manifest.json",
        ] {
            #expect(names.contains(expected), "metadata is missing \(expected)")
        }

        // And the collector must leave nothing behind on the server.
        let leftovers = try await fixture.client.run(
            RemoteCommand(
                executable: "/bin/sh",
                arguments: ["-c", "[ -d /run/hindsight/meta ] && echo present || echo absent"],
                requiresRoot: true
            ),
            on: fixture.destination
        )
        #expect(leftovers.standardOutput == "absent")
    }

    @Test("two backups of one repository take turns instead of colliding")
    func concurrentBackupsSerialise() async throws {
        let fixture = try await Self.makeFixture(id: "backup-lock")
        defer { Task { await fixture.client.closeControlMaster(on: fixture.destination) } }

        async let first = Self.collect(fixture.engine.run(fixture.plan))
        async let second = Self.collect(fixture.engine.run(fixture.plan))
        let results = try await [first, second]

        #expect(results.count == 2)
        let snapshots = try await fixture.localClient.snapshots()
        // Two filesystem snapshots and two metadata snapshots, and a repository
        // that still reads cleanly.
        #expect(snapshots.count == 4)
        #expect(try await fixture.localClient.check().isHealthy)
    }

    @Test("append-only: the server can add snapshots but cannot delete them")
    func appendOnlyIsEnforced() async throws {
        let fixture = try await Self.makeFixture(id: "backup-append")
        defer { Task { await fixture.client.closeControlMaster(on: fixture.destination) } }

        _ = try await Self.collect(fixture.engine.run(fixture.plan))

        let credential = RestServerCredential.generate(username: fixture.plan.server.id.value)
        let server = RestServer(
            configuration: RestServer.Configuration(
                repositoryRoot: fixture.plan.repositoryRoot,
                credential: credential,
                htpasswdFile: fixture.plan.repositoryRoot.appendingPathComponent(".htpasswd-test"),
                executable: try BinaryStore(directory: TestEnvironment.vendorBinDirectory())
                    .verifiedURL(for: try PinnedBinaries.hostRestServer)
            )
        )
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let base = "http://\(credential.urlUserInfo)@127.0.0.1:\(port)/\(fixture.plan.server.id.value)"
        let runner = ProcessRunner()

        func status(_ method: String, _ path: String) async throws -> String {
            let result = try await runner.run(
                Command(
                    path: "/usr/bin/curl",
                    arguments: ["-s", "-o", "/dev/null", "-w", "%{http_code}", "-X", method, "\(base)/\(path)"],
                    additionalSecrets: [credential.password]
                )
            )
            return result.standardOutput
        }

        // Find a real data object to aim at.
        let packFile = try fixture.plan.repositoryURL
            .appendingPathComponent("data")
            .pathsOfFirstPackFile()
        let deleteData = try await status("DELETE", "data/\(packFile)")
        #expect(deleteData == "403", "append-only must refuse deleting a pack, got \(deleteData)")

        let deleteConfig = try await status("DELETE", "config")
        #expect(deleteConfig == "403", "append-only must refuse deleting the config")

        // Locks are the documented exception: restic has to be able to drop its
        // own stale locks, so a hostile server can too. That is a nuisance, not
        // data loss, and the design accounts for it.
        let deleteLock = try await status("DELETE", "locks/0000000000000000000000000000000000000000000000000000000000000000")
        #expect(deleteLock != "403", "locks must stay deletable, got \(deleteLock)")

        // Nothing was actually lost.
        #expect(try await fixture.localClient.check().isHealthy)
    }
}

extension URL {
    /// The name of some pack file in a restic `data/` tree.
    func pathsOfFirstPackFile() throws -> String {
        let contents = try FileManager.default.contentsOfDirectory(atPath: path)
        for prefix in contents.sorted() {
            let inner = try FileManager.default.contentsOfDirectory(
                atPath: appendingPathComponent(prefix).path
            )
            if let first = inner.sorted().first { return first }
        }
        throw CocoaError(.fileNoSuchFile)
    }
}

extension BackupIntegrationTests {
    @Test("an interrupted backup leaves nothing behind and the next run recovers")
    func interruptedBackupRecovers() async throws {
        let fixture = try await Self.makeFixture(id: "backup-interrupt")
        defer { Task { await fixture.client.closeControlMaster(on: fixture.destination) } }

        let path = "/srv/hindsight-dataset/uploads/interrupt.bin"
        try await fixture.client.run(
            RemoteCommand(
                executable: "/bin/sh",
                arguments: ["-c", "head -c 600000000 /dev/urandom > \(ShellQuoting.quote(path))"],
                requiresRoot: true
            ),
            on: fixture.destination,
            timeout: .seconds(180)
        )
        defer {
            Task {
                try? await fixture.client.run(
                    RemoteCommand(executable: "/bin/rm", arguments: ["-f", path], requiresRoot: true),
                    on: fixture.destination
                )
            }
        }

        let restServersBefore = try await countRestServerProcesses()

        let interrupted = Task {
            for try await event in fixture.engine.run(fixture.plan) {
                // Cancel once the transfer is genuinely under way.
                if case .progress = event { break }
            }
        }
        _ = try? await interrupted.value
        interrupted.cancel()

        // Give teardown a moment, then confirm nothing is left running.
        try await Task.sleep(for: .seconds(2))
        let restServersAfter = try await countRestServerProcesses()
        #expect(restServersAfter <= restServersBefore, "a rest-server was left running")

        // The next run must simply work, with no manual unlocking.
        let (outcome, _) = try await Self.collect(fixture.engine.run(fixture.plan))
        #expect(outcome.filesystemSnapshot != nil)
        #expect(try await fixture.localClient.check().isHealthy)
    }

    private func countRestServerProcesses() async throws -> Int {
        let result = try await ProcessRunner().run(
            Command(path: "/bin/sh", arguments: ["-c", "pgrep -f 'rest-server-0.14.0' | wc -l"]),
            allowedExitCodes: [0, 1]
        )
        return Int(result.standardOutput.trimmingCharacters(in: .whitespaces)) ?? 0
    }
}
