import Foundation
import GRDB
import HindsightCore
import Testing
@testable import HindsightCatalog

func makeServer(
    id: String = "web-01",
    name: String = "Web 01",
    host: String = "198.51.100.10"
) throws -> Server {
    try Server(
        id: ServerID(validating: id),
        name: name,
        endpoint: SSHEndpoint(host: host, port: 22, user: "root"),
        authentication: .managedKey,
        privilege: .root,
        platform: Platform(
            distributionID: "ubuntu",
            versionID: "24.04",
            prettyName: "Ubuntu 24.04 LTS",
            kernelRelease: "6.8.0",
            architecture: .aarch64
        )
    )
}

func makeSnapshot(
    id: String,
    time: Date = Date(timeIntervalSince1970: 1_760_000_000),
    tags: Set<String> = [],
    kind: SnapshotKind = .filesystem
) throws -> Snapshot {
    Snapshot(
        id: try SnapshotID(validating: id),
        time: time,
        hostname: "web-01",
        paths: ["/etc", "/home"],
        tags: tags,
        kind: kind,
        sizeBytes: 4096,
        dataAddedBytes: 128
    )
}

func temporaryCatalogURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("hindsight-catalog-\(UUID().uuidString)")
        .appendingPathComponent("catalog.sqlite")
}

@Suite("Catalog migrations")
struct CatalogMigrationTests {
    @Test("a fresh catalog reaches the current schema")
    func freshCatalogMigrates() throws {
        let catalog = try Catalog.inMemory()
        let applied = try catalog.read { try CatalogSchema.migrator.appliedMigrations($0) }
        #expect(applied == CatalogSchema.migrator.migrations)
        #expect(!applied.isEmpty)
    }

    @Test("every expected table exists")
    func tablesExist() throws {
        let catalog = try Catalog.inMemory()
        let tables = [
            "server", "repository", "schedule", "retentionPolicy", "pathRule",
            "snapshot", "snapshotTag", "job", "jobEvent", "integrityCheck",
            "restore",
        ]
        try catalog.read { database in
            for table in tables {
                let exists = try database.tableExists(table)
                #expect(exists, "missing table \(table)")
            }
        }
    }

    @Test("migrating twice is a no-op")
    func migrationIsIdempotent() throws {
        let url = temporaryCatalogURL()
        let first = try Catalog.open(at: url)
        try first.save(try makeServer())
        try first.migrate()
        #expect(try first.servers().count == 1)

        let second = try Catalog.open(at: url)
        #expect(try second.servers().count == 1)
    }

    @Test("refuses a catalog written by a newer build instead of guessing")
    func refusesUnknownSchema() throws {
        let url = temporaryCatalogURL()
        let catalog = try Catalog.open(at: url)
        try catalog.write { database in
            try database.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99-from-the-future')"
            )
        }

