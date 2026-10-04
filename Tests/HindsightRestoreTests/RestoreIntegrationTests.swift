import Foundation
import HindsightCore
import HindsightProcess
import HindsightRestic
import HindsightSSH
import HindsightTestSupport
import Testing
@testable import HindsightRestore

/// Restores against the local Docker container.
///
/// Nothing here can touch a real server: the only policy these tests can
/// construct is `.localTestTargetOnly`, which demands both a local address and
/// the marker file, and the network policy refuses anything else before a
/// packet is sent.
@Suite(
    "Restore against the local test container",
    .enabled(if: TestEnvironment.allowsDestructiveOperations),
    .timeLimit(.minutes(10)),
    .serialized
)
struct RestoreIntegrationTests {
    struct Fixture {
        let client: SSHClient
        let destination: SSHDestination
        let facts: RemoteFacts
        let local: ResticClient
        let server: RestServer
        let localPort: Int
        let executor: RestoreExecutor
        let serverID: ServerID
        let password: Secret
        let remoteRestic: String
        /// The directory this test owns. Each test gets its own so they cannot
        /// interfere with each other or with the seeded dataset.
        let root: String
    }

    static func makeFixture(id: String) async throws -> Fixture {
        let (client, destination) = try await TestEnvironment.prepareTrustedClient(id: id)
        let repositoryRoot = try TestEnvironment.temporaryRepositoryRoot()
        let serverID = try ServerID(validating: id)
        let password = Secret(label: "repo", value: "restore-" + UUID().uuidString)
        let store = BinaryStore(directory: TestEnvironment.vendorBinDirectory())

        let local = ResticClient(
            executable: try store.verifiedURL(for: try PinnedBinaries.hostRestic),
            location: .local(repositoryRoot.appendingPathComponent(id)),
            password: password
        )
        _ = try await local.initializeIfNeeded()

        let facts = try await client.probeFacts(on: destination)
        let binary = try PinnedBinaries.restic(for: facts.platform.architecture)
        let remoteRestic = try await RemoteBinaryInstaller(client: client, store: store)
            .ensureInstalled(binary, on: destination, facts: facts)

        let server = RestServer(
            configuration: RestServer.Configuration(
                repositoryRoot: repositoryRoot,
                credential: RestServerCredential.generate(username: id),
                htpasswdFile: repositoryRoot.appendingPathComponent(".htpasswd"),
                executable: try store.verifiedURL(for: try PinnedBinaries.hostRestServer)
            )
        )
        let localPort = try await server.start()

        let root = "/srv/restore-tests/\(id)"
        return Fixture(
            client: client,
            destination: destination,
            facts: facts,
            local: local,
            server: server,
            localPort: localPort,
            executor: RestoreExecutor(
                client: client,
                binaryStore: store,
                locks: RepositoryLockManager(),
                policy: .localTestTargetOnly
            ),
            serverID: serverID,
            password: password,
            remoteRestic: remoteRestic,
            root: root
        )
    }

    static func shell(_ fixture: Fixture, _ script: String, timeout: Duration = .seconds(180)) async throws -> String {
        let result = try await fixture.client.run(
            RemoteCommand(executable: "/bin/sh", arguments: ["-c", script], requiresRoot: true),
            on: fixture.destination,
            timeout: timeout
        )
        return result.standardOutput
    }

    /// A small tree with known contents, so a restore can be compared exactly.
    static func seed(_ fixture: Fixture) async throws {
        try await shell(fixture, """
        rm -rf \(ShellQuoting.quote(fixture.root))
        mkdir -p \(ShellQuoting.quote(fixture.root))/nested
        printf 'original-one\\n' > \(ShellQuoting.quote(fixture.root))/one.txt
        printf 'original-two\\n' > \(ShellQuoting.quote(fixture.root))/two.txt
        head -c 2097152 /dev/urandom > \(ShellQuoting.quote(fixture.root))/blob.bin
        printf 'nested-original\\n' > \(ShellQuoting.quote(fixture.root))/nested/deep.txt
        chmod 640 \(ShellQuoting.quote(fixture.root))/two.txt
        """)
    }

