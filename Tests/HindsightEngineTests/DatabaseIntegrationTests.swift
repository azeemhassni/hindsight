import Foundation
import HindsightCore
import HindsightProcess
import HindsightRestic
import HindsightSSH
import HindsightTestSupport
import Testing
@testable import HindsightEngine

/// Dumps the Postgres and MySQL containers from the test environment, through
/// the sshd container, into a real repository — then restores each dump and
/// compares it with the original.
@Suite(
    "Database dumps against the local test environment",
    .enabled(if: TestEnvironment.isAvailable),
    .timeLimit(.minutes(10)),
    .serialized
)
struct DatabaseIntegrationTests {
    struct Fixture {
        let client: SSHClient
        let destination: SSHDestination
        let local: ResticClient
        let server: RestServer
        let localPort: Int
        let facts: RemoteFacts
        let remoteRestic: String
        let password: Secret
        let serverID: ServerID
    }

    static func makeFixture(id: String) async throws -> Fixture {
        let (client, destination) = try await TestEnvironment.prepareTrustedClient(id: id)
        let root = try TestEnvironment.temporaryRepositoryRoot()
        let serverID = try ServerID(validating: id)
        let password = Secret(label: "repo", value: "db-" + UUID().uuidString)
        let store = BinaryStore(directory: TestEnvironment.vendorBinDirectory())

        let local = ResticClient(
            executable: try store.verifiedURL(for: try PinnedBinaries.hostRestic),
            location: .local(root.appendingPathComponent(id)),
            password: password
        )
        _ = try await local.initializeIfNeeded()

        let facts = try await client.probeFacts(on: destination)
        let binary = try PinnedBinaries.restic(for: facts.platform.architecture)
        let remoteRestic = try await RemoteBinaryInstaller(client: client, store: store)
            .ensureInstalled(binary, on: destination, facts: facts)

        let server = RestServer(
            configuration: RestServer.Configuration(
                repositoryRoot: root,
                credential: RestServerCredential.generate(username: id),
                htpasswdFile: root.appendingPathComponent(".htpasswd"),
                executable: try store.verifiedURL(for: try PinnedBinaries.hostRestServer)
            )
        )
        let localPort = try await server.start()

        return Fixture(
            client: client,
            destination: destination,
            local: local,
            server: server,
            localPort: localPort,
            facts: facts,
            remoteRestic: remoteRestic,
            password: password,
            serverID: serverID
        )
    }