        #expect(throws: CatalogError.self) { try Catalog.open(at: url) }
    }

    @Test("opens a catalog holding rows orphaned by an older build")
    func migratesPastOrphanedEvents() throws {
        let url = temporaryCatalogURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // A catalog as an earlier build left it: migrated as far as v2, with a
        // job's events still in it after the job itself went away. Written with
        // references off, which is how they got there — a hand-run DELETE, or a
        // build before the catalog enforced them.
        let pool = try DatabasePool(path: url.path, configuration: Catalog.configuration())
        try CatalogSchema.migrator.migrate(pool)
        try pool.writeWithoutTransaction { database in
            try database.execute(sql: "DELETE FROM grdb_migrations WHERE identifier LIKE 'v3%' OR identifier LIKE 'v4%'")
            try database.execute(sql: "ALTER TABLE server DROP COLUMN pausedAt")
            try database.execute(sql: "PRAGMA foreign_keys = OFF")
            try database.execute(
                sql: """
                INSERT INTO jobEvent (jobId, sequence, at, level, message)
                VALUES ('gone', 1, '2026-10-04 15:45:44.080', 'error', 'restic is not here')
                """
            )
            try database.execute(
                sql: """
                INSERT INTO repository (id, serverId, path, createdAt, checkRotationIndex, checkRotationDivisor)
                VALUES ('repo-gone', 'gone', '/tmp/gone', '2026-10-04 15:44:01.648', 0, 4)
                """
            )
        }

        let catalog = try Catalog.open(at: url)
        let applied = try catalog.read { try CatalogSchema.migrator.appliedMigrations($0) }
        #expect(applied == CatalogSchema.migrator.migrations)
        let (events, repositories, violations) = try catalog.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM jobEvent") ?? -1,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM repository") ?? -1,
                try Row.fetchAll(database, sql: "PRAGMA foreign_key_check").count
            )
        }
        #expect(events == 0)
        #expect(repositories == 0)
        #expect(violations == 0)
    }

    @Test("drops Coolify's tables and columns from a catalog that has them")
    func migratesPastCoolify() throws {
        let url = temporaryCatalogURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let pool = try DatabasePool(path: url.path, configuration: Catalog.configuration())

        // A catalog as it stood before Coolify was removed, with rows in the
        // tables that are about to go: dropping a populated table is the case
        // that has to work, since every installed catalog has one.
        try CatalogSchema.migrator.migrate(pool, upTo: "v4-orphaned-rows")
        try pool.write { database in
            try database.execute(
                sql: """
                INSERT INTO server (id, name, host, port, user, authentication, privilege, createdAt, coolifyVersion)
                VALUES ('web-01', 'Web', '198.51.100.10', 22, 'root', '{}', 'root', '2026-10-01 00:00:00.000', '4.3.23')
                """
            )
            try database.execute(
                sql: """
                INSERT INTO coolifyResource (uuid, serverId, kind, name, discoverySource, lastSeenAt)
                VALUES ('abc', 'web-01', 'database', 'acme-db', 'api', '2026-10-01 00:00:00.000')
                """
            )
            try database.execute(
                sql: """
                INSERT INTO schedule (id, serverId, resourceUUID, cadence, onlyOnACPower, enabled)
                VALUES ('s1', 'web-01', 'abc', x'7b7d', 0, 1)
                """
            )
        }

        let catalog = try Catalog.open(at: url)
        let (applied, tables, serverColumns, violations, servers) = try catalog.read { database in
            (
                try CatalogSchema.migrator.appliedMigrations(database),
                [
                    try database.tableExists("coolifyResource"),
                    try database.tableExists("resourceCapture"),
                ],
                try database.columns(in: "server").map(\.name),
                try Row.fetchAll(database, sql: "PRAGMA foreign_key_check").count,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM server") ?? -1
            )
        }
        #expect(applied == CatalogSchema.migrator.migrations)
        #expect(tables == [false, false])
        #expect(!serverColumns.contains("coolifyVersion"))
        #expect(violations == 0)
        // The server itself survives: only Coolify's part of it goes.
        #expect(servers == 1)
    }

    @Test("enforces foreign keys so an orphaned row cannot be written")
    func enforcesForeignKeys() throws {
        let catalog = try Catalog.inMemory()
        #expect(throws: (any Error).self) {
            try catalog.save(
                RepositoryRecord(id: "r1", serverId: "no-such-server", path: "/tmp/repo")
            )
        }
    }
}

@Suite("Catalog round trips")
struct CatalogRoundTripTests {
    @Test("stores and reads a server, including its probed platform")
    func serverRoundTrip() throws {
        let catalog = try Catalog.inMemory()
        let server = try makeServer()
        try catalog.save(server)

        let loaded = try #require(try catalog.server(server.id))
        #expect(loaded == server)
        #expect(loaded.platform?.architecture == .aarch64)
        try #expect(catalog.servers().count == 1)
    }

    @Test("saving a server again keeps when it was first added")
    func saveKeepsCreationDate() throws {
        let catalog = try Catalog.inMemory()
        var server = try makeServer()
        let id = server.id.value
        try catalog.save(server)
        let created = try catalog.read { try ServerRecord.fetchOne($0, key: id) }?.createdAt

        server.name = "Renamed"
        try catalog.save(server)

        let after = try catalog.read { try ServerRecord.fetchOne($0, key: id) }
        #expect(after?.createdAt == created)
        #expect(after?.name == "Renamed")
    }

    @Test("deleting a server takes its repositories and snapshots with it")
    func deleteCascades() throws {
        let catalog = try Catalog.inMemory()
        let server = try makeServer()
        try catalog.save(server)
        try catalog.save(RepositoryRecord(id: "r1", serverId: server.id.value, path: "/tmp/repo"))
        try catalog.record(try makeSnapshot(id: "aa11", tags: ["hindsight"]), inRepository: "r1")

        try catalog.deleteServer(server.id)

        try #expect(catalog.repository("r1") == nil)
        try #expect(catalog.snapshots(inRepository: "r1").isEmpty)
        try catalog.read { database in
            let tagCount = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM snapshotTag")
            #expect(tagCount == 0)
        }
    }

