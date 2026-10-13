import Foundation
import HindsightCore
import Testing
@testable import HindsightEngine

/// Putting a dump back. The half that was missing: restoring a dump snapshot
/// used to write a `.dump` file at the root of the server and leave the
/// database exactly as it was.
@Suite("Loading a dump")
struct DatabaseLoadTests {
    private func container(_ engine: DatabaseEngine, _ name: String = "db") -> DatabaseTarget {
        DatabaseTarget(engine: engine, location: .container(name: name, image: "\(engine.rawValue):16"))
    }

    @Test("Postgres is replaced, not merged into")
    func postgresReplaces() throws {
        let command = try DatabaseLoadCommand.loadCommand(
            for: container(.postgres),
            database: "umami"
        )
        #expect(command.contains("pg_restore"))
        // Without these a restore leaves a mixture of two moments.
        #expect(command.contains("--clean"))
        #expect(command.contains("--if-exists"))
        #expect(command.contains("--dbname=\"umami\""))
    }

    @Test("MySQL and MariaDB use their own client")
    func mysqlAndMariaDB() throws {
        let mysql = try DatabaseLoadCommand.loadCommand(for: container(.mysql), database: "shop")
        #expect(mysql.hasPrefix("mysql "))
        #expect(mysql.contains("\"shop\""))

        let maria = try DatabaseLoadCommand.loadCommand(for: container(.mariadb), database: "shop")
        #expect(maria.hasPrefix("mariadb "))
    }

    @Test("MongoDB drops what it replaces")
    func mongo() throws {
        let command = try DatabaseLoadCommand.loadCommand(for: container(.mongodb), database: "app")
        #expect(command.contains("mongorestore"))
        #expect(command.contains("--drop"))
        #expect(command.contains("--nsInclude=app.*"))
    }

    /// An RDB is what Redis reads when it starts, so there is nothing to load
    /// it into. Saying so is better than appearing to work.
    @Test("Redis is refused, with what to do instead")
    func redisIsRefused() {
        #expect(!DatabaseLoadCommand.canLoadIntoRunningServer(.redis))
        let refusal = DatabaseLoadCommand.refusal(for: .redis, container: "cache")
        #expect(refusal?.contains("cache") == true)
        #expect(refusal?.contains("CONFIG GET dir") == true)

        #expect(throws: (any Error).self) {
            _ = try DatabaseLoadCommand.loadCommand(for: container(.redis), database: nil)
        }
        // And every other engine is not refused.
        for engine in [DatabaseEngine.postgres, .mysql, .mariadb, .mongodb] {
            #expect(DatabaseLoadCommand.refusal(for: engine, container: "db") == nil)
        }
    }

    /// The backup run backwards: read from the repository, pipe into the
    /// database, and fail if either end fails.
    @Test("the pipeline streams from the repository into the database")
    func pipelineReadsAndLoads() throws {
        let script = try DatabaseLoadCommand.pipeline(
            for: container(.postgres, "app-db"),
            database: "umami",
            snapshotID: "aa11bb22",
            dumpPath: "/postgres-umami.dump",
            remoteResticPath: "/usr/local/bin/restic",
            hasBash: true
        )
        #expect(script.contains("set -o pipefail"))
        // Quoted only where quoting changes anything, which is what
        // `ShellQuoting` does.
        #expect(script.contains("dump aa11bb22 /postgres-umami.dump"))
        #expect(script.contains("docker exec -i"))
        #expect(script.contains("app-db"))
        #expect(script.contains("pg_restore"))
        // The password reaches the client inside the container by name, not
        // by value: `docker exec` does not inherit the caller's environment,
        // and `-e NAME=value` would put it in argv.
        #expect(script.contains("-e PGPASSWORD "))
        #expect(!script.contains("-e PGPASSWORD="))
    }

    /// Without `pipefail` a load whose source could not be read still exits
    /// zero, because the loader succeeded at loading nothing.
    @Test("a shell without pipefail still reports a failed read")
    func shellFallbackChecksBothEnds() throws {
        let script = try DatabaseLoadCommand.pipeline(
            for: container(.postgres),
            database: "app",
            snapshotID: "aa11",
            dumpPath: "/postgres-app.dump",
            remoteResticPath: "/usr/local/bin/restic",
            hasBash: false
        )
        #expect(!script.contains("pipefail"))
        #expect(script.contains("read_status"))
        #expect(script.contains("load_status"))
        #expect(script.contains("exit \"$read_status\""))
    }

    @Test("nothing is written to the server's disk on the way")
    func nothingTouchesTheFilesystem() throws {
        let script = try DatabaseLoadCommand.pipeline(
            for: container(.postgres),
            database: "app",
            snapshotID: "aa11",
            dumpPath: "/postgres-app.dump",
            remoteResticPath: "/usr/local/bin/restic",
            hasBash: true
        )
        // `restic dump` writes to standard output; `restore` would put a file
        // on the disk, and a dump left on a production server is a copy of the
        // database somebody has to remember to delete.
        #expect(script.contains(" dump "))
        #expect(!script.contains("restic restore"))
        #expect(!script.contains("--target"))
    }
}

/// restic applies retention per group, and a group is host plus paths. Six
/// containers each dumping a database called `postgres` shared one path, so
/// they shared one history: measured against restic 0.19.1, three databases
/// over three days with `--keep-daily 3` kept one arbitrary database per day
/// and removed every snapshot of another.
@Suite("Dumps keep their own history")
struct DumpGroupingTests {
    private func target(_ container: String) -> DatabaseTarget {
        DatabaseTarget(
            engine: .postgres,
            location: .container(name: container, image: "postgres:16")
        )
    }

    @Test("two containers with the same database name get different paths")
    func sameDatabaseDifferentContainers() {
        let first = DatabaseDumpCommand.fileName(for: target("app-db"), database: "postgres")
        let second = DatabaseDumpCommand.fileName(for: target("other-db"), database: "postgres")

        #expect(first != second, "a shared path is a shared retention group")
        #expect(first.contains("app-db"))
        #expect(second.contains("other-db"))
    }

    @Test("the path names the container it came from")
    func pathNamesTheSource() {
        let name = DatabaseDumpCommand.fileName(
            for: target("coolify-db"),
            database: "umami"
        )
        #expect(name == "postgres-coolify-db/umami.dump")
    }

    @Test("the source is tagged as well, so it need not be parsed out of a path")
    func sourceIsTagged() {
        let tags = DatabaseDumpCommand
            .tags(for: target("coolify-db"), database: "umami")
            .map(\.rawValue)
        #expect(tags.contains("dbsrc:postgres-coolify-db"))
        #expect(tags.contains("dbname:umami"))
        #expect(tags.contains("db:postgres"))
    }

    /// Redis dumps carry no database name, so before this they were
    /// indistinguishable: four containers, one path, one group.
    @Test("Redis dumps are told apart by their container")
    func redisDumpsAreDistinct() {
        func redis(_ container: String) -> DatabaseTarget {
            DatabaseTarget(engine: .redis, location: .container(name: container, image: "redis:7"))
        }
        let first = DatabaseDumpCommand.fileName(for: redis("cache"), database: nil)
        let second = DatabaseDumpCommand.fileName(for: redis("queue"), database: nil)
        #expect(first == "redis-cache/all.rdb")
        #expect(second == "redis-queue/all.rdb")
        #expect(first != second)
    }
}
