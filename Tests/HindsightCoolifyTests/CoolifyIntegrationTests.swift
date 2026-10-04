import Foundation
import HindsightCore
import HindsightSSH
import HindsightTestSupport
import Testing
@testable import HindsightCoolify

/// Discovery against the local Coolify virtual machine.
///
/// The point of this suite is the comparison: the API and the container labels
/// must describe the same install the same way, because Hindsight has to fall
/// back from one to the other and a resource's backup history is keyed on the
/// identity they produce.
@Suite(
    "Coolify discovery against the local VM",
    .enabled(if: CoolifyTestEnvironment.isAvailable),
    .timeLimit(.minutes(5)),
    .serialized
)
struct CoolifyIntegrationTests {
    /// One connection for the whole suite.
    ///
    /// A client per test meant a host key scan and a new master each time, and
    /// that burst of connections is itself enough to make the virtual machine
    /// refuse some of them — a test failure that says nothing about Hindsight.
    private actor SharedConnection {
        static let shared = SharedConnection()
        private var cached: (SSHClient, SSHDestination)?

        func get() async throws -> (SSHClient, SSHDestination) {
            if let cached { return cached }
            let made = try await CoolifyTestEnvironment.prepareTrustedClient(id: "coolify-shared")
            cached = made
            return made
        }
    }

    static func connection() async throws -> (SSHClient, SSHDestination) {
        try await SharedConnection.shared.get()
    }

    static func labelTree(
        _ client: SSHClient,
        _ destination: SSHDestination
    ) async throws -> CoolifyTree {
        let result = try await client.run(
            RemoteCommand(
                executable: "/bin/sh",
                arguments: ["-c", CoolifyLabelDiscovery.inspectCommand],
                requiresRoot: true
            ),
            on: destination,
            timeout: .seconds(60)
        )
        let resources = try CoolifyLabelDiscovery.discover(inspectJSON: result.standardOutput)
        return CoolifyTree.assemble(resources, source: .containerLabels)
    }

    @Test("finds the real resource from container labels alone")
    func discoversFromLabels() async throws {
        let (client, destination) = try await Self.connection()

        let tree = try await Self.labelTree(client, destination)
        #expect(!tree.allResources.isEmpty, "the VM should have at least one deployed resource")

        let database = try #require(tree.allResources.first { $0.kind == .database })
        #expect(database.uuid.count > 10)
        #expect(database.databaseEngineName == "postgresql")
        #expect(database.volumes.contains { $0.isNamedVolume })
        #expect(database.configurationDirectory.hasPrefix("/data/coolify/databases/"))
    }

    @Test("does not mistake Coolify's own containers for resources")
    func ignoresCoolifyInfrastructure() async throws {
        let (client, destination) = try await Self.connection()

        let tree = try await Self.labelTree(client, destination)
        let names = Set(tree.allResources.compactMap(\.containerName))

        // Verified on v4.3.23: coolify-proxy, coolify-sentinel and
        // coolify-realtime all carry coolify.managed=true but no
        // coolify.type, so they must not appear as backup targets.
        for infrastructure in ["coolify-proxy", "coolify-sentinel", "coolify-realtime", "coolify", "coolify-db"] {
            #expect(!names.contains(infrastructure), "\(infrastructure) must not be treated as a resource")
        }
    }

