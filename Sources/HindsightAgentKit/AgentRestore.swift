import Foundation
import HindsightCatalog
import HindsightCore
import HindsightEngine
import HindsightKeychain
import HindsightProtocol
import HindsightRestic
import HindsightRestore
import HindsightSSH

/// The agent's restore and maintenance work.
///
/// Both run here rather than in the app because both need the repository on
/// local disk and the repository lock: the app is a client, and two processes
/// writing one repository is how a repository gets damaged.
extension AgentCore {
    // MARK: Session plumbing

    func sshPaths() -> SSHPaths {
        SSHPaths(
            configurationDirectory: configuration.sshConfigurationDirectory,
            preferredControlDirectory: FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Hindsight/cm")
        )
    }

    func identityFile(for server: Server, paths: SSHPaths) -> String {
        switch server.authentication {
        case .managedKey:
            paths.configurationDirectory.appendingPathComponent("\(server.id.value).key").path
        case let .existingKey(path):
            path
        }
    }

    func localClient(for server: Server, repository: RepositoryRecord) async throws -> ResticClient {
        ResticClient(
            executable: try BinaryStore(directory: configuration.binaryDirectory)
                .verifiedURL(for: try PinnedBinaries.hostRestic),
            location: .local(URL(fileURLWithPath: repository.path)),
            password: try await secretOrCreate(.repositoryPassword(server.id))
        )
    }

    /// Opens a session the server can read the repository through.
    ///
    /// The same append-only server and reverse tunnel a backup uses: append-only
    /// does not restrict reads, so a restore needs no extra privilege on the
    /// repository.
    func withRestoreSession<T: Sendable>(
        server: Server,
        repository: RepositoryRecord,
        jobID: JobID,
        _ body: @Sendable @escaping (RestoreSession, SSHClient, SSHDestination, ResticClient) async throws -> T
    ) async throws -> T {
        let paths = sshPaths()
        let client = SSHClient(paths: paths, policy: .fromEnvironment())
        let destination = SSHDestination(
            server: server,
            identityFile: identityFile(for: server, paths: paths)
        )
        let store = BinaryStore(directory: configuration.binaryDirectory)
        let password = try await secretOrCreate(.repositoryPassword(server.id))

        let facts = try await client.probeFacts(on: destination)
        let binary = try PinnedBinaries.restic(for: facts.platform.architecture)
        let remoteRestic = try await RemoteBinaryInstaller(client: client, store: store)
            .ensureInstalled(binary, on: destination, facts: facts)

        let credential = RestServerCredential.generate(username: server.id.value)
        let restServer = RestServer(
            configuration: RestServer.Configuration(
                repositoryRoot: configuration.repositoryRoot,
                credential: credential,
                htpasswdFile: configuration.repositoryRoot
                    .appendingPathComponent(".hindsight-htpasswd-\(UUID().uuidString)"),
                executable: try store.verifiedURL(for: try PinnedBinaries.hostRestServer)
            )
        )
        let localPort = try await restServer.start()

        do {
            let value = try await client.withReverseForward(
                toLocalPort: localPort,
                on: destination
            ) { remotePort in
                let url = await restServer.repositoryURL(
                    remotePort: remotePort,
                    serverID: server.id
                )
                let session = RestoreSession(
                    jobID: jobID,
                    destination: destination,
                    remoteResticPath: remoteRestic,
                    repositorySecret: Secret(
                        label: "rest-repository/\(server.id.value)",
                        value: url
                    ),
                    repositoryPassword: password
                )
                let local = ResticClient(
                    executable: try store.verifiedURL(for: try PinnedBinaries.hostRestic),
                    location: .local(URL(fileURLWithPath: repository.path)),
                    password: password
                )
                return try await body(session, client, destination, local)
            }
            await restServer.stop()
            return value
        } catch {
            await restServer.stop()
            throw error
        }
    }