    @Test("stores snapshots newest first, with their tags")
    func snapshotRoundTrip() throws {
        let catalog = try Catalog.inMemory()
        let server = try makeServer()
        try catalog.save(server)
        try catalog.save(RepositoryRecord(id: "r1", serverId: server.id.value, path: "/tmp/repo"))

        let older = try makeSnapshot(id: "aa11", time: Date(timeIntervalSince1970: 1_000), tags: ["hindsight"])
        let newer = try makeSnapshot(
            id: "bb22",
            time: Date(timeIntervalSince1970: 2_000),
            tags: ["hindsight", SnapshotTag.databaseName("res-1").rawValue]
        )
        try catalog.record([older, newer], inRepository: "r1")

        let all = try catalog.snapshots(inRepository: "r1")
        #expect(all.map(\.id.value) == ["bb22", "aa11"])
        #expect(all.first?.tags.contains(.databaseName("res-1")) == true)
        try #expect(catalog.snapshot(older.id) == older)
    }

    @Test("finds a tag's whole history by tag alone")
    func findsByTag() throws {
        let catalog = try Catalog.inMemory()
        let server = try makeServer()
        try catalog.save(server)
        try catalog.save(RepositoryRecord(id: "r1", serverId: server.id.value, path: "/tmp/repo"))

        let tagged = try makeSnapshot(
            id: "cc33",
            time: Date(timeIntervalSince1970: 3_000),
            tags: [SnapshotTag.databaseName("res-1").rawValue]
        )
        let other = try makeSnapshot(
            id: "dd44",
            time: Date(timeIntervalSince1970: 4_000),
            tags: [SnapshotTag.databaseName("res-2").rawValue]
        )
        try catalog.record([tagged, other], inRepository: "r1")

        let history = try catalog.snapshots(taggedWith: .databaseName("res-1"))
        #expect(history.map(\.id.value) == ["cc33"])
        try #expect(catalog.snapshots(taggedWith: .databaseName("missing")).isEmpty)
    }

    @Test("re-recording a snapshot replaces its tags rather than accumulating them")
    func reRecordingReplacesTags() throws {
        let catalog = try Catalog.inMemory()
        let server = try makeServer()
        try catalog.save(server)
        try catalog.save(RepositoryRecord(id: "r1", serverId: server.id.value, path: "/tmp/repo"))

        try catalog.record(try makeSnapshot(id: "ee55", tags: ["old"]), inRepository: "r1")
        try catalog.record(try makeSnapshot(id: "ee55", tags: ["new"]), inRepository: "r1")

        let snapshot = try #require(try catalog.snapshot(SnapshotID(unchecked: "ee55")))
        #expect(snapshot.tags == ["new"])
    }

    @Test("forgets snapshots a prune removed, so the catalog stays truthful")
    func retainOnlyRemovesPrunedSnapshots() throws {
        let catalog = try Catalog.inMemory()
        let server = try makeServer()
        try catalog.save(server)
        try catalog.save(RepositoryRecord(id: "r1", serverId: server.id.value, path: "/tmp/repo"))
        try catalog.record(
            [try makeSnapshot(id: "aa11"), try makeSnapshot(id: "bb22"), try makeSnapshot(id: "cc33")],
            inRepository: "r1"
        )

        let removed = try catalog.retainOnly(resticIDs: ["bb22"], inRepository: "r1")
        #expect(removed == 2)
        try #expect(catalog.snapshots(inRepository: "r1").map(\.id.value) == ["bb22"])
    }

    @Test("falls back to the documented retention defaults when none is stored")
    func retentionFallsBackToDefaults() throws {
        let catalog = try Catalog.inMemory()
        let server = try makeServer()
        try catalog.save(server)

        try #expect(catalog.retentionPolicy(forServer: server.id, scope: .filesystem) == .filesystemDefault)
        try #expect(catalog.retentionPolicy(forServer: server.id, scope: .databaseDumps) == .databaseDumpsDefault)

        let custom = try RetentionPolicy(
            scope: .filesystem,
            keepWithinHours: 48,
            keepDaily: 30,
            keepWeekly: 0,
            keepMonthly: 0,
            keepYearly: 0
        )
        try catalog.save(RetentionPolicyRecord(id: "p1", serverId: server.id.value, policy: custom))
        try #expect(catalog.retentionPolicy(forServer: server.id, scope: .filesystem) == custom)
    }

