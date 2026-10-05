import Foundation
import HindsightCore
import HindsightProcess
import HindsightRestic
import HindsightSSH

public enum BackupEngineError: Error, Hashable, Sendable, CustomStringConvertible {
    case noSummaryFromRestic
    case notEnoughDiskSpace(required: Int64, available: Int64, path: String)
    case snapshotNotFoundAfterBackup(id: String)
    case noIncludePathsExist
    case resticFailed(status: Int32, warnings: [String])

    public var description: String {
        switch self {
        case .noSummaryFromRestic:
            "The backup ended without restic reporting a summary, so its result is unknown."
        case let .notEnoughDiskSpace(required, available, path):
            """
            Not enough space at \(path): about \(required) bytes are needed and \
            \(available) are free. Refusing to start rather than leave a \
            half-written repository.
            """
        case let .snapshotNotFoundAfterBackup(id):
            "restic reported snapshot \(id) but it is not in the repository."
        case .noIncludePathsExist:
            "None of the paths in this backup profile exist on the server."
        case let .resticFailed(status, warnings):
            """
            restic exited with status \(status).
            \(warnings.prefix(10).joined(separator: "\n"))
            """
        }
    }
}

/// Runs a backup: local append-only server, reverse tunnel, remote restic.
public struct BackupEngine: Sendable {
    public let client: SSHClient
    public let binaryStore: BinaryStore
    public let locks: RepositoryLockManager
    public let runner: ProcessRunner
    public let hindsightVersion: String
    /// Space that must remain free after a backup's projected growth.
    public let freeSpaceMargin: Int64
    /// How often restic reports progress. Low enough not to flood the tunnel,
    /// high enough that a short backup still shows movement rather than
    /// appearing frozen.
    public let progressUpdatesPerSecond: Int

    public init(
        client: SSHClient,
        binaryStore: BinaryStore,
        locks: RepositoryLockManager = .shared,
        runner: ProcessRunner = ProcessRunner(),
        hindsightVersion: String = "0.1.0",
        freeSpaceMargin: Int64 = 2 << 30,
        progressUpdatesPerSecond: Int = 2
    ) {
        self.client = client
        self.binaryStore = binaryStore
        self.locks = locks
        self.runner = runner
        self.hindsightVersion = hindsightVersion
        self.freeSpaceMargin = freeSpaceMargin
        self.progressUpdatesPerSecond = progressUpdatesPerSecond
    }