    func restorePlan(from command: RestoreCommand, server: Server) throws -> RestorePlan {
        let mode = RestoreMode(rawValue: command.mode) ?? .standard
        let paths = sshPaths()
        let destination = SSHDestination(
            server: server,
            identityFile: identityFile(for: server, paths: paths)
        )
        let authorizedKeys = destination.user == "root"
            ? "/root/.ssh/authorized_keys"
            : "/home/\(destination.user)/.ssh/authorized_keys"

        return RestorePlan(
            snapshotID: SnapshotID(unchecked: command.snapshotID),
            scope: command.paths.isEmpty ? .fullServer : .paths(command.paths),
            target: command.targetPath.map { RestoreTarget.alternatePath($0) } ?? .inPlace,
            mode: mode,
            optedInExclusions: Set(
                command.optedInExclusions.compactMap(RestoreExclusions.Category.init(rawValue:))
            ),
            serverHostname: server.endpoint.host,
            sshAuthorizedKeysPath: authorizedKeys
        )
    }

    // MARK: Preview

    func previewRestore(_ command: RestoreCommand) async throws -> RestorePreviewReport {
        guard let id = try? ServerID(validating: command.serverID),
              let server = try catalog.server(id),
              let repository = try catalog.repository(forServer: id)
        else { throw AgentError.unknownServer(command.serverID) }

        let plan = try restorePlan(from: command, server: server)
        let jobID = JobID.generate()
        // Hoisted so the session body captures plain values rather than the
        // actor, which would make every access an await inside the closure.
        let binaryDirectory = configuration.binaryDirectory

        return try await withRestoreSession(
            server: server,
            repository: repository,
            jobID: jobID
        ) { session, client, destination, local in
            let executor = RestoreExecutor(
                client: client,
                binaryStore: BinaryStore(directory: binaryDirectory),
                policy: .userConfirmedHostname(command.typedHostname)
            )
            let preview = try await executor.prepare(
                plan: plan,
                paths: command.paths.isEmpty ? ["/"] : command.paths,
                session: session,
                local: local
            )
            _ = destination

            return RestorePreviewReport(
                changes: preview.changes.map {
                    RestoreChange(path: $0.path, kind: $0.kind.rawValue)
                },
                safetySnapshotID: preview.safetySnapshotID.value,
                bytesAdded: preview.bytesAdded,
                bytesRemoved: preview.bytesRemoved
            )
        }
    }

    // MARK: Restore

    func runRestore(_ job: QueuedJob, server: Server, repository: RepositoryRecord) async throws {
        guard let command = takePendingRestore(job.id.value) else {
            throw AgentError.noRestoreCommand(job.id.value)
        }
        let plan = try restorePlan(from: command, server: server)
        let paths = command.paths.isEmpty ? ["/"] : command.paths
        let binaryDirectory = configuration.binaryDirectory
        let catalog = self.catalog
        let jobID = job.id

        try catalog.append("Restoring \(plan.scope.describedForConfirmation).", to: jobID)

        let safetySnapshotID = try await withRestoreSession(
            server: server,
            repository: repository,
            jobID: job.id
        ) { session, client, destination, local in
            let facts = try await client.probeFacts(on: destination)
            let executor = RestoreExecutor(
                client: client,
                binaryStore: BinaryStore(directory: binaryDirectory),
                policy: .userConfirmedHostname(command.typedHostname)
            )
            try executor.authorize(facts: facts, destination: destination)

            // The safety snapshot is taken before anything is written, so the
            // restore can be undone even if it turns out to be the wrong one.
            let preview = try await executor.prepare(
                plan: plan,
                paths: paths,
                session: session,
                local: local
            )
            try catalog.append(
                "Taken a snapshot of what this replaces: \(preview.safetySnapshotID.short). "
                    + "\(preview.changes.count) path(s) will change.",
                to: jobID
            )

            let target = command.targetPath ?? "/"
            let restored = try await executor.restoreFiles(
                plan: plan,
                paths: command.paths,
                into: target,
                session: session
            )
            try catalog.append("Restored \(restored) file(s) into \(target).", to: jobID)
            return preview.safetySnapshotID
        }

        notifier.restoreFinished(server: server.name, succeeded: true)
        emit(.restoreFinished(
            serverID: server.id.value,
            succeeded: true,
            safetySnapshotID: safetySnapshotID.value,
            message: nil
        ))
    }

