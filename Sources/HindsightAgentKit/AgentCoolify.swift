import Foundation
import HindsightCatalog
import HindsightCoolify
import HindsightCore
import HindsightEngine
import HindsightKeychain
import HindsightProtocol
import HindsightRestic
import HindsightSSH

/// Coolify discovery and per-resource backups.
///
/// Discovery runs here rather than in the app because it needs the ssh
/// connection; what it finds is written to the catalog so the interface has
/// something to show before the first connection of a session.
extension AgentCore {
    func discoverCoolify(serverID: String) async -> AgentResponse {
        guard let id = try? ServerID(validating: serverID),
              let server = try? catalog.server(id)
        else { return .failed(message: "No server with id \(serverID).") }

        refreshSSHConfiguration()
        let paths = sshPaths()
        let client = SSHClient(paths: paths, policy: .fromEnvironment())
        let destination = SSHDestination(server: server, identityFile: identityFile(for: server, paths: paths))
        let token = await optionalSecret(.coolifyToken(id))

        do {
            let tree = try await CoolifyDiscovery(client: client)
                .discover(on: destination, apiToken: token)
            persist(tree, forServer: id)
            return .coolifyTree(report(for: tree, serverID: id))
        } catch {
            // A failed probe must not erase what the catalog already knows:
            // showing a stale tree beats showing nothing when ssh is down.
            if let cached = try? cachedCoolifyTree(forServer: id), !cached.resources.isEmpty {
                var stale = cached
                stale.mayBeIncomplete = true
                stale.sourceExplanation = "Could not reach the server, so this is what was last seen: \(error)"
                return .coolifyTree(stale)
            }
            return .failed(message: "\(error)")
        }
    }

    private func persist(_ tree: CoolifyTree, forServer id: ServerID) {
        let records = tree.allResources.map { resource in
            CoolifyResourceRecord(
                uuid: resource.uuid,
                serverId: id.value,
                kind: resource.kind.rawValue,
                name: resource.name,
                projectName: resource.projectName,
                environmentName: resource.environmentName,
                discoverySource: tree.source.rawValue
            )
        }
        try? catalog.replaceCoolifyResources(records, forServer: id)
    }

    func report(for tree: CoolifyTree, serverID: ServerID) -> CoolifyTreeReport {
        CoolifyTreeReport(
            resources: tree.allResources.map { resource in
                CoolifyResourceReport(
                    uuid: resource.uuid,
                    name: resource.name,
                    kind: resource.kind.rawValue,
                    projectName: resource.projectName,
                    environmentName: resource.environmentName,
                    engine: resource.databaseEngineName,
                    isRunning: resource.isRunning,
                    volumeCount: resource.volumes.count,
                    lastBackupAt: lastBackup(ofResource: resource.uuid)
                )
            },
            source: tree.source.rawValue,
            sourceExplanation: tree.source.explanation,
            coolifyVersion: tree.coolifyVersion,
            mayBeIncomplete: tree.mayBeIncomplete
        )
    }

    /// What the catalog last saw, for when the server cannot be reached.
    func cachedCoolifyTree(forServer id: ServerID) throws -> CoolifyTreeReport {
        let records = try catalog.coolifyResources(forServer: id)
        return CoolifyTreeReport(
            resources: records.map { record in
                CoolifyResourceReport(
                    uuid: record.uuid,
                    name: record.name,
                    kind: record.kind,
                    projectName: record.projectName,
                    environmentName: record.environmentName,
                    engine: nil,
                    // Whether it is running was true when it was seen, and says
                    // nothing now; the interface shows the age instead.
                    isRunning: false,
                    volumeCount: 0,
                    lastBackupAt: lastBackup(ofResource: record.uuid)
                )
            },
            source: records.first?.discoverySource ?? CoolifyTree.Source.containerLabels.rawValue,
            sourceExplanation: "Last seen at \(records.first?.lastSeenAt.description ?? "an unknown time").",
            coolifyVersion: nil,
            mayBeIncomplete: true
        )
    }

    private func lastBackup(ofResource uuid: String) -> Date? {
        (try? catalog.snapshots(taggedWith: .coolifyResource(uuid)))?
            .map(\.time)
            .max()
    }

    func enqueueResourceBackup(serverID: String, resourceUUID: String) async -> AgentResponse {
        guard let id = try? ServerID(validating: serverID),
              (try? catalog.server(id)) != nil,
              let repository = try? catalog.repository(forServer: id)
        else { return .failed(message: "No server with id \(serverID).") }

        let job = QueuedJob(
            serverID: id,
            kind: .backup,
            resourceUUID: resourceUUID,
            repositoryPath: repository.path
        )
        await queue.enqueue(job)
        return .accepted(jobID: job.id.value)
    }

    /// Backs up a single Coolify resource.
    ///
    /// The resource is looked up on the server again rather than read from the
    /// catalog: volumes and container names change under a redeploy, and a
    /// backup of a stale path list would silently miss data.
    func runResourceBackup(
        _ job: QueuedJob,
        resourceUUID: String,
        server: Server,
        repository: RepositoryRecord
    ) async throws {
        refreshSSHConfiguration()
        let paths = sshPaths()
        let client = SSHClient(paths: paths, policy: .fromEnvironment())
        let destination = SSHDestination(server: server, identityFile: identityFile(for: server, paths: paths))

        try catalog.append("Looking for \(resourceUUID) on \(server.name).", to: job.id)
        let tree = try await CoolifyDiscovery(client: client).discover(
            on: destination,
            apiToken: await optionalSecret(.coolifyToken(server.id))
        )
        persist(tree, forServer: server.id)

        guard let resource = tree.resource(uuid: resourceUUID) else {
            throw AgentError.unknownCoolifyResource(resourceUUID)
        }

        let engine = BackupEngine(
            client: client,
            binaryStore: BinaryStore(directory: configuration.binaryDirectory),
            hindsightVersion: version
        )
        let plan = BackupPlan(
            server: server,
            destination: destination,
            profile: try BackupProfile(
                includePaths: BackupProfile.fullServer.includePaths,
                excludePatterns: [],
                bandwidthLimitKiBPerSecond: repository.bandwidthLimitKiB
            ),
            repositoryRoot: URL(fileURLWithPath: repository.path).deletingLastPathComponent(),
            repositoryPassword: try await secretOrCreate(.repositoryPassword(server.id)),
            extraTags: resource.snapshotTags,
            repositoryName: URL(fileURLWithPath: repository.path).lastPathComponent
        )

        let outcome = try await engine.backUp(resource: resource, plan: plan) { [weak self] event in
            guard let self else { return }
            Task { await self.record(event, forJob: job.id) }
        }

        if let failure = outcome.failure {
            throw AgentError.resourceBackupFailed(resourceUUID, failure)
        }

        // Reconcile, so the new snapshot is visible in the timeline without
        // waiting for the next full backup.
        if let local = try? await localClient(for: server, repository: repository),
           let listed = try? await local.snapshots() {
            try? catalog.record(listed.map { $0.toSnapshot() }, inRepository: repository.id)
        }
    }

    private func record(_ event: BackupEvent, forJob jobID: JobID) {
        switch event {
        case let .phase(phase):
            try? catalog.append("phase: \(phase.rawValue)", to: jobID)
        case let .message(text):
            try? catalog.append(text, to: jobID)
        case let .warning(text):
            try? catalog.append(text, level: .warning, to: jobID)
        default:
            break
        }
    }
}