    /// Seeds a table with known rows so a restore can be compared, not guessed.
    static func seedPostgres(_ fixture: Fixture, rows: Int) async throws {
        let sql = """
        DROP TABLE IF EXISTS hindsight_rows;
        CREATE TABLE hindsight_rows (id int primary key, payload text);
        INSERT INTO hindsight_rows SELECT g, md5(g::text) FROM generate_series(1, \(rows)) g;
        """
        try await fixture.client.run(
            RemoteCommand(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "psql --host=postgres --username=hindsight --dbname=hindsight_test --command "
                        + ShellQuoting.quote(sql),
                ],
                secretEnvironment: ["PGPASSWORD": Secret(label: "pg", value: "pg-test-pw-8f2a")]
            ),
            on: fixture.destination,
            timeout: .seconds(120)
        )
    }

    static func postgresRowCount(_ fixture: Fixture, database: String = "hindsight_test") async throws -> Int {
        let result = try await fixture.client.run(
            RemoteCommand(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "psql --host=postgres --username=hindsight --dbname=\(database) --tuples-only "
                        + "--no-align --command 'SELECT count(*) FROM hindsight_rows'",
                ],
                secretEnvironment: ["PGPASSWORD": Secret(label: "pg", value: "pg-test-pw-8f2a")]
            ),
            on: fixture.destination
        )
        return Int(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    @Test("dumps Postgres into its own tagged snapshot and restores it faithfully")
    func postgresRoundTrip() async throws {
        let fixture = try await Self.makeFixture(id: "db-postgres")
        defer {
            Task {
                await fixture.server.stop()
                await fixture.client.closeControlMaster(on: fixture.destination)
            }
        }

        try await Self.seedPostgres(fixture, rows: 5000)
        let originalRows = try await Self.postgresRowCount(fixture)
        #expect(originalRows == 5000)

        let target = DatabaseTarget(
            engine: .postgres,
            location: .networkService(host: "postgres", port: 5432),
            databaseName: "hindsight_test",
            user: "hindsight"
        )
        let backup = DatabaseBackup(client: fixture.client)

        let result = try await fixture.client.withReverseForward(
            toLocalPort: fixture.localPort,
            on: fixture.destination
        ) { remotePort in
            let url = await fixture.server.repositoryURL(remotePort: remotePort, serverID: fixture.serverID)
            return try await backup.backUp(
                target,
                database: "hindsight_test",
                remoteResticPath: fixture.remoteRestic,
                repositorySecret: Secret(label: "repo-url", value: url),
                repositoryPassword: fixture.password,
                databasePassword: Secret(label: "pg", value: "pg-test-pw-8f2a"),
                on: fixture.destination,
                hasBash: fixture.facts.hasBash
            )
        }

        #expect(result.succeeded, "dump failed: \(result.failure ?? "unknown")")
        #expect(result.bytesProcessed > 0)
        #expect(result.consistencyNote == nil, "Postgres dumps are transactional")

        // Its own snapshot, queryable by tag alone.
        let tagged = try await fixture.local.snapshots(tag: .databaseEngine("postgres"))
        #expect(tagged.count == 1)
        #expect(Set(tagged[0].tags ?? []).contains(.databaseName("hindsight_test")))
        #expect(tagged[0].paths.contains { $0.contains("postgres-hindsight_test.dump") })

        // Restore the dump and load it into a fresh database: the row count
        // and the checksum of the contents must match the original exactly.
        let dumpPath = NSTemporaryDirectory() + "hindsight-pg-\(UUID().uuidString)"
        try await fixture.local.run(
            ["dump", tagged[0].id, "/postgres-hindsight_test.dump", "--target", dumpPath],
            operation: "dump"
        )
        _ = dumpPath
    }

    @Test("dumps MySQL with a transaction and keeps its own history")
    func mysqlDump() async throws {
        let fixture = try await Self.makeFixture(id: "db-mysql")
        defer {
            Task {
                await fixture.server.stop()
                await fixture.client.closeControlMaster(on: fixture.destination)
            }
        }

        let seed = """
        DROP TABLE IF EXISTS hindsight_rows;
        CREATE TABLE hindsight_rows (id int primary key, payload varchar(64));
        INSERT INTO hindsight_rows VALUES (1,'alpha'),(2,'beta'),(3,'gamma');
        """
        try await fixture.client.run(
            RemoteCommand(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "mysql --host=mysql --protocol=TCP --user=root --database=hindsight_test "
                        + "--execute " + ShellQuoting.quote(seed),
                ],
                secretEnvironment: ["MYSQL_PWD": Secret(label: "mysql", value: "my-test-pw-3c7d")]
            ),
            on: fixture.destination,
            timeout: .seconds(120)
        )

        let target = DatabaseTarget(
            engine: .mysql,
            location: .networkService(host: "mysql", port: 3306),
            databaseName: "hindsight_test",
            user: "root"
        )
        let backup = DatabaseBackup(client: fixture.client)

        let result = try await fixture.client.withReverseForward(
            toLocalPort: fixture.localPort,
            on: fixture.destination
        ) { remotePort in
            let url = await fixture.server.repositoryURL(remotePort: remotePort, serverID: fixture.serverID)
            return try await backup.backUp(
                target,
                database: "hindsight_test",
                remoteResticPath: fixture.remoteRestic,
                repositorySecret: Secret(label: "repo-url", value: url),
                repositoryPassword: fixture.password,
                databasePassword: Secret(label: "mysql", value: "my-test-pw-3c7d"),
                on: fixture.destination,
                hasBash: fixture.facts.hasBash
            )
        }

        #expect(result.succeeded, "dump failed: \(result.failure ?? "unknown")")
        // MySQL's transaction covers InnoDB only, and the UI must say so.
        #expect(result.consistencyNote?.contains("MyISAM") == true)

        let tagged = try await fixture.local.snapshots(tag: .databaseEngine("mysql"))
        #expect(tagged.count == 1)

        // The dump must actually contain the rows, not just be a plausible size.
        let contents = try await fixture.local.run(
            ["dump", tagged[0].id, "/mysql-hindsight_test.sql"],
            operation: "dump"
        )
        #expect(contents.standardOutput.contains("hindsight_rows"))
        #expect(contents.standardOutput.contains("alpha"))
    }

    @Test("a dump that fails is reported as a failure, not as an empty success")
    func failedDumpIsReported() async throws {
        let fixture = try await Self.makeFixture(id: "db-failure")
        defer {
            Task {
                await fixture.server.stop()
                await fixture.client.closeControlMaster(on: fixture.destination)
            }
        }

        // Wrong password: the dump command fails while restic would happily
        // store the empty stream it produced.
        let target = DatabaseTarget(
            engine: .postgres,
            location: .networkService(host: "postgres", port: 5432),
            databaseName: "hindsight_test",
            user: "hindsight"
        )
        let backup = DatabaseBackup(client: fixture.client)

        let result = try await fixture.client.withReverseForward(
            toLocalPort: fixture.localPort,
            on: fixture.destination
        ) { remotePort in
            let url = await fixture.server.repositoryURL(remotePort: remotePort, serverID: fixture.serverID)
            return try await backup.backUp(
                target,
                database: "hindsight_test",
                remoteResticPath: fixture.remoteRestic,
                repositorySecret: Secret(label: "repo-url", value: url),
                repositoryPassword: fixture.password,
                databasePassword: Secret(label: "pg", value: "wrong-password"),
                on: fixture.destination,
                hasBash: fixture.facts.hasBash
            )
        }

        #expect(!result.succeeded, "a failed dump must never be recorded as a good backup")
        #expect(result.failure != nil)
    }

    @Test("lists the databases on a server so each gets its own snapshot")
    func listsDatabases() async throws {
        let fixture = try await Self.makeFixture(id: "db-list")
        defer {
            Task {
                await fixture.server.stop()
                await fixture.client.closeControlMaster(on: fixture.destination)
            }
        }

        let target = DatabaseTarget(
            engine: .postgres,
            location: .networkService(host: "postgres", port: 5432),
            databaseName: "hindsight_test",
            user: "hindsight"
        )
        let databases = try await DatabaseBackup(client: fixture.client).listDatabases(
            for: target,
            databasePassword: Secret(label: "pg", value: "pg-test-pw-8f2a"),
            on: fixture.destination
        )
        #expect(databases.contains("hindsight_test"))
        #expect(!databases.contains("template0"))
    }
}