    // MARK: Maintenance

    func runMaintenance(_ job: QueuedJob, server: Server, repository: RepositoryRecord) async throws {
        let local = try await localClient(for: server, repository: repository)
        let engine = MaintenanceEngine()
        var updated = repository

        switch job.kind {
        case .forgetAndPrune:
            let policy = try catalog.retentionPolicy(forServer: server.id, scope: .filesystem)
            try catalog.append("Applying retention and pruning.", to: job.id)

            let outcome = try await engine.forgetAndPrune(
                policy: policy,
                on: local,
                repositoryPath: repository.path
            )
            try catalog.append(
                "Removed \(outcome.removed.count) snapshot(s), kept \(outcome.kept.count).",
                to: job.id
            )

            // Dumps keep their own policy, so a file-oriented rule cannot
            // quietly expire a year of database history.
            let dumpPolicy = try catalog.retentionPolicy(forServer: server.id, scope: .databaseDumps)
            _ = try? await engine.forgetAndPrune(
                policy: dumpPolicy,
                on: local,
                repositoryPath: repository.path,
                tag: .databaseEngine("postgres"),
                prune: false,
                checkAfterPrune: false
            )

            updated.lastPrunedAt = Date()
            updated.lastCheckedAt = Date()
            try catalog.save(updated)
            await reconcile(repository: repository, with: local)

        case .check:
            let rotation = IntegrityRotation(
                divisor: repository.checkRotationDivisor,
                index: repository.checkRotationIndex
            )
            try catalog.append(
                "Verifying \(rotation.describeProgress()) of the repository's data.",
                to: job.id
            )

            var record = IntegrityCheckRecord(
                repositoryId: repository.id,
                kind: .readDataSubset,
                subsetIndex: rotation.index + 1,
                subsetDivisor: rotation.divisor
            )
            let outcome = try await engine.runIntegrityCheck(
                on: local,
                repositoryPath: repository.path,
                rotation: rotation
            )

            record.finishedAt = Date()
            record.outcome = outcome.isHealthy ? .passed : .failed
            if !outcome.isHealthy {
                let detail = outcome.summary.brokenPacks?.joined(separator: ", ")
                record.errorText = "\(outcome.summary.numErrors) error(s)"
                    + (detail.map { "; damaged packs: \($0)" } ?? "")
            }
            try catalog.save(record)

            updated.lastCheckedAt = Date()
            // Advance only on success: repeating a slice that failed is more
            // useful than moving past it.
            if outcome.isHealthy {
                updated.checkRotationIndex = outcome.rotation.index
            }
            try catalog.save(updated)

            guard outcome.isHealthy else {
                throw MaintenanceError.integrityCheckFailed(summary: outcome.summary)
            }
            try catalog.append(
                outcome.completedFullPass
                    ? "Every pack in this repository has now been read and verified."
                    : "This slice verified.",
                to: job.id
            )

        default:
            break
        }
    }

    /// Makes the catalog agree with the repository after snapshots are removed.
    ///
    /// Best effort: a stale timeline is a cosmetic problem, and failing a prune
    /// that already succeeded would be worse than showing a snapshot that has
    /// gone until the next backup.
    func reconcile(repository: RepositoryRecord, with local: ResticClient) async {
        guard let listed = try? await local.snapshots() else { return }
        try? catalog.record(listed.map { $0.toSnapshot() }, inRepository: repository.id)
        _ = try? catalog.retainOnly(
            resticIDs: Set(listed.map(\.id)),
            inRepository: repository.id
        )
    }
}
