import Foundation
import HindsightCoolify
import HindsightCore
import Testing
@testable import HindsightEngine

@Suite("Coolify resource backup")
struct CoolifyResourceBackupTests {
    private func backup() -> CoolifyResourceBackup {
        CoolifyResourceBackup(client: makeUnusedClient())
    }

    private func resource(
        kind: CoolifyResourceKind = .database,
        subType: String? = "standalone-postgresql",
        volumes: [CoolifyVolume] = [
            CoolifyVolume(name: "postgres-data-abc", mountPath: "/var/lib/postgresql/data"),
        ]
    ) -> CoolifyResource {
        CoolifyResource(
            uuid: "abc123",
            name: "acme-db",
            kind: kind,
            projectName: "acme",
            environmentName: "production",
            subType: subType,
            containerName: "abc123",
            image: "postgres:16-alpine",
            volumes: volumes
        )
    }

    @Test("captures the config directory and the volume's real location")
    func capturesTheRightPaths() {
        let paths = backup().capturePaths(for: resource())
        #expect(paths.contains("/data/coolify/databases/abc123"))
        // A named volume's bytes live under Docker's volume root, not inside
        // the container.
        #expect(paths.contains("/var/lib/docker/volumes/postgres-data-abc/_data"))
    }

    @Test("captures a bind mount at its host path")
    func capturesBindMounts() {
        let bound = resource(
            volumes: [CoolifyVolume(name: "", mountPath: "/app/data", hostPath: "/srv/app-data")]
        )
        #expect(backup().capturePaths(for: bound).contains("/srv/app-data"))
    }

    @Test("tags the snapshot so the resource's history stands alone")
    func tagsTheSnapshot() {
        let tags = resource().snapshotTags.map(\.rawValue)
        #expect(tags.contains("coolify:abc123"))
        #expect(tags.contains("coolify-project:acme"))
        #expect(tags.contains("coolify-env:production"))
        #expect(tags.contains("hindsight"))
    }

    @Test("maps Coolify's sub-types onto database engines")
    func mapsEngines() {
        #expect(backup().databaseEngine(for: resource(subType: "standalone-postgresql")) == .postgres)
        #expect(backup().databaseEngine(for: resource(subType: "standalone-mysql")) == .mysql)
        #expect(backup().databaseEngine(for: resource(subType: "standalone-mariadb")) == .mariadb)
        #expect(backup().databaseEngine(for: resource(subType: "standalone-mongodb")) == .mongodb)
        #expect(backup().databaseEngine(for: resource(subType: "standalone-redis")) == .redis)
        #expect(backup().databaseEngine(for: resource(subType: "standalone-keydb")) == .redis)
        #expect(backup().databaseEngine(for: resource(subType: nil)) == nil)
    }

    @Test("does not look for a database engine on an application")
    func ignoresEngineForApplications() {
        let application = resource(kind: .application, subType: nil)
        #expect(backup().databaseEngine(for: application) == nil)
        #expect(application.configurationDirectory == "/data/coolify/applications/abc123")
    }

    @Test("an outcome is only a success when a snapshot actually exists")
    func outcomeHonesty() {
        var outcome = CoolifyResourceOutcome(
            resourceUUID: "abc",
            snapshotID: nil,
            dumps: [],
            capturedPaths: [],
            bytesAdded: 0,
            failure: nil
        )
        // No snapshot and no stated failure is still not a success.
        #expect(!outcome.succeeded)

        outcome.snapshotID = SnapshotID(unchecked: "aa11")
        #expect(outcome.succeeded)

        outcome.failure = "something went wrong"
        #expect(!outcome.succeeded)
    }
}