    static func manifest(_ fixture: Fixture) async throws -> [String: String] {
        let output = try await shell(fixture, """
        cd \(ShellQuoting.quote(fixture.root)) && find . -type f -print0 | sort -z | xargs -0 sha256sum
        """)
        var manifest: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            manifest[parts[1].trimmingCharacters(in: .whitespaces)] = parts[0]
        }
        return manifest
    }

    static func session(_ fixture: Fixture, remotePort: Int) async -> RestoreSession {
        RestoreSession(
            jobID: .generate(),
            destination: fixture.destination,
            remoteResticPath: fixture.remoteRestic,
            repositorySecret: Secret(
                label: "repo-url",
                value: await fixture.server.repositoryURL(remotePort: remotePort, serverID: fixture.serverID)
            ),
            repositoryPassword: fixture.password
        )
    }

    static func backUp(_ fixture: Fixture, session: RestoreSession, tag: String) async throws -> SnapshotID {
        let result = try await fixture.client.run(
            RemoteCommand(
                executable: fixture.remoteRestic,
                arguments: ["backup", "--json", "--tag", tag, fixture.root],
                secretEnvironment: [
                    "RESTIC_REPOSITORY": session.repositorySecret,
                    "RESTIC_PASSWORD": session.repositoryPassword,
                ],
                requiresRoot: true
            ),
            on: fixture.destination,
            timeout: .seconds(600)
        )
        for line in result.standardOutputLines.reversed() {
            if case let .summary(summary) = ResticMessage.decode(line: line), let id = summary.snapshotID {
                return SnapshotID(unchecked: id)
            }
        }
        throw RestoreExecutionError.nothingToRestore
    }

    static func teardown(_ fixture: Fixture) async {
        try? await shell(fixture, "rm -rf \(ShellQuoting.quote(fixture.root))")
        await fixture.server.stop()
        await fixture.client.closeControlMaster(on: fixture.destination)
    }

    @Test("restores changed and deleted files exactly, byte for byte")
    func standardRestoreReturnsOriginalBytes() async throws {
        let fixture = try await Self.makeFixture(id: "restore-standard")
        defer { Task { await Self.teardown(fixture) } }

        try fixture.executor.authorize(facts: fixture.facts, destination: fixture.destination)
        try await Self.seed(fixture)
        let original = try await Self.manifest(fixture)
        #expect(original.count == 4)

        try await fixture.client.withReverseForward(
            toLocalPort: fixture.localPort,
            on: fixture.destination
        ) { remotePort in
            let session = await Self.session(fixture, remotePort: remotePort)
            let snapshot = try await Self.backUp(fixture, session: session, tag: "before")

            // Mutate three ways: change a file, delete a file, add a file.
            try await Self.shell(fixture, """
            printf 'tampered\\n' > \(ShellQuoting.quote(fixture.root))/one.txt
            rm -f \(ShellQuoting.quote(fixture.root))/nested/deep.txt
            printf 'added-after\\n' > \(ShellQuoting.quote(fixture.root))/extra.txt
            """)
            let mutated = try await Self.manifest(fixture)
            #expect(mutated["./one.txt"] != original["./one.txt"])
            #expect(mutated["./nested/deep.txt"] == nil)
            #expect(mutated["./extra.txt"] != nil)

            let plan = RestorePlan(
                snapshotID: snapshot,
                scope: .paths([fixture.root]),
                target: .inPlace,
                mode: .standard,
                serverHostname: fixture.destination.host
            )

            // The preview comes from diffing the safety snapshot against the
            // source, so it is exact rather than an estimate.
            let preview = try await fixture.executor.prepare(
                plan: plan,
                paths: [fixture.root],
                session: session,
                local: fixture.local
            )
            #expect(preview.modified.contains { $0.path.hasSuffix("/one.txt") })
            #expect(preview.added.contains { $0.path.hasSuffix("/nested/deep.txt") })
            #expect(preview.removed.contains { $0.path.hasSuffix("/extra.txt") })

            let restored = try await fixture.executor.restoreFiles(
                plan: plan,
                paths: [fixture.root],
                into: "/",
                session: session
            )
            #expect(restored > 0)

            let after = try await Self.manifest(fixture)
            // Everything the snapshot held is back, byte for byte.
            for (path, digest) in original {
                #expect(after[path] == digest, "\(path) did not come back unchanged")
            }
            // And the file added afterwards is still there, because a restore
            // of selected paths does not delete what it did not back up.
            #expect(after["./extra.txt"] == mutated["./extra.txt"])

            // Permissions come back too, not just contents.
            let mode = try await Self.shell(
                fixture,
                "stat -c '%a' \(ShellQuoting.quote(fixture.root))/two.txt"
            )
            #expect(mode.trimmingCharacters(in: .whitespacesAndNewlines) == "640")
        }
    }

    @Test("the safety snapshot can undo the restore")
    func safetySnapshotUndoesTheRestore() async throws {
        let fixture = try await Self.makeFixture(id: "restore-undo")
        defer { Task { await Self.teardown(fixture) } }

        try fixture.executor.authorize(facts: fixture.facts, destination: fixture.destination)
        try await Self.seed(fixture)

        try await fixture.client.withReverseForward(
            toLocalPort: fixture.localPort,
            on: fixture.destination
        ) { remotePort in
            let session = await Self.session(fixture, remotePort: remotePort)
            let snapshot = try await Self.backUp(fixture, session: session, tag: "before")

            try await Self.shell(fixture, """
            printf 'the state we might want back\\n' > \(ShellQuoting.quote(fixture.root))/one.txt
            """)
            let beforeRestore = try await Self.manifest(fixture)

            let plan = RestorePlan(
                snapshotID: snapshot,
                scope: .paths([fixture.root]),
                target: .inPlace,
                mode: .standard,
                serverHostname: fixture.destination.host
            )
            let preview = try await fixture.executor.prepare(
                plan: plan,
                paths: [fixture.root],
                session: session,
                local: fixture.local
            )
            _ = try await fixture.executor.restoreFiles(
                plan: plan,
                paths: [fixture.root],
                into: "/",
                session: session
            )
            #expect(try await Self.manifest(fixture)["./one.txt"] != beforeRestore["./one.txt"])

            // Undo: restoring the safety snapshot puts back exactly what the
            // restore overwrote. This is the whole reason it is taken.
            let undo = RestorePlan(
                snapshotID: preview.safetySnapshotID,
                scope: .paths([fixture.root]),
                target: .inPlace,
                mode: .standard,
                serverHostname: fixture.destination.host
            )
            _ = try await fixture.executor.restoreFiles(
                plan: undo,
                paths: [fixture.root],
                into: "/",
                session: session
            )

            let afterUndo = try await Self.manifest(fixture)
            for (path, digest) in beforeRestore {
                #expect(afterUndo[path] == digest, "\(path) was not returned by the undo")
            }
        }
    }

    @Test("the safety snapshot is tagged so it is never mistaken for a backup")
    func safetySnapshotIsTagged() async throws {
        let fixture = try await Self.makeFixture(id: "restore-tags")
        defer { Task { await Self.teardown(fixture) } }

        try fixture.executor.authorize(facts: fixture.facts, destination: fixture.destination)
        try await Self.seed(fixture)

        try await fixture.client.withReverseForward(
            toLocalPort: fixture.localPort,
            on: fixture.destination
        ) { remotePort in
            let session = await Self.session(fixture, remotePort: remotePort)
            let snapshot = try await Self.backUp(fixture, session: session, tag: "before")

            let plan = RestorePlan(
                snapshotID: snapshot,
                scope: .paths([fixture.root]),
                target: .inPlace,
                mode: .standard,
                serverHostname: fixture.destination.host
            )
            let preview = try await fixture.executor.prepare(
                plan: plan,
                paths: [fixture.root],
                session: session,
                local: fixture.local
            )

            let safety = try await fixture.local.snapshots(tag: .safety)
            #expect(safety.contains { $0.id == preview.safetySnapshotID.value })

            let recorded = try #require(safety.first { $0.id == preview.safetySnapshotID.value })
            let tags = Set(recorded.tags ?? [])
            #expect(tags.contains(.safety))
            #expect(tags.contains(.restore(session.jobID)))
            // Its kind is inferred from the tags, so it is excluded from the
            // ordinary timeline and from ordinary retention.
            #expect(recorded.toSnapshot().kind == .safety)
        }
    }

    @Test("stages and swaps with the service stopped, and reports the downtime")
    func minimalDowntimeSwapsAtomically() async throws {
        let fixture = try await Self.makeFixture(id: "restore-minimal")
        defer { Task { await Self.teardown(fixture) } }

        try fixture.executor.authorize(facts: fixture.facts, destination: fixture.destination)
        try await Self.seed(fixture)

        try await fixture.client.withReverseForward(
            toLocalPort: fixture.localPort,
            on: fixture.destination
        ) { remotePort in
            let session = await Self.session(fixture, remotePort: remotePort)
            let snapshot = try await Self.backUp(fixture, session: session, tag: "before")
            let original = try await Self.manifest(fixture)

            try await Self.shell(fixture, """
            printf 'tampered\\n' > \(ShellQuoting.quote(fixture.root))/one.txt
            rm -f \(ShellQuoting.quote(fixture.root))/nested/deep.txt
            """)

            let staging = fixture.root + ".hindsight-staging"
            let retired = fixture.root + ".hindsight-retired"

            // Staging has to share a filesystem with the live data, or the
            // swap is a copy and the downtime claim is false.
            #expect(
                try await fixture.executor.stagingIsOnSameFilesystem(
                    livePath: fixture.root,
                    stagingPath: staging,
                    session: session
                )
            )

            let plan = RestorePlan(
                snapshotID: snapshot,
                scope: .paths([fixture.root]),
                target: .inPlace,
                mode: .minimalDowntime,
                serverHostname: fixture.destination.host
            )

            // The slow part happens while the live data is untouched.
            _ = try await fixture.executor.restoreFiles(
                plan: plan,
                paths: [fixture.root],
                into: staging,
                session: session
            )
            #expect(try await Self.manifest(fixture)["./one.txt"] != original["./one.txt"])

            let swapStarted = ContinuousClock.now
            try await fixture.executor.swapStaged(
                livePath: fixture.root,
                stagingPath: staging + fixture.root,
                retiredPath: retired,
                session: session
            )
            let downtime = ContinuousClock.now - swapStarted

            let after = try await Self.manifest(fixture)
            for (path, digest) in original {
                #expect(after[path] == digest, "\(path) was not swapped in correctly")
            }
            // Two renames on one filesystem, so the swap is quick enough that
            // the "minimal downtime" claim holds.
            #expect(downtime < .seconds(5), "the swap took \(downtime), which is not a swap")

            try await Self.shell(fixture, "rm -rf \(ShellQuoting.quote(retired)) \(ShellQuoting.quote(staging))")
        }
    }

    @Test("restores to an alternate path without touching the live data")
    func restoresToAlternatePath() async throws {
        let fixture = try await Self.makeFixture(id: "restore-alternate")
        defer { Task { await Self.teardown(fixture) } }

        try fixture.executor.authorize(facts: fixture.facts, destination: fixture.destination)
        try await Self.seed(fixture)

        try await fixture.client.withReverseForward(
            toLocalPort: fixture.localPort,
            on: fixture.destination
        ) { remotePort in
            let session = await Self.session(fixture, remotePort: remotePort)
            let snapshot = try await Self.backUp(fixture, session: session, tag: "before")

            try await Self.shell(fixture, "printf 'live-changed\\n' > \(ShellQuoting.quote(fixture.root))/one.txt")
            let liveBefore = try await Self.manifest(fixture)

            let inspect = "/tmp/inspect-\(UUID().uuidString)"
            let plan = RestorePlan(
                snapshotID: snapshot,
                scope: .paths([fixture.root]),
                target: .alternatePath(inspect),
                mode: .standard,
                serverHostname: fixture.destination.host
            )
            _ = try await fixture.executor.restoreFiles(
                plan: plan,
                paths: [fixture.root],
                into: inspect,
                session: session
            )

            let copied = try await Self.shell(
                fixture,
                "cat \(ShellQuoting.quote(inspect + fixture.root))/one.txt"
            )
            #expect(copied.trimmingCharacters(in: .whitespacesAndNewlines) == "original-one")
            // The live copy is untouched, which is the point of a clone.
            #expect(try await Self.manifest(fixture) == liveBefore)

            try await Self.shell(fixture, "rm -rf \(ShellQuoting.quote(inspect))")
        }
    }

    @Test("refuses to write the key it logs in with")
    func refusesToOverwriteOwnAccess() async throws {
        let fixture = try await Self.makeFixture(id: "restore-selfharm")
        defer { Task { await Self.teardown(fixture) } }

        try fixture.executor.authorize(facts: fixture.facts, destination: fixture.destination)
        try await Self.seed(fixture)

        try await fixture.client.withReverseForward(
            toLocalPort: fixture.localPort,
            on: fixture.destination
        ) { remotePort in
            let session = await Self.session(fixture, remotePort: remotePort)
            let snapshot = try await Self.backUp(fixture, session: session, tag: "before")

            let plan = RestorePlan(
                snapshotID: snapshot,
                scope: .fullServer,
                target: .inPlace,
                mode: .standard,
                optedInExclusions: [.authorizedKeys],
                serverHostname: fixture.destination.host,
                sshAuthorizedKeysPath: "/root/.ssh/authorized_keys"
            )

            // Even with the category opted into, and before any file is
            // written, this must be refused.
            await #expect(throws: RestoreSafetyError.self) {
                try await fixture.executor.prepare(
                    plan: plan,
                    paths: ["/root/.ssh/authorized_keys"],
                    session: session,
                    local: fixture.local
                )
            }

            // And the server is still reachable, which is the thing that
            // matters.
            #expect(try await Self.shell(fixture, "echo still-here")
                .trimmingCharacters(in: .whitespacesAndNewlines) == "still-here")
        }
    }
}
