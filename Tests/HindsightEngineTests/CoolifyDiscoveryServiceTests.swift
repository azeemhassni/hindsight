import Foundation
import HindsightCatalog
import HindsightCoolify
import HindsightCore
import HindsightKeychain
import HindsightProtocol
import Testing
@testable import HindsightAgentKit
@testable import HindsightEngine

@Suite("Coolify version detection")
struct CoolifyVersionTests {
    @Test("reads the version off Coolify's own image tag")
    func readsVersionFromImage() {
        // Coolify writes no version label, so the image tag is the only source
        // that does not need the API. Verified against a live v4.3.23.
        #expect(CoolifyDiscovery.version(fromImage: "coollabsio/coolify:4.3.23\n") == "4.3.23")
        #expect(CoolifyDiscovery.version(fromImage: "ghcr.io/coollabsio/coolify:4.3.23") == "4.3.23")
    }

    @Test("says nothing rather than something useless")
    func refusesUninformativeTags() {
        #expect(CoolifyDiscovery.version(fromImage: "coollabsio/coolify:latest") == nil)
        #expect(CoolifyDiscovery.version(fromImage: "coollabsio/coolify") == nil)
        #expect(CoolifyDiscovery.version(fromImage: "") == nil)
        // A registry port is a colon that is not a tag.
        #expect(CoolifyDiscovery.version(fromImage: "registry:5000/coolify") == nil)
    }
}

@Suite("Coolify resources in the catalog")
struct CoolifyCatalogTests {
    private func catalogWithServer() throws -> (Catalog, ServerID) {
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
        return (catalog, id)
    }

    @Test("replaces what is known, rather than accumulating resources that are gone")
    func replacesResources() throws {
        let (catalog, id) = try catalogWithServer()
        try catalog.replaceCoolifyResources(
            [
                CoolifyResourceRecord(
                    uuid: "a",
                    serverId: id.value,
                    kind: "database",
                    name: "acme-db",
                    projectName: "acme",
                    environmentName: "production",
                    discoverySource: "containerLabels"
                ),
                CoolifyResourceRecord(
                    uuid: "b",
                    serverId: id.value,
                    kind: "application",
                    name: "acme-web",
                    projectName: "acme",
                    environmentName: "production",
                    discoverySource: "containerLabels"
                ),
            ],
            forServer: id
        )
        #expect(try catalog.coolifyResources(forServer: id).count == 2)

        // The application was deleted in Coolify; a stale row would offer a
        // backup of something that no longer exists.
        try catalog.replaceCoolifyResources(
            [
                CoolifyResourceRecord(
                    uuid: "a",
                    serverId: id.value,
                    kind: "database",
                    name: "acme-db",
                    projectName: "acme",
                    environmentName: "production",
                    discoverySource: "api"
                ),
            ],
            forServer: id
        )
        let remaining = try catalog.coolifyResources(forServer: id)
        #expect(remaining.map(\.uuid) == ["a"])
        #expect(remaining.first?.discoverySource == "api")
    }

    @Test("falls back to the cached tree, marked incomplete, when the server is unreachable")
    func fallsBackToCache() async throws {
        let (catalog, id) = try catalogWithServer()
        try catalog.replaceCoolifyResources(
            [
                CoolifyResourceRecord(
                    uuid: "a",
                    serverId: id.value,
                    kind: "database",
                    name: "acme-db",
                    projectName: "acme",
                    environmentName: "production",
                    discoverySource: "containerLabels"
                ),
            ],
            forServer: id
        )
        let core = AgentCore(
            configuration: .fallback,
            catalog: catalog,
            secrets: InMemorySecretStore(),
            version: "test"
        )

        let cached = try await core.cachedCoolifyTree(forServer: id)
        #expect(cached.resources.map(\.name) == ["acme-db"])
        // Anything cached is by definition not current, and the interface has
        // to be able to say so.
        #expect(cached.mayBeIncomplete)
        #expect(cached.sourceExplanation.contains("Last seen"))
    }

    @Test("counts a resource's last backup from the snapshot tagged with its uuid")
    func reportsLastBackup() async throws {
        let (catalog, id) = try catalogWithServer()
        try catalog.save(RepositoryRecord(id: "repo", serverId: id.value, path: "/tmp/repo"))
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try catalog.record(
            Snapshot(
                id: SnapshotID(unchecked: "deadbeefdeadbeef"),
                time: when,
                hostname: "web-01",
                paths: ["/data/coolify/databases/a"],
                tags: ["hindsight", SnapshotTag.coolifyResource("a").rawValue],
                kind: .filesystem
            ),
            inRepository: "repo"
        )
        let core = AgentCore(
            configuration: .fallback,
            catalog: catalog,
            secrets: InMemorySecretStore(),
            version: "test"
        )

        let tree = CoolifyTree.assemble(
            [CoolifyResource(uuid: "a", name: "acme-db", kind: .database)],
            source: .containerLabels
        )
        let report = await core.report(for: tree, serverID: id)
        #expect(report.resources.first?.lastBackupAt == when)
    }
}

@Suite("Coolify resource reports")
struct CoolifyReportGroupingTests {
    private func resource(
        _ uuid: String,
        project: String?,
        environment: String?
    ) -> CoolifyResourceReport {
        CoolifyResourceReport(
            uuid: uuid,
            name: uuid,
            kind: "application",
            projectName: project,
            environmentName: environment,
            engine: nil,
            isRunning: true,
            volumeCount: 0,
            lastBackupAt: nil
        )
    }

    @Test("groups by project and environment for display")
    func groups() {
        let report = CoolifyTreeReport(
            resources: [
                resource("a", project: "acme", environment: "production"),
                resource("b", project: "acme", environment: "staging"),
                resource("c", project: "beta", environment: "production"),
            ],
            source: "containerLabels",
            sourceExplanation: "",
            coolifyVersion: nil,
            mayBeIncomplete: false
        )
        #expect(report.grouped.map(\.project) == ["acme", "beta"])
        #expect(report.grouped[0].environments.map(\.name) == ["production", "staging"])
    }

    @Test("keeps a resource that names no project rather than dropping it")
    func keepsUngrouped() {
        let report = CoolifyTreeReport(
            resources: [resource("orphan", project: nil, environment: nil)],
            source: "containerLabels",
            sourceExplanation: "",
            coolifyVersion: nil,
            mayBeIncomplete: false
        )
        #expect(report.grouped.map(\.project) == ["Ungrouped"])
        #expect(report.grouped[0].environments.first?.resources.count == 1)
    }
}