    public func run(_ plan: BackupPlan) -> AsyncThrowingStream<BackupEvent, any Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    let outcome = try await execute(plan) { continuation.yield($0) }
                    continuation.yield(.finished(outcome))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private func execute(
        _ plan: BackupPlan,
        emit: @Sendable (BackupEvent) -> Void
    ) async throws -> BackupOutcome {
        let started = ContinuousClock.now
        var warnings: [String] = []

        emit(.phase(.preparing))
        try await locks.withLock(repositoryPath: plan.repositoryURL.path) {
            try ensureEnoughSpace(for: plan)
        }

        emit(.phase(.connecting))
        let facts = try await client.probeFacts(on: plan.destination)

        emit(.phase(.verifyingBinary))
        let binary = try PinnedBinaries.restic(for: facts.platform.architecture)
        let installer = RemoteBinaryInstaller(client: client, store: binaryStore)
        let remoteRestic = try await installer.ensureInstalled(binary, on: plan.destination, facts: facts)

        return try await locks.withLock(repositoryPath: plan.repositoryURL.path) {
            let local = ResticClient(
                executable: try binaryStore.verifiedURL(for: try PinnedBinaries.hostRestic),
                location: .local(plan.repositoryURL),
                password: plan.repositoryPassword,
                runner: runner
            )
            if try await local.initializeIfNeeded() {
                emit(.message("Created a new repository at \(plan.repositoryURL.path)."))
            }

            emit(.phase(.startingServer))
            let credential = RestServerCredential.generate(username: plan.server.id.value)
            let server = RestServer(
                configuration: RestServer.Configuration(
                    repositoryRoot: plan.repositoryRoot,
                    credential: credential,
                    htpasswdFile: plan.repositoryRoot
                        .appendingPathComponent(".hindsight-htpasswd-\(UUID().uuidString)"),
                    executable: try binaryStore.verifiedURL(for: try PinnedBinaries.hostRestServer)
                ),
                runner: runner
            )
            // Our file lock is already held, so any restic lock still in the
            // repository belongs to a run that died. Clearing it here is what
            // makes an interrupted backup recoverable on the next attempt
            // rather than after restic's lock timeout.
            try? await local.unlock(removeAll: true)

            let localPort = try await server.start()

            emit(.phase(.openingTunnel))
            // Warnings are returned from the session rather than appended to a
            // captured variable: the session body runs on its own isolation
            // domain, and sharing mutable state across it is a data race.
            let outcome: (ResticSummary, String?, [DatabaseDumpResult], [String])
            do {
                outcome = try await client.withReverseForward(
                    toLocalPort: localPort,
                    on: plan.destination
                ) { remotePort in
                    let repositoryURL = await server.repositoryURL(
                        remotePort: remotePort,
                        repositoryName: plan.repositoryName
                    )
                    // The URL carries the credential, so it travels as a secret:
                    // in argv it would be visible to every user on the server.
                    let repositorySecret = Secret(
                        label: "rest-repository/\(plan.server.id.value)",
                        value: repositoryURL
                    )

                    var sessionWarnings: [String] = []
                    var metadataSnapshotID: String?
                    if plan.includeMetadata {
                        emit(.phase(.collectingMetadata))
                        do {
                            metadataSnapshotID = try await backUpMetadata(
                                plan: plan,
                                facts: facts,
                                remoteRestic: remoteRestic,
                                repositorySecret: repositorySecret,
                                binary: binary
                            )
                        } catch {
                            // Metadata is valuable but never worth failing the
                            // backup of the data itself.
                            sessionWarnings.append("Could not record server metadata: \(error)")
                            emit(.warning("Could not record server metadata: \(error)"))
                        }
                    }

                    emit(.phase(.backingUp))
                    let backup = try await runRemoteBackup(
                        plan: plan,
                        facts: facts,
                        remoteRestic: remoteRestic,
                        repositorySecret: repositorySecret,
                        emit: emit
                    )
                    let summary = backup.summary
                    sessionWarnings += backup.warnings

                    // Recorded here, not after the dumps: the files are in the
                    // repository and restic has written their snapshot, so the
                    // timeline should show it even if a dump later hangs.
                    if let id = summary.snapshotID,
                       let written = try? await local.snapshots().first(where: { $0.id == id }) {
                        emit(.snapshotCreated(written.toSnapshot(kind: .filesystem)))
                    }

                    var dumps: [DatabaseDumpResult] = []
                    if plan.includeDatabaseDumps {
                        emit(.phase(.dumpingDatabases))
                        dumps = await dumpDatabases(
                            plan: plan,
                            facts: facts,
                            remoteRestic: remoteRestic,
                            repositorySecret: repositorySecret,
                            emit: emit
                        )
                        // A dump that failed is a warning on an otherwise good
                        // backup of the filesystem, not a silent omission.
                        for failure in dumps where !failure.succeeded {
                            let text = "Could not dump \(failure.target.displayName): "
                                + (failure.failure ?? "unknown reason")
                            sessionWarnings.append(text)
                            emit(.warning(text))
                        }
                    }
                    return (summary, metadataSnapshotID, dumps, sessionWarnings)
                }
            } catch {
                // Deterministic teardown: a cancelled backup must not leave a
                // server process behind holding the repository open.
                await server.stop()
                throw error
            }
            await server.stop()
            warnings += outcome.3

            emit(.phase(.recording))
            let snapshots = try await local.snapshots()
            let byID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })

            var filesystemSnapshot: Snapshot?
            if let id = outcome.0.snapshotID {
                guard let found = byID[id] else {
                    throw BackupEngineError.snapshotNotFoundAfterBackup(id: id)
                }
                filesystemSnapshot = found.toSnapshot(kind: .filesystem)
                emit(.snapshotCreated(filesystemSnapshot!))
            }

            var metadataSnapshot: Snapshot?
            if let id = outcome.1, let found = byID[id] {
                metadataSnapshot = found.toSnapshot(kind: .metadata)
            }

            for dump in outcome.2 {
                guard let id = dump.snapshotID?.value, let found = byID[id] else { continue }
                emit(.snapshotCreated(found.toSnapshot(kind: .databaseDump)))
            }