    @Test("stores a schedule with its cadence and time zone")
    func scheduleRoundTrip() throws {
        let catalog = try Catalog.inMemory()
        let server = try makeServer()
        try catalog.save(server)

        let schedule = try Schedule(
            cadence: .dailyAt(TimeOfDay(hour: 3, minute: 30)),
            onlyOnACPower: true,
            timeZoneIdentifier: "Europe/Berlin"
        )
        try catalog.save(ScheduleRecord(id: "s1", serverId: server.id.value, schedule: schedule))

        let loaded = try #require(try catalog.schedules(forServer: server.id).first)
        try #expect(loaded.toSchedule() == schedule)
        try #expect(catalog.enabledSchedules().count == 1)
    }

    @Test("tracks jobs and their events in order")
    func jobRoundTrip() throws {
        let catalog = try Catalog.inMemory()
        let server = try makeServer()
        try catalog.save(server)

        let jobID = JobID.generate()
        var job = JobRecord(id: jobID, serverId: server.id, kind: .backup)
        try catalog.save(job)

        try catalog.append("starting", to: jobID)
        try catalog.append("scanned 10 files", to: jobID)
        try catalog.append("failed to read /root/secret", level: .error, to: jobID)

        job.state = .failed
        job.finishedAt = Date()
        job.errorText = "one file could not be read"
        try catalog.save(job)

        let events = try catalog.events(for: jobID)
        #expect(events.map(\.sequence) == [1, 2, 3])
        #expect(events.last?.level == .error)
        try #expect(catalog.job(jobID)?.state == .failed)
        try #expect(catalog.jobs(forServer: server.id).count == 1)
        try #expect(catalog.activeJobs().isEmpty)
    }

    @Test("counts a queued job as active and a finished one as not")
    func activeJobs() throws {
        let catalog = try Catalog.inMemory()
        let server = try makeServer()
        try catalog.save(server)

        var waiting = JobRecord(id: JobID.generate(), serverId: server.id, kind: .backup)
        waiting.state = .waitingForRepository
        try catalog.save(waiting)

        var done = JobRecord(id: JobID.generate(), serverId: server.id, kind: .check(readDataSubset: "1/4"))
        done.state = .succeeded
        try catalog.save(done)

        let active = try catalog.activeJobs()
        #expect(active.map(\.id) == [waiting.id])
    }

    @Test("bounds job event history so a noisy job cannot grow the catalog without end")
    func trimsEvents() throws {
        let catalog = try Catalog.inMemory()
        let server = try makeServer()
        try catalog.save(server)
        let jobID = JobID.generate()
        try catalog.save(JobRecord(id: jobID, serverId: server.id, kind: .backup))

        for index in 1...500 {
            try catalog.append("line \(index)", to: jobID)
        }
        let removed = try catalog.trimEvents(for: jobID, keeping: 100)

        #expect(removed == 400)
        let events = try catalog.events(for: jobID)
        #expect(events.count == 100)
        #expect(events.first?.message == "line 401")
        #expect(events.last?.message == "line 500")
    }

    @Test("records integrity checks and finds the most recent")
    func integrityChecks() throws {
        let catalog = try Catalog.inMemory()
        let server = try makeServer()
        try catalog.save(server)
        try catalog.save(RepositoryRecord(id: "r1", serverId: server.id.value, path: "/tmp/repo"))

        var older = IntegrityCheckRecord(
            repositoryId: "r1",
            kind: .structure,
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        older.outcome = .passed
        try catalog.save(older)

        var newer = IntegrityCheckRecord(
            repositoryId: "r1",
            kind: .readDataSubset,
            subsetIndex: 2,
            subsetDivisor: 4,
            startedAt: Date(timeIntervalSince1970: 2_000)
        )
        newer.outcome = .failed
        newer.errorText = "pack 1a2b3c is damaged"
        try catalog.save(newer)

        let latest = try #require(try catalog.latestCheck(forRepository: "r1"))
        #expect(latest.id == newer.id)
        #expect(latest.outcome == .failed)
        #expect(latest.subsetIndex == 2)
        try #expect(catalog.checks(forRepository: "r1").count == 2)
    }
}