    @Test("reports the server's proxy rather than assuming one")
    func detectsProxy() async throws {
        let (client, destination) = try await Self.connection()

        let result = try await client.run(
            RemoteCommand(
                executable: "/bin/sh",
                arguments: ["-c", "docker inspect coolify-proxy --format '{{.Config.Image}}' 2>/dev/null || true"],
                requiresRoot: true
            ),
            on: destination
        )
        let flavour = CoolifyProxyFlavour(proxyImage: result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(flavour == .traefik, "a default v4 install runs Traefik; got \(flavour)")
    }

    @Test("captures the files a Coolify instance cannot be rebuilt without")
    func instancePlanMatchesReality() async throws {
        let (client, destination) = try await Self.connection()

        // Every path the plan claims to back up must actually exist, or the
        // plan is describing a Coolify that does not exist.
        for path in CoolifyInstancePlan.includePaths {
            let result = try await client.run(
                RemoteCommand(
                    executable: "/bin/sh",
                    arguments: ["-c", "test -e \(ShellQuoting.quote(path)) && echo yes || echo no"],
                    requiresRoot: true
                ),
                on: destination
            )
            #expect(result.standardOutput == "yes", "\(path) does not exist on a real install")
        }

        for path in CoolifyInstancePlan.requiredFiles + [CoolifyInstancePlan.acmeFile] {
            let result = try await client.run(
                RemoteCommand(
                    executable: "/bin/sh",
                    arguments: ["-c", "test -f \(ShellQuoting.quote(path)) && echo yes || echo no"],
                    requiresRoot: true
                ),
                on: destination
            )
            #expect(result.standardOutput == "yes", "\(path) is missing")
        }
    }

    @Test("dumps Coolify's own database with the command the plan specifies")
    func coolifyDatabaseDumps() async throws {
        let (client, destination) = try await Self.connection()

        let result = try await client.run(
            RemoteCommand(
                executable: "/bin/sh",
                arguments: ["-c", CoolifyInstancePlan.databaseDumpCommand + " | wc -c"],
                requiresRoot: true
            ),
            on: destination,
            timeout: .seconds(180)
        )
        let bytes = Int(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        #expect(bytes > 10_000, "a Coolify database dump should not be nearly empty; got \(bytes) bytes")
    }

    @Test("the API and the labels describe the same install", .enabled(if: CoolifyTestEnvironment.hasToken))
    func apiAndLabelsAgree() async throws {
        let (client, destination) = try await Self.connection()

        let token = try #require(CoolifyTestEnvironment.token)
        let api = CoolifyAPIClient(
            client: client,
            destination: destination,
            token: Secret(label: "coolify-token", value: token)
        )

        #expect(try await api.version().hasPrefix("4."))

        let fromAPI = try await api.discover()
        let fromLabels = try await Self.labelTree(client, destination)

        #expect(fromAPI.source == .api)
        #expect(fromLabels.source == .containerLabels)

        // Running resources must appear in both, with the same identity: the
        // uuid is what a resource's backup history is keyed on, so the two
        // paths disagreeing would silently split one resource's history in two.
        let runningLabelUUIDs = Set(fromLabels.allResources.map(\.uuid))
        let apiUUIDs = Set(fromAPI.allResources.map(\.uuid))
        #expect(!runningLabelUUIDs.isEmpty)
        #expect(runningLabelUUIDs.isSubset(of: apiUUIDs), """
            resources found by label are missing from the API:
            \(runningLabelUUIDs.subtracting(apiUUIDs))
            """)

        for uuid in runningLabelUUIDs {
            let viaAPI = try #require(fromAPI.resource(uuid: uuid))
            let viaLabels = try #require(fromLabels.resource(uuid: uuid))
            #expect(viaAPI.kind == viaLabels.kind)
            #expect(viaAPI.name == viaLabels.name)
            #expect(viaAPI.projectName == viaLabels.projectName)
            #expect(viaAPI.environmentName == viaLabels.environmentName)

            // Volumes come from different places — Coolify's storage records
            // versus the container's mounts — and must still match.
            #expect(Set(viaAPI.volumes.map(\.name)) == Set(viaLabels.volumes.map(\.name)))
            #expect(Set(viaAPI.volumes.map(\.mountPath)) == Set(viaLabels.volumes.map(\.mountPath)))
        }
    }

    @Test("says plainly when the API is turned off", .enabled(if: CoolifyTestEnvironment.hasToken))
    func reportsDisabledAPI() async throws {
        let (client, destination) = try await Self.connection()

        // A fresh Coolify answers every endpoint with HTTP 200 and
        // success:true, which a careless client reads as an empty instance.
        // Verified on v4.3.23, and the reason the label path is the default.
        let api = CoolifyAPIClient(
            client: client,
            destination: destination,
            token: Secret(label: "coolify-token", value: "0|not-a-real-token")
        )
        do {
            _ = try await api.projects()
            Issue.record("expected the bad token to be refused")
        } catch let error as CoolifyAPIError {
            #expect(error == .unauthorized || error == .apiDisabled)
            #expect("\(error)".contains("team") || "\(error)".contains("labels"))
        }
    }
}
