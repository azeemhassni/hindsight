import Foundation
import HindsightProtocol
import Testing
@testable import HindsightUI

/// Adding a machine to restore onto, from its connection details.
@MainActor
@Suite("Adding a restore target")
struct RestoreTargetFlowTests {
    private func model(
        hostKey: HostKeyReport? = HostKeyReport(
            keyType: "ssh-ed25519",
            base64Key: "AAAAC3NzaC1lZDI1NTE5",
            fingerprint: "SHA256:abc123"
        ),
        trusts: Bool = true,
        probes: Bool = true,
        adds: Bool = true,
        record: ((AgentRequest) -> Void)? = nil
    ) -> AppModel {
        let model = AppModel()
        model.send = { request in
            record?(request)
            switch request {
            case .scanHostKey:
                return hostKey.map { .hostKey($0) } ?? .failed(message: "unreachable")
            case .trustHostKey:
                return trusts ? .done : .failed(message: "refused")
            case .probeServer:
                return probes
                    ? .probe(ServerProbeReport(
                        prettyName: "Ubuntu 24.04",
                        architecture: "aarch64",
                        hasPasswordlessSudo: true,
                        dockerVersion: nil,
                        homeDirectory: "/root",
                        isTestTarget: false
                    ))
                    : .failed(message: "could not connect")
            case .addRestoreTarget:
                return adds ? .serverAdded(serverID: "web-02") : .failed(message: "refused")
            case .status:
                return .status(AgentStatus(version: "test", servers: [], runningJobs: []))
            default:
                return .done
            }
        }
        return model
    }

    private func flow(_ model: AppModel) -> RestoreTargetFlow {
        let flow = RestoreTargetFlow(model: model)
        flow.host = "198.51.100.20"
        flow.user = "root"
        flow.port = "22"
        return flow
    }

    @Test("will not scan without a host, user and valid port")
    func requiresDetails() {
        let flow = RestoreTargetFlow(model: model())
        #expect(!flow.canScan)
        flow.host = "198.51.100.20"
        flow.user = "root"
        #expect(flow.canScan)
        flow.port = "0"
        #expect(!flow.canScan, "port 0 is not a port")
        flow.port = "70000"
        #expect(!flow.canScan)
        flow.port = "2222"
        #expect(flow.canScan)
    }

    /// The key is shown before anything is trusted, because the whole point is
    /// that a person compares it with the machine.
    @Test("shows the host key before accepting it")
    func showsTheHostKeyFirst() async {
        var requests: [String] = []
        let model = model(record: { request in
            if case .trustHostKey = request { requests.append("trust") }
            if case .addRestoreTarget = request { requests.append("add") }
        })
        let flow = flow(model)

        await flow.scan()
        guard case let .confirmingHostKey(report) = flow.stage else {
            Issue.record("expected a fingerprint to compare, got \(flow.stage)")
            return
        }
        #expect(report.fingerprint == "SHA256:abc123")
        // Nothing has been trusted or recorded yet.
        #expect(requests.isEmpty)
    }

    @Test("records the machine once the key is accepted")
    func addsAfterConfirmation() async {
        let flow = flow(model())
        await flow.scan()
        await flow.confirmHostKey()

        guard case let .added(serverID, hostname, _) = flow.stage else {
            Issue.record("expected the machine to be added, got \(flow.stage)")
            return
        }
        #expect(serverID == "web-02")
        #expect(hostname == "198.51.100.20")
        #expect(flow.probe?.prettyName == "Ubuntu 24.04")
    }

    /// Finding out at restore time that the details were wrong is finding out
    /// too late.
    @Test("a connection that does not work is refused before it is recorded")
    func refusesAnUnreachableMachine() async {
        var added = false
        let model = model(probes: false, record: { request in
            if case .addRestoreTarget = request { added = true }
        })
        let flow = flow(model)

        await flow.scan()
        await flow.confirmHostKey()

        guard case .failed = flow.stage else {
            Issue.record("expected a failure, got \(flow.stage)")
            return
        }
        #expect(!added, "a machine that cannot be reached must not be recorded")
    }

    @Test("an unreachable host fails at the scan, before anything is trusted")
    func failsWhenTheHostCannotBeReached() async {
        let flow = flow(model(hostKey: nil))
        await flow.scan()
        guard case .failed = flow.stage else {
            Issue.record("expected a failure, got \(flow.stage)")
            return
        }
    }
}

/// A dump and a filesystem snapshot are different restores, and the sheet has
/// to treat them differently: one is loaded into a database, the other is
/// written onto a disk.
@MainActor
@Suite("Restoring a dump")
struct DumpRestoreFlowTests {
    private func makeFlow(databases: [DatabaseTargetReport]) -> RestoreFlow {
        let model = AppModel()
        model.send = { request in
            if case .discoverDatabases = request { return .databases(databases) }
            return .status(AgentStatus(version: "test", servers: [], runningJobs: []))
        }
        let flow = RestoreFlow(model: model, serverID: "web-01", serverHostname: "web-01.example")
        flow.snapshotID = "aa11"
        flow.isDatabaseDump = true
        flow.paths = ["/postgres-umami.dump"]
        flow.databaseName = "umami"
        return flow
    }

    private let postgres = DatabaseTargetReport(
        id: "postgres-app-db",
        engine: "postgres",
        displayName: "postgres in app-db",
        canLoadWhileRunning: true
    )
    private let redis = DatabaseTargetReport(
        id: "redis-cache",
        engine: "redis",
        displayName: "redis in cache",
        canLoadWhileRunning: false
    )

