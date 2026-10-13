import Foundation
import HindsightCore
import HindsightSSH
import Testing
@testable import HindsightEngine

@Suite("Database discovery")
struct DatabaseDiscoveryTests {
    @Test("recognises the usual database images")
    func recognisesImages() {
        #expect(DatabaseDiscovery.engineForImage("postgres:16-alpine") == .postgres)
        #expect(DatabaseDiscovery.engineForImage("docker.io/library/postgres:15") == .postgres)
        #expect(DatabaseDiscovery.engineForImage("timescale/timescaledb:latest-pg16") == .postgres)
        #expect(DatabaseDiscovery.engineForImage("pgvector/pgvector:pg16") == .postgres)
        #expect(DatabaseDiscovery.engineForImage("mysql:8.4") == .mysql)
        #expect(DatabaseDiscovery.engineForImage("percona:8") == .mysql)
        #expect(DatabaseDiscovery.engineForImage("mongo:7") == .mongodb)
        #expect(DatabaseDiscovery.engineForImage("redis:7-alpine") == .redis)
        #expect(DatabaseDiscovery.engineForImage("valkey/valkey:8") == .redis)
    }

    @Test("does not mistake mariadb for mysql")
    func mariadbIsNotMysql() {
        // "mariadb" contains "maria", not "mysql", but the image often
        // mentions both; the longest keyword must win.
        #expect(DatabaseDiscovery.engineForImage("mariadb:11") == .mariadb)
        #expect(DatabaseDiscovery.engineForImage("mariadb/server:11") == .mariadb)
    }

    @Test("ignores sidecars that only talk about databases")
    func ignoresSidecars() {
        #expect(DatabaseDiscovery.engineForImage("prometheuscommunity/postgres-exporter") == nil)
        #expect(DatabaseDiscovery.engineForImage("oliver006/redis_exporter:latest") == nil)
        #expect(DatabaseDiscovery.engineForImage("tiredofit/db-backup") == nil)
        #expect(DatabaseDiscovery.engineForImage("nginx:alpine") == nil)
        #expect(DatabaseDiscovery.engineForImage("") == nil)
    }

    @Test("parses docker ps output")
    func parsesContainers() {
        let lines = [
            "app-db\tpostgres:16",
            "cache\tredis:7",
            "web\tnginx:alpine",
            "",
            "malformed-line",
        ]
        let targets = DatabaseDiscovery.parseContainers(lines)
        #expect(targets.count == 2)
        #expect(targets[0].engine == .postgres)
        #expect(targets[1].engine == .redis)
        #expect(targets[0].displayName == "postgres in app-db")
    }

    @Test("falls back to listening ports for services on the host")
    func findsHostServices() throws {
        let facts = RemoteFacts(
            platform: Platform(
                distributionID: "ubuntu", versionID: "24.04", prettyName: "Ubuntu",
                kernelRelease: "6.8", architecture: .aarch64
            ),
            homeDirectory: "/root",
            hasPasswordlessSudo: false,
            hasNice: true,
            hasIonice: true,
            dockerServerVersion: nil,
            containerNames: [],
            hasTestMarker: true,
            mounts: [],
            listeningPorts: [22, 5432, 6379]
        )
        let discovery = DatabaseDiscovery(client: makeUnusedClient())
        let targets = discovery.hostTargets(from: facts, excluding: [])
        let engines: [DatabaseEngine] = targets.map(\.engine).sorted { $0.rawValue < $1.rawValue }
        #expect(engines == [DatabaseEngine.postgres, DatabaseEngine.redis])
    }

    @Test("prefers a container over a host service on the same port")
    func prefersContainers() throws {
        let facts = RemoteFacts(
            platform: Platform(
                distributionID: "ubuntu", versionID: "24.04", prettyName: "Ubuntu",
                kernelRelease: "6.8", architecture: .aarch64
            ),
            homeDirectory: "/root",
            hasPasswordlessSudo: false,
            hasNice: true,
            hasIonice: true,
            dockerServerVersion: "27.0",
            containerNames: [],
            hasTestMarker: true,
            mounts: [],
            listeningPorts: [5432]
        )
        // A published container port looks exactly like a host service, and
        // dumping the same database twice would be wasteful and confusing.
        let container = DatabaseTarget(engine: .postgres, location: .container(name: "db", image: "postgres:16"))
        let discovery = DatabaseDiscovery(client: makeUnusedClient())
        #expect(discovery.hostTargets(from: facts, excluding: [container]).isEmpty)
    }
}

