import Foundation
import HindsightCatalog
import HindsightCore
import HindsightKeychain
import HindsightProtocol
import HindsightRestic
import HindsightTestSupport
import Testing
@testable import HindsightAgentKit

/// Reading a repository through the agent.
///
/// The app asks for these because it holds no secrets: it cannot open a
/// repository itself, and the agent can.
@Suite("Repository reads over the protocol", .timeLimit(.minutes(3)))
struct AgentRepositoryReadTests {
    private static let password = "repository-read-test"

    private func makeCore() async throws -> (AgentCore, ServerID, SnapshotID) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hindsight reads \(UUID().uuidString)")
        let repositories = base.appendingPathComponent("repos")
        let id = try ServerID(validating: "web-01")
        let repository = repositories.appendingPathComponent(id.value)

        // A real repository with real files in it.
        let data = base.appendingPathComponent("data")
        try FileManager.default.createDirectory(
            at: data.appendingPathComponent("etc"),
            withIntermediateDirectories: true
        )
        try Data("hello\n".utf8).write(to: data.appendingPathComponent("etc/hostname"))
        try Data([0xFF, 0xD8, 0xFF, 0x01]).write(to: data.appendingPathComponent("etc/binary.bin"))

        let client = ResticClient(
            executable: try BinaryStore(directory: TestEnvironment.vendorBinDirectory())
                .verifiedURL(for: try PinnedBinaries.hostRestic),
            location: .local(repository),
            password: Secret(label: "repo", value: Self.password)
        )
        _ = try await client.initializeIfNeeded()
        try await client.run(["backup", data.path], operation: "backup")
        let snapshot = try #require(try await client.snapshots().first)

        let configuration = AgentConfiguration(
            catalogURL: base.appendingPathComponent("catalog.sqlite"),
            repositoryRoot: repositories,
            sshConfigurationDirectory: base.appendingPathComponent("ssh"),
            binaryDirectory: TestEnvironment.vendorBinDirectory()
        )
        let catalog = try Catalog.open(at: configuration.catalogURL)
        try catalog.save(
            try Server(
                id: id,
                name: "Web 01",
                endpoint: try SSHEndpoint(host: "127.0.0.1", port: 2222, user: "root"),
                authentication: .managedKey,
                privilege: .root
            )
        )
        try catalog.save(
            RepositoryRecord(id: "repo-web-01", serverId: id.value, path: repository.path)
        )

        let core = AgentCore(
            configuration: configuration,
            catalog: catalog,
            secrets: InMemorySecretStore([.repositoryPassword(id): Self.password]),
            version: "test"
        )
        return (core, id, SnapshotID(unchecked: snapshot.id))
    }

    @Test("lists a snapshot one directory at a time")
    func listsADirectory() async throws {
        let (core, id, snapshot) = try await makeCore()
        let response = await core.handle(
            .listSnapshotDirectory(serverID: id.value, snapshotID: snapshot.value, path: "/")
        )
        guard case let .snapshotNodes(nodes) = response else {
            Issue.record("expected nodes, got \(response)")
            return
        }
        #expect(!nodes.isEmpty)

        // Walk to the directory holding the files, as the browser does.
        var path = try #require(nodes.first { $0.isDirectory }).path
        var found: [SnapshotNodeReport] = []
        for _ in 0..<8 {
            let next = await core.handle(
                .listSnapshotDirectory(serverID: id.value, snapshotID: snapshot.value, path: path)
            )
            guard case let .snapshotNodes(children) = next else { break }
            if children.contains(where: { $0.name == "hostname" }) {
                found = children
                break
            }
            guard let directory = children.first(where: \.isDirectory) else { break }
            path = directory.path
        }
        #expect(found.map(\.name).sorted() == ["binary.bin", "hostname"])
        #expect(found.first { $0.name == "hostname" }?.sizeBytes == 6)
    }

    @Test("extracts a file byte for byte, where the app can read it")
    func extractsAFile() async throws {
        let (core, id, snapshot) = try await makeCore()
        let listing = await core.handle(
            .listSnapshotDirectory(serverID: id.value, snapshotID: snapshot.value, path: "/")
        )
        guard case let .snapshotNodes(roots) = listing else {
            Issue.record("expected nodes, got \(listing)")
            return
        }

        var path = try #require(roots.first { $0.isDirectory }).path
        var target: String?
        for _ in 0..<8 {
            let next = await core.handle(
                .listSnapshotDirectory(serverID: id.value, snapshotID: snapshot.value, path: path)
            )
            guard case let .snapshotNodes(children) = next else { break }
            if let binary = children.first(where: { $0.name == "binary.bin" }) {
                target = binary.path
                break
            }
            guard let directory = children.first(where: \.isDirectory) else { break }
            path = directory.path
        }

        let response = await core.handle(
            .extractFile(
                serverID: id.value,
                snapshotID: snapshot.value,
                path: try #require(target)
            )
        )
        guard case let .extractedFile(file) = response else {
            Issue.record("expected a file, got \(response)")
            return
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == Data([0xFF, 0xD8, 0xFF, 0x01]))
        // Readable by the person who asked, and nobody else on the machine.
        let attributes = try FileManager.default.attributesOfItem(atPath: file)
        #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o600)
    }

    @Test("assembles a recovery kit, with the passwords the app cannot read itself")
    func assemblesARecoveryKit() async throws {
        let (core, id, _) = try await makeCore()
        let response = await core.handle(.recoveryKit(serverID: nil))
        guard case let .kit(kit) = response else {
            Issue.record("expected a kit, got \(response)")
            return
        }
        #expect(kit.isUsable)
        #expect(kit.serverCount == 1)
        #expect(kit.markdown.contains(Self.password))
        #expect(kit.json.contains(id.value))
    }

    @Test("refuses to call a kit usable when a password is missing")
    func refusesAnIncompleteKit() async throws {
        let (core, _, _) = try await makeCore()
        await core.forgetSecretsForTesting()
        let response = await core.handle(.recoveryKit(serverID: nil))
        guard case let .kit(kit) = response else {
            Issue.record("expected a kit, got \(response)")
            return
        }
        #expect(!kit.isUsable)
        #expect(kit.missingPasswordServers == ["Web 01"])
    }

    @Test("says so when the repository is not on this Mac")
    func reportsAMissingRepository() async throws {
        let (core, id, snapshot) = try await makeCore()
        await core.breakRepositoryPathForTesting(serverID: id)
        let response = await core.handle(
            .listSnapshotDirectory(serverID: id.value, snapshotID: snapshot.value, path: "/")
        )
        guard case .failed = response else {
            Issue.record("expected a failure, got \(response)")
            return
        }
    }
}