    @Test("a dump cannot be confirmed until a database is chosen")
    func needsADatabase() {
        let flow = makeFlow(databases: [postgres])
        flow.typedHostname = "web-01.example"
        #expect(!flow.canConfirm, "nowhere to load it yet")

        flow.loadIntoDatabase = postgres.id
        #expect(flow.canConfirm)
    }

    /// A filesystem restore needs a preview first; a dump has nothing to
    /// preview, because what it replaces is inside a database.
    @Test("a dump needs no preview, and a filesystem restore still does")
    func previewOnlyForFiles() {
        let dump = makeFlow(databases: [postgres])
        dump.loadIntoDatabase = postgres.id
        dump.typedHostname = "web-01.example"
        #expect(dump.preview == nil)
        #expect(dump.canConfirm)

        let files = makeFlow(databases: [])
        files.isDatabaseDump = false
        files.paths = []
        files.typedHostname = "web-01.example"
        #expect(!files.canConfirm, "a filesystem restore is confirmed on its preview")
    }

    @Test("the command carries where the dump goes, and only for a dump")
    func commandCarriesTheDestination() throws {
        let flow = makeFlow(databases: [postgres])
        flow.loadIntoDatabase = postgres.id
        let command = try #require(flow.command)
        #expect(command.loadIntoDatabase == "postgres-app-db")
        #expect(command.databaseName == "umami")

        // The same flow for files carries neither, so a filesystem restore
        // cannot be turned into a database write by a stale field.
        flow.isDatabaseDump = false
        let fileCommand = try #require(flow.command)
        #expect(fileCommand.loadIntoDatabase == nil)
        #expect(fileCommand.databaseName == nil)
    }

    @Test("chooses the only loadable database, and never an unloadable one")
    func choosesTheObviousDatabase() async {
        let flow = makeFlow(databases: [postgres, redis])
        await flow.loadDatabaseChoices()
        // Two were found, but only one can be loaded into while running.
        #expect(flow.availableDatabases.count == 2)
        #expect(flow.loadIntoDatabase == postgres.id)

        // With two loadable ones it must not guess.
        let ambiguous = makeFlow(databases: [
            postgres,
            DatabaseTargetReport(
                id: "postgres-other",
                engine: "postgres",
                displayName: "postgres in other",
                canLoadWhileRunning: true
            ),
        ])
        await ambiguous.loadDatabaseChoices()
        #expect(ambiguous.loadIntoDatabase == nil)
    }

    @Test("a Redis dump alone leaves nothing chosen")
    func redisIsNotChosen() async {
        let flow = makeFlow(databases: [redis])
        await flow.loadDatabaseChoices()
        #expect(flow.loadIntoDatabase == nil, "Redis cannot be loaded while running")
    }
}

/// Six Postgres containers each with a database called `postgres` produced six
/// snapshots that were identical in every way the sheet could show. The source
/// is recorded now, so a dump can say where it came from and be put back
/// there.
@MainActor
@Suite("Knowing where a dump came from")
struct DumpOriginTests {
    private func flowFor(source: String?, databases: [DatabaseTargetReport]) -> RestoreFlow {
        let model = AppModel()
        model.send = { request in
            if case .discoverDatabases = request { return .databases(databases) }
            return .status(AgentStatus(version: "test", servers: [], runningJobs: []))
        }
        let flow = RestoreFlow(model: model, serverID: "web-01", serverHostname: "web-01.example")
        flow.isDatabaseDump = true
        flow.snapshotID = "aa11"
        flow.databaseName = "postgres"
        flow.databaseSource = source
        return flow
    }

    private func report(_ id: String, _ name: String) -> DatabaseTargetReport {
        DatabaseTargetReport(
            id: id,
            engine: "postgres",
            displayName: name,
            canLoadWhileRunning: true
        )
    }

    @Test("says which database and container the dump holds")
    func describesTheOrigin() {
        let flow = flowFor(source: "postgres-coolify-db", databases: [])
        #expect(flow.dumpOrigin == "postgres in coolify-db")

        // Older dumps carry no source, and must not claim one.
        let older = flowFor(source: nil, databases: [])
        #expect(older.dumpOrigin == "postgres")
    }

    /// Guessing wrong here overwrites the wrong database.
    @Test("puts a dump back where it came from")
    func matchesTheSource() async {
        let flow = flowFor(
            source: "postgres-coolify-db",
            databases: [
                report("postgres-other-db", "postgres in other-db"),
                report("postgres-coolify-db", "postgres in coolify-db"),
                report("postgres-third-db", "postgres in third-db"),
            ]
        )
        await flow.loadDatabaseChoices()
        #expect(flow.loadIntoDatabase == "postgres-coolify-db")
        #expect(!flow.isLoadingElsewhere)
    }

    /// Three candidates and no recorded source is exactly when a guess would
    /// be wrong, so nothing is chosen.
    @Test("chooses nothing when there are several and no source")
    func refusesToGuess() async {
        let flow = flowFor(
            source: nil,
            databases: [
                report("postgres-one", "postgres in one"),
                report("postgres-two", "postgres in two"),
            ]
        )
        await flow.loadDatabaseChoices()
        #expect(flow.loadIntoDatabase == nil)
    }

    /// Restoring onto a replacement machine, where the container has a
    /// different name: nothing matches, so the person picks, and the sheet
    /// says it is not where the dump came from.
    @Test("says when a dump is going somewhere else")
    func noticesADifferentDestination() async {
        let flow = flowFor(
            source: "postgres-coolify-db",
            databases: [report("postgres-new-name", "postgres in new-name")]
        )
        await flow.loadDatabaseChoices()
        // One loadable candidate, so it is chosen — but it is not the original.
        #expect(flow.loadIntoDatabase == "postgres-new-name")
        #expect(flow.isLoadingElsewhere)
    }
}