@Suite("Database dump commands")
struct DatabaseDumpCommandTests {
    @Test("dumps Postgres in a format that restores selectively")
    func postgresPipeline() throws {
        let target = DatabaseTarget(
            engine: .postgres,
            location: .container(name: "app-db", image: "postgres:16"),
            databaseName: "app_production"
        )
        let pipeline = try DatabaseDumpCommand.pipeline(for: target)
        // The password variable is forwarded by name, which `docker exec`
        // leaves unset in the container when the caller has not set it — so
        // Postgres reaching its socket as the container's own superuser,
        // which is how this has always worked, is unaffected. Verified
        // against postgres:16 in Docker.
        #expect(pipeline.hasPrefix("docker exec -i -e PGPASSWORD app-db sh -c "))
        #expect(pipeline.contains("pg_dump"))
        #expect(pipeline.contains("--format=custom"))
        #expect(pipeline.contains("app_production"))
    }

    @Test("dumps MySQL inside a transaction")
    func mysqlPipeline() throws {
        let target = DatabaseTarget(
            engine: .mysql,
            location: .container(name: "shop-db", image: "mysql:8.4")
        )
        let pipeline = try DatabaseDumpCommand.pipeline(for: target)
        #expect(pipeline.contains("mysqldump"))
        #expect(pipeline.contains("--single-transaction"))
        #expect(pipeline.contains("--all-databases"))
    }

    @Test("uses the MariaDB client for MariaDB")
    func mariadbPipeline() throws {
        let target = DatabaseTarget(engine: .mariadb, location: .hostService(port: 3306))
        let pipeline = try DatabaseDumpCommand.pipeline(for: target)
        #expect(pipeline.contains("mariadb-dump"))
        #expect(!pipeline.contains("mysqldump"))
    }

    @Test("waits for the Redis save it started, rather than guessing")
    func redisWaitsForSave() throws {
        let target = DatabaseTarget(engine: .redis, location: .container(name: "cache", image: "redis:7"))
        let pipeline = try DatabaseDumpCommand.pipeline(for: target)
        #expect(pipeline.contains("BGSAVE"))
        #expect(pipeline.contains("LASTSAVE"))
        // Comparing the save timestamp is the only reliable completion signal.
        #expect(pipeline.contains("previous"))
        #expect(pipeline.contains("exit 75"))
    }

    @Test("captures Postgres roles separately, since they live outside a database")
    func capturesGlobals() {
        let postgres = DatabaseTarget(engine: .postgres, location: .hostService(port: 5432))
        #expect(DatabaseDumpCommand.globalsCommand(for: postgres)?.contains("pg_dumpall --globals-only") == true)
        #expect(DatabaseDumpCommand.globalsCommand(for: DatabaseTarget(
            engine: .mysql, location: .hostService(port: 3306)
        )) == nil)
    }

    @Test("names and tags each dump so its history is queryable on its own")
    func namesAndTags() {
        let target = DatabaseTarget(
            engine: .postgres,
            location: .container(name: "db", image: "postgres:16")
        )
        // A path per source, so each database gets its own retention group:
        // restic groups by host and paths, and six containers sharing one path
        // shared one history.
        #expect(DatabaseDumpCommand.fileName(for: target, database: "app") == "postgres-db/app.dump")
        let tags = DatabaseDumpCommand.tags(for: target, database: "app").map(\.rawValue)
        #expect(tags.contains("db:postgres"))
        #expect(tags.contains("dbname:app"))
        #expect(tags.contains("dbsrc:postgres-db"))
    }

    @Test("says which engines give a transactional dump and which do not")
    func describesConsistency() {
        #expect(DatabaseEngine.postgres.isTransactionalDump)
        #expect(DatabaseEngine.mysql.isTransactionalDump)
        #expect(!DatabaseEngine.redis.isTransactionalDump)

        let backup = DatabaseBackup(client: makeUnusedClient())
        #expect(backup.consistencyNote(for: DatabaseTarget(engine: .postgres, location: .hostService(port: 5432))) == nil)
        #expect(backup.consistencyNote(for: DatabaseTarget(engine: .redis, location: .hostService(port: 6379)))?
            .contains("not a transaction") == true)
        #expect(backup.consistencyNote(for: DatabaseTarget(engine: .mysql, location: .hostService(port: 3306)))?
            .contains("MyISAM") == true)
    }
}
