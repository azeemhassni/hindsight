import Foundation
import HindsightCatalog
import HindsightCoolify
import HindsightCore
import HindsightRestic
import HindsightSSH
import HindsightTestSupport
import Testing
@testable import HindsightEngine

/// Per-resource backups against the local Coolify virtual machine.
///
/// This is the path the Coolify tab's "Back up now" takes: discover over ssh,
/// find the resource by the identity labels give it, then back up its
/// configuration directory, its volumes and — for a database — a logical dump.
@Suite(
    "Backing up one Coolify resource",
    .enabled(if: CoolifyTestEnvironment.isAvailable),
    .timeLimit(.minutes(10)),
    .serialized
)
struct CoolifyResourceVMTests {
    private actor SharedConnection {
        static let shared = SharedConnection()
        private var cached: (SSHClient, SSHDestination)?

        func get() async throws -> (SSHClient, SSHDestination) {
            if let cached { return cached }
            let made = try await CoolifyTestEnvironment.prepareTrustedClient(id: "coolify-resource")
            cached = made
            return made
        }
    }

    @Test("discovers the real resources over ssh, with the version off the image")
    func discoversOverSSH() async throws {
        let (client, destination) = try await SharedConnection.shared.get()
        let tree = try await CoolifyDiscovery(client: client).discover(on: destination)

        #expect(!tree.allResources.isEmpty)
        #expect(tree.source == .containerLabels)
        // Read from `coollabsio/coolify:<tag>`, which is the only place a
        // version appears without the API.
        #expect(tree.coolifyVersion?.hasPrefix("4.") == true)
    }

    @Test(
        "backs up a database resource, dump and volume, into its own snapshot",
        .enabled(if: CoolifyTestEnvironment.supportsReverseForwarding)
    )
    func backsUpADatabaseResource() async throws {
        let (client, destination) = try await SharedConnection.shared.get()
        let tree = try await CoolifyDiscovery(client: client).discover(on: destination)
        guard let resource = tree.allResources.first(where: { $0.kind == .database }) else {
            // Nothing to prove rather than a false pass: the VM is expected to
            // carry one database resource.
            Issue.record("the Coolify VM has no database resource to back up")
            return
        }

        let root = try TestEnvironment.temporaryRepositoryRoot()
        let password = Secret(label: "repo/coolify-resource", value: "test-" + UUID().uuidString)
        let store = BinaryStore(directory: TestEnvironment.vendorBinDirectory())
        let engine = BackupEngine(
            client: client,
            binaryStore: store,
            locks: RepositoryLockManager()
        )
        let plan = BackupPlan(
            server: try CoolifyTestEnvironment.server(id: "coolify-resource"),
            destination: destination,
            repositoryRoot: root,
            repositoryPassword: password,
            extraTags: resource.snapshotTags
        )

        let outcome = try await engine.backUp(resource: resource, plan: plan)
        #expect(outcome.failure == nil)
        #expect(outcome.succeeded)
        // The configuration directory at least; a volume as well when the
        // resource has one.
        #expect(!outcome.capturedPaths.isEmpty)

        let local = ResticClient(
            executable: try store.verifiedURL(for: try PinnedBinaries.hostRestic),
            location: .local(plan.repositoryURL),
            password: password
        )
        let tagged = try await local.snapshots(tag: .coolifyResource(resource.uuid))
        #expect(!tagged.isEmpty)

        // A database resource's volume copy is crash-consistent at best, so the
        // dump is what makes it restorable — it has to be there.
        let dump = try #require(outcome.dumps.first)
        #expect(dump.succeeded, "\(dump.failure ?? "no reason given")")
        let dumps = try await local.snapshots(tag: .databaseEngine(dump.target.engine.rawValue))
        #expect(!dumps.isEmpty)
    }
}