            emit(.phase(.finishing))
            let summary = outcome.0
            return BackupOutcome(
                filesystemSnapshot: filesystemSnapshot,
                metadataSnapshot: metadataSnapshot,
                databaseDumps: outcome.2,
                filesNew: summary.filesNew,
                filesChanged: summary.filesChanged,
                filesUnmodified: summary.filesUnmodified,
                bytesProcessed: summary.totalBytesProcessed,
                bytesAdded: summary.dataAdded,
                duration: ContinuousClock.now - started,
                warnings: warnings
            )
        }
    }

    /// Dumps every database the server has, each into its own snapshot.
    ///
    /// Failures are collected rather than thrown: a database that cannot be
    /// reached must not discard a filesystem backup that already succeeded.
    private func dumpDatabases(
        plan: BackupPlan,
        facts: RemoteFacts,
        remoteRestic: String,
        repositorySecret: Secret,
        emit: @Sendable (BackupEvent) -> Void
    ) async -> [DatabaseDumpResult] {
        let discovery = DatabaseDiscovery(client: client)
        let backup = DatabaseBackup(client: client)

        let targets: [DatabaseTarget]
        do {
            targets = try await discovery.discover(on: plan.destination, facts: facts)
        } catch {
            emit(.warning("Could not look for databases: \(error)"))
            return []
        }
        guard !targets.isEmpty else { return [] }
        emit(.message("Found \(targets.count) database(s) to dump."))

        var results: [DatabaseDumpResult] = []
        for (index, target) in targets.enumerated() {
            // Named before it starts, so a backup that stops moving says what
            // it is waiting on rather than only that it is dumping something.
            emit(.message(
                "Dumping \(target.displayName) (\(index + 1) of \(targets.count))…"
            ))
            let password = plan.databaseCredentials[target.identifier]
            let databases = (try? await backup.listDatabases(
                for: target,
                databasePassword: password,
                on: plan.destination
            )) ?? []

            // One snapshot per database, so each keeps its own history and can
            // be restored without touching the others.
            let subjects: [String?] = databases.isEmpty ? [target.databaseName] : databases
            for database in subjects {
                do {
                    let result = try await backup.backUp(
                        target,
                        database: database,
                        remoteResticPath: remoteRestic,
                        repositorySecret: repositorySecret,
                        repositoryPassword: plan.repositoryPassword,
                        databasePassword: password,
                        on: plan.destination,
                        hasBash: facts.hasBash,
                        priorityPrefix: facts.lowPriorityPrefix
                    )
                    results.append(result)
                    emit(.databaseDumped(result))
                } catch {
                    results.append(
                        DatabaseDumpResult(
                            target: target,
                            database: database,
                            snapshotID: nil,
                            bytesAdded: 0,
                            bytesProcessed: 0,
                            consistencyNote: nil,
                            failure: "\(error)"
                        )
                    )
                }
            }
        }
        return results
    }

    private func runRemoteBackup(
        plan: BackupPlan,
        facts: RemoteFacts,
        remoteRestic: String,
        repositorySecret: Secret,
        emit: @Sendable (BackupEvent) -> Void
    ) async throws -> (summary: ResticSummary, warnings: [String]) {
        let includeFile = "\(facts.homeDirectory)/.cache/hindsight/include-\(plan.server.id.value).txt"
        let excludeFile = "\(facts.homeDirectory)/.cache/hindsight/exclude-\(plan.server.id.value).txt"

        // The default profile names paths that many servers do not have, and
        // restic treats a missing path as an error. Ask the server which of
        // them exist rather than failing a backup over an absent /data.
        let present = try await existingPaths(plan.profile.includePaths, on: plan.destination)
        let missing = plan.profile.includePaths.filter { !present.contains($0) }
        if !missing.isEmpty {
            emit(.message("Not present on this server, skipped: \(missing.joined(separator: ", "))"))
        }
        guard !present.isEmpty else { throw BackupEngineError.noIncludePathsExist }
        let includeContents = present.joined(separator: "\n") + "\n"

        try await client.upload(Data(includeContents.utf8), to: includeFile, on: plan.destination)
        try await client.upload(Data(plan.excludeFileContents.utf8), to: excludeFile, on: plan.destination)

        let command = RemoteCommand(
            executable: remoteRestic,
            arguments: plan.resticArguments(
                binaryPath: remoteRestic,
                includeFile: includeFile,
                excludeFile: excludeFile
            ),
            environment: ["RESTIC_PROGRESS_FPS": String(progressUpdatesPerSecond)],
            secretEnvironment: ["RESTIC_REPOSITORY": repositorySecret, "RESTIC_PASSWORD": plan.repositoryPassword],
            requiresRoot: true,
            priorityPrefix: facts.lowPriorityPrefix
        )

        var summary: ResticSummary?
        var collectedWarnings: [String] = []
        var exit: ProcessExit?

        // `-tt` forces a pseudo-terminal: restic only emits progress when its
        // output is a terminal, verified against restic 0.19.1. Without it the
        // UI would have nothing to show until the run ended.
        for try await event in try client.stream(command, on: plan.destination, extraSSHArguments: ["-tt"]) {
            if case let .exited(status) = event {
                exit = status
                continue
            }
            guard case let .line(_, line) = event else { continue }
            guard let message = ResticMessage.decode(line: line) else { continue }
            switch message {
            case let .status(status):
                emit(.progress(BackupProgress(status)))
            case let .error(error):
                let text = [error.item, error.error.message].compactMap { $0 }.joined(separator: ": ")
                collectedWarnings.append(text)
                emit(.warning(text))
            case let .summary(value):
                summary = value
            case .verboseStatus, .unknown:
                continue
            }
        }

        guard let summary else { throw BackupEngineError.noSummaryFromRestic }
        var warnings = collectedWarnings

        // restic exits 3 when it finished but could not read everything. That
        // is a warning, not a success: the snapshot is real but incomplete, and
        // saying otherwise would be the worst kind of lie for a backup tool.
        if let exit, exit.terminationStatus != 0 {
            guard exit.terminationStatus == 3 else {
                throw BackupEngineError.resticFailed(
                    status: exit.terminationStatus,
                    warnings: collectedWarnings
                )
            }
            warnings.append("Some files could not be read; the snapshot is incomplete.")
        }

        return (summary, warnings)
    }

    private func existingPaths(
        _ paths: [String],
        on destination: SSHDestination
    ) async throws -> [String] {
        let script = paths
            .map { "[ -e \(ShellQuoting.quote($0)) ] && printf '%s\\n' \(ShellQuoting.quote($0))" }
            .joined(separator: "\n")
        let result = try await client.run(
            RemoteCommand(executable: "/bin/sh", arguments: ["-c", script + "\nexit 0"], requiresRoot: true),
            on: destination
        )
        let found = Set(result.standardOutputLines.filter { !$0.isEmpty })
        return paths.filter(found.contains)
    }

    private func backUpMetadata(
        plan: BackupPlan,
        facts: RemoteFacts,
        remoteRestic: String,
        repositorySecret: Secret,
        binary: PinnedBinary
    ) async throws -> String? {
        let manifest = try SnapshotManifest(
            hindsightVersion: hindsightVersion,
            resticVersion: binary.version,
            profileName: "full",
            includePaths: plan.profile.includePaths,
            excludePatterns: plan.profile.excludePatterns,
            serverName: plan.server.name,
            serverID: plan.server.id.value
        ).jsonString()

        try await client.run(
            RemoteCommand(
                executable: "/bin/sh",
                arguments: ["-c", MetadataCollector.script],
                requiresRoot: true
            ),
            on: plan.destination,
            timeout: .seconds(120)
        )
        try await client.upload(
            Data(manifest.utf8),
            to: MetadataCollector.remoteDirectory + "/hindsight-manifest.json",
            on: plan.destination,
            requiresRoot: true
        )

        let tags: [SnapshotTag] = [.hindsight, .profile("metadata")] + plan.extraTags
        var arguments = ["backup", "--json", MetadataCollector.remoteDirectory]
        for tag in tags { arguments += ["--tag", tag.rawValue] }

        let result = try await client.run(
            RemoteCommand(
                executable: remoteRestic,
                arguments: arguments,
                secretEnvironment: [
                    "RESTIC_REPOSITORY": repositorySecret,
                    "RESTIC_PASSWORD": plan.repositoryPassword,
                ],
                requiresRoot: true
            ),
            on: plan.destination,
            timeout: .seconds(300)
        )

        defer {
            Task {
                try? await client.run(
                    RemoteCommand(
                        executable: "/bin/sh",
                        arguments: ["-c", MetadataCollector.cleanupScript],
                        requiresRoot: true
                    ),
                    on: plan.destination
                )
            }
        }

        for line in result.standardOutputLines.reversed() {
            if case let .summary(summary) = ResticMessage.decode(line: line) {
                return summary.snapshotID
            }
        }
        return nil
    }

    /// Refuses to start rather than fill the volume mid-write.
    private func ensureEnoughSpace(for plan: BackupPlan) throws {
        let values = try? plan.repositoryRoot.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }
        guard available > freeSpaceMargin else {
            throw BackupEngineError.notEnoughDiskSpace(
                required: freeSpaceMargin,
                available: available,
                path: plan.repositoryRoot.path
            )
        }
    }
}
