import Foundation
import HindsightCatalog
import HindsightCore
import HindsightEngine
import HindsightKeychain
import HindsightProtocol
import HindsightRestore
import HindsightRestic
import HindsightSSH
import HindsightSchedule

/// The agent's behaviour, independent of XPC.
///
/// Keeping the logic here rather than in the listener means it can be tested
/// by calling `handle(_:)` directly, with no connection and no entitlements.
public actor AgentCore {
    let configuration: AgentConfiguration
    let catalog: Catalog
    let secrets: any SecretStore
    let version: String
    // Built in `init` rather than in `start`, so a request that arrives before
    // the agent has started queues or fails rather than trapping on nil.
    let queue: JobQueue
    private let scheduler: Scheduler
    private var running: [String: RunningJob] = [:]
    private var observers: [UUID: @Sendable (AgentEvent) -> Void] = [:]
    /// Restores waiting to run, keyed by job. The command is held here rather
    /// than in the queue so the queue stays a plain scheduler.
    private var pendingRestores: [String: RestoreCommand] = [:]
    /// Permission to write to a server, issued one restore at a time.
    var restoreAuthorizations: [String: RestoreAuthorization] = [:]
    private var maintenanceSweep: Task<Void, Never>?
    let maintenanceSchedule = MaintenanceSchedule.default
    let notifier = Notifier()
    /// Directory listings already read out of a snapshot. A snapshot cannot
    /// change, so these are only ever dropped to bound memory.
    let listings = SnapshotListingCache()

    public init(
        configuration: AgentConfiguration,
        catalog: Catalog,
        secrets: any SecretStore = Keychain(),
        version: String
    ) {
        self.configuration = configuration
        self.catalog = catalog
        self.secrets = secrets
        self.version = version

        let runner = QueueRunnerBox()
        queue = JobQueue { job in try await runner.run(job) }
        let scheduleRunner = ScheduleRunnerBox()
        scheduler = Scheduler(power: SystemPowerSource()) { entry in
            await scheduleRunner.enqueue(entry)
        }
        runner.core = self
        scheduleRunner.core = self
    }

    public func start() async {
        reconcileInterruptedJobs()
        await reapOrphanedServers()
        await queue.observe { [weak self] event in
            Task { await self?.handle(queueEvent: event) }
        }
        await reloadSchedules()
        await scheduler.start()

        notifier.requestAuthorizationIfNeeded()
        startMaintenanceSweep()
    }

    private func reapOrphanedServers() async {
        let paths = (try? catalog.repositories().map(\.path)) ?? []
        _ = await OrphanedServers.reap(
            binaryDirectory: configuration.binaryDirectory,
            repositoryPaths: paths
        )
    }

    /// How many entries the scheduler holds. Used by tests to prove a paused
    /// server contributes none.
    func scheduledEntryCountForTesting() async -> Int {
        await scheduler.statuses().count
    }

    /// Closes off jobs that were running when the agent last stopped.
    ///
    /// Nothing is running them any more, so leaving them `running` would show a
    /// backup in progress for ever — and the interface would be right to
    /// believe the catalog.
    func reconcileInterruptedJobs(forServer serverID: ServerID? = nil, reason: String? = nil) {
        guard let active = try? catalog.activeJobs() else { return }
        for var job in active where serverID == nil || job.serverId == serverID?.value {
            let text = reason ?? "Interrupted: the agent stopped while this was running."
            job.state = reason == nil ? .failed : .cancelled
            job.finishedAt = Date()
            job.errorText = text
            try? catalog.save(job)
            try? catalog.append(text, level: .warning, to: JobID(unchecked: job.id))
        }
    }

    /// Looks for maintenance that is due, on its own slow timer.
    ///
    /// Separate from the backup scheduler because the two have nothing to say
    /// to each other: the repository lock already stops them overlapping, and a
    /// prune that takes an hour must not hold up an hourly backup's evaluation.
    private func startMaintenanceSweep() {
        guard maintenanceSweep == nil else { return }
        maintenanceSweep = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sweepMaintenance()
                try? await Task.sleep(for: .seconds(1800))
            }
        }
    }

    private func sweepMaintenance() async {
        guard let servers = try? catalog.servers() else { return }
        let onPower = SystemPowerSource().isOnACPower()

        for server in servers {
            guard let repository = try? catalog.repository(forServer: server.id) else { continue }
            let decision = MaintenancePlanner.decide(
                schedule: maintenanceSchedule,
                lastPrunedAt: repository.lastPrunedAt,
                lastCheckedAt: repository.lastCheckedAt,
                onACPower: onPower
            )
            guard let kind = decision.jobKind else { continue }

            // One maintenance job per repository at a time; the queue would
            // serialise them anyway, but queueing a backlog is pointless.
            guard await !queue.isRunning(repository: repository.path) else { continue }
            await queue.enqueue(
                QueuedJob(serverID: server.id, kind: kind, repositoryPath: repository.path)
            )
        }
    }

    public func handleWake() async {
        await scheduler.wakeUp()
    }

    public func stop() async {
        maintenanceSweep?.cancel()
        maintenanceSweep = nil
        await scheduler.stop()
        await queue.cancelAll()
    }

    public func observe(_ observer: @escaping @Sendable (AgentEvent) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    public func handle(_ request: AgentRequest) async -> AgentResponse {
        switch request {
        case .status:
            return .status(await status())

        case let .backUpNow(serverID):
            guard let id = try? ServerID(validating: serverID),
                  let server = try? catalog.server(id),
                  let repository = try? catalog.repository(forServer: id)
            else { return .failed(message: "No server with id \(serverID).") }

            let job = QueuedJob(
                serverID: server.id,
                kind: .backup,
                repositoryPath: repository.path
            )
            await queue.enqueue(job)
            return .accepted(jobID: job.id.value)

        case let .cancelJob(jobID):
            _ = jobID
            await queue.cancelAll()
            return .done

        case let .stopWork(serverID):
            return await stopWork(serverID: serverID)

        case let .removeServer(serverID, deleteBackups):
            return await removeServer(serverID: serverID, deleteBackups: deleteBackups)

        case let .setPaused(serverID, paused):
            guard let id = try? ServerID(validating: serverID),
                  (try? catalog.setPaused(paused, forServer: id)) == true
            else { return .failed(message: "No server with id \(serverID).") }
            if paused {
                // Pausing means stop backing up, not stop starting backups: a
                // run already going is what someone is usually trying to stop.
                _ = await queue.cancelAll(forServer: id)
                reconcileInterruptedJobs(forServer: id, reason: "Backups were paused.")
            }
            // Applied at once rather than at the next sweep.
            await reloadSchedules()
            return .done

        case .reloadSchedules:
            await reloadSchedules()
            return .done

        case let .runMaintenance(serverID):
            return enqueueMaintenance(serverID: serverID, kind: .forgetAndPrune)

        case let .checkIntegrity(serverID):
            return enqueueMaintenance(serverID: serverID, kind: .check(readDataSubset: nil))

        case let .previewRestore(command):
            do {
                let report = try await previewRestore(command)
                return .restorePreview(report)
            } catch {
                return .failed(message: "\(error)")
            }

        case let .authorizeRestore(serverID):
            return issueRestoreAuthorization(serverID: serverID)

        case let .runRestore(command):
            // Checked before anything else: an unauthorised restore should not
            // even reach the point of looking the server up.
            if let refusal = refusalForRestoreAuthorization(command) {
                return .failed(message: refusal)
            }
            guard let id = try? ServerID(validating: command.serverID),
                  let server = try? catalog.server(id),
                  let repository = try? catalog.repository(forServer: id)
            else { return .failed(message: "No server with id \(command.serverID).") }

            // The hostname is checked here, in the process that will do the
            // writing, rather than trusted from the caller.
            guard RestoreSafety.confirmationMatches(
                command.typedHostname,
                hostname: server.endpoint.host
            ) else {
                return .failed(message: "\(RestoreSafetyError.hostnameConfirmationRequired)")
            }

            let job = QueuedJob(
                serverID: id,
                kind: .restore,
                repositoryPath: repository.path
            )
            pendingRestores[job.id.value] = command
            await queue.enqueue(job)
            return .accepted(jobID: job.id.value)

        case let .scanHostKey(host, port):
            do {
                return .hostKey(try await scanHostKey(host: host, port: port))
            } catch {
                return .failed(message: "\(error)")
            }

        case let .trustHostKey(host, port, keyType, base64Key):
            do {
                try trustHostKey(host: host, port: port, keyType: keyType, base64Key: base64Key)
                return .done
            } catch {
                return .failed(message: "\(error)")
            }

        case let .probeServer(draft):
            do {
                return .probe(try await probeServer(draft))
            } catch {
                return .failed(message: "\(error)")
            }

        case let .addRestoreTarget(draft):
            do {
                let id = try await addRestoreTarget(draft)
                return .serverAdded(serverID: id.value)
            } catch {
                return .failed(message: "\(error)")
            }

        case let .addServer(draft):
            do {
                let id = try await addServer(draft)
                return .serverAdded(serverID: id.value)
            } catch {
                return .failed(message: "\(error)")
            }

        case let .jobHistory(serverID, limit):
            return jobHistory(serverID: serverID, limit: limit)

        case let .jobLog(jobID):
            return jobLog(jobID: jobID)

        case let .listSnapshotDirectory(serverID, snapshotID, path):
            return await listSnapshotDirectory(
                serverID: serverID,
                snapshotID: snapshotID,
                path: path
            )

        case let .searchSnapshot(serverID, snapshotID, term, limit):
            return await searchSnapshot(
                serverID: serverID,
                snapshotID: snapshotID,
                term: term,
                limit: limit
            )

        case let .extractFile(serverID, snapshotID, path):
            return await extractFile(serverID: serverID, snapshotID: snapshotID, path: path)

        case let .discoverDatabases(serverID):
            return await discoverDatabases(serverID: serverID)

        case let .replicaSeed(serverID, snapshotID, destinationDirectory):
            return await buildReplicaSeed(
                serverID: serverID,
                snapshotID: snapshotID,
                destinationDirectory: destinationDirectory
            )

        case let .recoveryKit(serverID):
            return await recoveryKit(serverID: serverID)

        case .restartAgent:
            // Replied to first, then gone: launchd brings the new one back.
            // Anything in flight is closed off here rather than at the next
            // startup, so a restart can never leave a row saying "running"
            // with nothing running it.
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                await stop()
                reconcileInterruptedJobs()
                exit(0)
            }
            return .done

        case let .serverSettings(serverID):
            do {
                return .settings(try await settings(forServer: serverID))
            } catch {
                return .failed(message: "\(error)")
            }

        case let .updateServerSettings(update):
            do {
                try await apply(update)
                await reloadSchedules()
                return .done
            } catch {
                return .failed(message: "\(error)")
            }
        }
    }

    private func enqueueMaintenance(serverID: String, kind: JobKind) -> AgentResponse {
        guard let id = try? ServerID(validating: serverID),
              let repository = try? catalog.repository(forServer: id)
        else { return .failed(message: "No server with id \(serverID).") }

        let job = QueuedJob(serverID: id, kind: kind, repositoryPath: repository.path)
        Task { await queue.enqueue(job) }
        return .accepted(jobID: job.id.value)
    }

    public func status() async -> AgentStatus {
        let statuses = await scheduler.statuses()
        let byServer = Dictionary(
            statuses.map { ($0.entry.serverID.value, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let servers = ((try? catalog.servers()) ?? []).map { server -> ServerStatus in
            let schedule = byServer[server.id.value]
            let repository = try? catalog.repository(forServer: server.id)
            let lastBackup = (try? catalog.jobs(forServer: server.id, limit: 20))?
                .first { $0.state == .succeeded && $0.kind == .backup }?
                .finishedAt
            let lastCheck = repository.flatMap { try? catalog.latestCheck(forRepository: $0.id) }

            let recent = (try? catalog.jobs(forServer: server.id, limit: 20)) ?? []
            // A machine recorded only to restore onto keeps no backups, so
            // every question about when it was last backed up has no answer
            // rather than a bad one.
            let targetOnly = repository == nil
            return ServerStatus(
                id: server.id.value,
                name: server.name,
                hostname: server.endpoint.host,
                health: targetOnly ? .unknown : Self.health(
                    lastBackupAt: lastBackup,
                    lastCheckPassed: lastCheck.map { $0.outcome == .passed }
                ),
                lastBackupAt: lastBackup,
                nextBackupAt: server.isPaused ? nil : schedule?.decision.nextFireDate,
                scheduleExplanation: targetOnly
                    ? "A machine to restore onto. Nothing here is backed up."
                    : (server.isPaused
                        ? "Paused. Scheduled backups will not run until you resume them."
                        : (schedule?.decision.explanation ?? "No schedule.")),
                lastCheckPassed: lastCheck.map { $0.outcome == .passed },
                pausedAt: server.pausedAt,
                healthReason: targetOnly ? nil : Self.healthReason(
                    lastBackupAt: lastBackup,
                    lastCheckPassed: lastCheck.map { $0.outcome == .passed },
                    recentJobs: recent
                ),
                isRestoreTargetOnly: targetOnly
            )
        }

        return AgentStatus(
            version: version,
            servers: servers,
            runningJobs: Array(running.values),
            binaryIdentity: CodeIdentity.binaryIdentity
        )
    }

    /// Why a server is in the state it is, said plainly.
    ///
    /// "Needs attention" on its own tells someone there is a problem and
    /// nothing about what it is, which leaves them opening logs to find out.
    public static func healthReason(
        lastBackupAt: Date?,
        lastCheckPassed: Bool?,
        recentJobs: [JobRecord],
        now: Date = Date()
    ) -> String? {
        if let failure = recentJobs.first(where: { $0.state == .failed }),
           failure.finishedAt ?? failure.queuedAt > (lastBackupAt ?? .distantPast) {
            let reason = failure.errorText.map(Self.firstLine) ?? "no reason was recorded"
            return "The last \(failure.kind.name) failed: \(reason)"
        }
        if lastCheckPassed == false {
            return "The last integrity check found a problem in the repository."
        }
        guard let lastBackupAt else {
            return "This server has never been backed up."
        }
        let age = now.timeIntervalSince(lastBackupAt)
        if age > 48 * 3600 {
            return "The last backup finished \(Int(age / 86400)) days ago."
        }
        return nil
    }

    static func firstLine(of text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        return line.count > 160 ? String(line.prefix(160)) + "…" : line
    }

    /// `lastCheckPassed` is optional for the same reason it is in
    /// `healthReason`: nil means no integrity check has ever run, which is not
    /// the same as one having failed. Taking a plain `Bool` meant the caller
    /// collapsed "never checked" into `false`, and a repository that had
    /// simply never been verified was shown as failing — in red, with the
    /// explanation coming from somewhere else entirely, because `healthReason`
    /// knew the difference and returned nothing.
    public static func health(lastBackupAt: Date?, lastCheckPassed: Bool?) -> ServerStatus.Health {
        guard let lastBackupAt else { return .unknown }
        if lastCheckPassed == false { return .failing }
        return Date().timeIntervalSince(lastBackupAt) > 48 * 3600 ? .stale : .healthy
    }

    func reloadSchedules() async {
        guard let servers = try? catalog.servers() else { return }
        var entries: [ScheduledEntry] = []
        for server in servers {
            // A paused server contributes no entries at all, so nothing can
            // fire for it until it is resumed.
            guard !server.isPaused else { continue }
            guard let repository = try? catalog.repository(forServer: server.id) else { continue }
            guard let records = try? catalog.schedules(forServer: server.id) else { continue }
            for record in records where record.enabled {
                guard let schedule = try? record.toSchedule() else { continue }
                let lastFired = (try? catalog.jobs(forServer: server.id, limit: 20))?
                    .first { $0.state == .succeeded && $0.kind == .backup }?
                    .finishedAt
                entries.append(
                    ScheduledEntry(
                        serverID: server.id,
                        schedule: schedule,
                        repositoryPath: repository.path,
                        lastFiredAt: lastFired
                    )
                )
            }
        }
        await scheduler.replaceEntries(entries)
    }

    func enqueueScheduled(_ entry: ScheduledEntry) async {
        await enqueueBackup(for: entry)
    }

    func runQueued(_ job: QueuedJob) async throws {
        try await run(job)
    }

    private func enqueueBackup(for entry: ScheduledEntry) async {
        await queue.enqueue(
            QueuedJob(
                serverID: entry.serverID,
                kind: .backup,
                repositoryPath: entry.repositoryPath
            )
        )
    }

    private func run(_ job: QueuedJob) async throws {
        guard let server = try catalog.server(job.serverID) else {
            throw AgentError.unknownServer(job.serverID.value)
        }
        guard let repository = try catalog.repository(forServer: job.serverID) else {
            throw AgentError.noRepository(job.serverID.value)
        }

        var record = JobRecord(id: job.id, serverId: server.id, kind: job.kind)
        record.state = .running
        record.startedAt = Date()
        try catalog.save(record)

        do {
            try await perform(job, record: &record, server: server, repository: repository)
        } catch {
            // Every way out leads here. Preparation failed outside the engine's
            // own handler once — an unreadable secret, a profile the catalog
            // could not satisfy — and the row stayed "running" for ever with
            // nothing running it, which is worse than any error message.
            if record.state == .running {
                record.state = .failed
                record.errorText = "\(error)"
                record.finishedAt = Date()
                try? catalog.save(record)
                try? catalog.append("\(error)", level: .error, to: job.id)
                notifier.backupFailed(server: server.name, reason: "\(error)")
            }
            throw error
        }
    }

    private func perform(
        _ job: QueuedJob,
        record: inout JobRecord,
        server: Server,
        repository: RepositoryRecord
    ) async throws {

        switch job.kind {
        case .forgetAndPrune, .check:
            do {
                try await runMaintenance(job, server: server, repository: repository)
                record.state = .succeeded
            } catch {
                record.state = .failed
                record.errorText = "\(error)"
                try? catalog.append("\(error)", level: .error, to: job.id)
                record.finishedAt = Date()
                try? catalog.save(record)
                notifier.integrityProblem(server: server.name, message: "\(error)")
                emit(.integrityProblem(serverID: server.id.value, message: "\(error)"))
                throw error
            }
            record.finishedAt = Date()
            try catalog.save(record)
            return

        case .restore:
            do {
                try await runRestore(job, server: server, repository: repository)
                record.state = .succeeded
            } catch {
                record.state = .failed
                record.errorText = "\(error)"
                try? catalog.append("\(error)", level: .error, to: job.id)
                record.finishedAt = Date()
                try? catalog.save(record)
                notifier.restoreFinished(server: server.name, succeeded: false)
                emit(.restoreFinished(
                    serverID: server.id.value,
                    succeeded: false,
                    safetySnapshotID: nil,
                    message: "\(error)"
                ))
                throw error
            }
            record.finishedAt = Date()
            try catalog.save(record)
            return

        case .backup, .databaseDump, .metadata, .copy:
            break
        }

        let paths = SSHPaths(
            configurationDirectory: configuration.sshConfigurationDirectory,
            preferredControlDirectory: FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Hindsight/cm")
        )
        try? catalog.append("preparing the connection", to: job.id)
        refreshSSHConfiguration()
        let client = SSHClient(paths: paths, policy: .fromEnvironment())
        let engine = BackupEngine(
            client: client,
            binaryStore: BinaryStore(directory: configuration.binaryDirectory),
            hindsightVersion: version
        )

        let identityFile: String? = switch server.authentication {
        case .managedKey:
            paths.configurationDirectory.appendingPathComponent("\(server.id.value).key").path
        case let .existingKey(path):
            path
        // A server Hindsight backs up is given a key during onboarding, so
        // this is only reached by a machine added as a restore destination.
        case .systemDefault:
            nil
        }

        // The profile's own excludes live in code so an upgrade can improve
        // them; anything a person added is layered on top.
        let extraExcludes = (try? userExcludes(forServer: server.id)) ?? []
        let scope = repository.backupScope
            .flatMap(BackupScope.init(rawValue:)) ?? .dataAndConfiguration
        let base = scope.profile
        let profile = try BackupProfile(
            includePaths: base.includePaths,
            excludePatterns: base.excludePatterns + extraExcludes,
            // A whole-root backup has to cross into whatever else is mounted
            // under it, or it is not the whole root.
            oneFileSystem: scope == .wholeRootFilesystem ? false : base.oneFileSystem,
            excludeCaches: base.excludeCaches,
            bandwidthLimitKiBPerSecond: repository.bandwidthLimitKiB
        )
        if scope == .wholeRootFilesystem {
            try? catalog.append(
                "Backing up the whole root filesystem, including the operating system.",
                to: job.id
            )
        }

        try? catalog.append("reading this server's repository password", to: job.id)
        // From the catalog, not from the configuration: the location is chosen
        // during onboarding, and writing somewhere else would leave prune,
        // check and restore working on an empty directory.
        let repositoryURL = URL(fileURLWithPath: repository.path)
        let plan = BackupPlan(
            server: server,
            destination: SSHDestination(server: server, identityFile: identityFile),
            profile: profile,
            repositoryRoot: repositoryURL.deletingLastPathComponent(),
            repositoryPassword: try await secretOrCreate(.repositoryPassword(server.id)),
            repositoryName: repositoryURL.lastPathComponent
        )

        try? catalog.append("starting the backup engine", to: job.id)
        // The outcome is the only place the counts live; without keeping it
        // the job history shows a run with no size, which is what it did. It
        // outlives the run itself because the reconciliation below needs to
        // know which dumps failed.
        var outcome: BackupOutcome?
        do {
            for try await event in engine.run(plan) {
                if case let .finished(result) = event { outcome = result }
                await apply(event, to: job, server: server)
            }
            if let outcome { record.record(outcome) }
            record.state = .succeeded
        } catch {
            record.state = .failed
            record.errorText = "\(error)"
            try? catalog.append("\(error)", level: .error, to: job.id)
            record.finishedAt = Date()
            try? catalog.save(record)
            // A failed backup is worth interrupting someone for; a successful
            // one is not.
            notifier.backupFailed(server: server.name, reason: "\(error)")
            throw error
        }

        // Reconcile the catalog with what the repository now holds, so a prune
        // somewhere else cannot leave the timeline showing snapshots that are
        // gone. A failure here is a warning on the job rather than a silence:
        // a timeline that quietly disagrees with the repository is worse than
        // one that says it could not be checked.
        do {
            let local = try await localClient(for: server, repository: repository)

            // A dump that failed may still have left a snapshot: restic writes
            // one even when it could not read its source. Removing it here,
            // before the catalog is reconciled against the repository, is what
            // keeps an empty snapshot from being filed as a backup.
            let abandoned = (outcome?.databaseDumps ?? [])
                .filter { !$0.succeeded }
                .compactMap(\.snapshotID)
            if !abandoned.isEmpty {
                do {
                    try await local.forget(snapshotIDs: abandoned)
                    try? catalog.append(
                        "removed \(abandoned.count) empty snapshot(s) left by a failed dump",
                        to: job.id
                    )
                } catch {
                    try? catalog.append(
                        "could not remove a snapshot left by a failed dump: \(error)",
                        level: .warning,
                        to: job.id
                    )
                }
            }

            let listed = try await local.snapshots()
            try catalog.record(listed.map { $0.toSnapshot() }, inRepository: repository.id)
            let removed = try catalog.retainOnly(
                resticIDs: Set(listed.map(\.id)),
                inRepository: repository.id
            )
            try? catalog.append(
                "recorded \(listed.count) snapshots, forgot \(removed) that are gone",
                to: job.id
            )
        } catch {
            try? catalog.append(
                "Could not reconcile the snapshot list with the repository: \(error)",
                level: .warning,
                to: job.id
            )
        }

        record.finishedAt = Date()
        try catalog.save(record)
        try? catalog.trimEvents(for: job.id, keeping: 2000)
    }

    /// Changes what the window is told about a job that is still going.
    private func updateRunning(
        job: QueuedJob,
        server: Server,
        _ change: (inout RunningJob) -> Void
    ) {
        var current = running[job.id.value] ?? RunningJob(
            id: job.id.value,
            serverID: server.id.value,
            kind: "backup",
            startedAt: Date()
        )
        change(&current)
        running[job.id.value] = current
        emit(.jobProgress(current))
    }

    private func apply(_ event: BackupEvent, to job: QueuedJob, server: Server) async {
        switch event {
        case let .phase(phase):
            try? catalog.append("phase: \(phase.rawValue)", to: job.id)
            updateRunning(job: job, server: server) {
                $0.phase = phase.rawValue
                // The detail belonged to the phase that just ended.
                $0.detail = nil
            }
        case let .message(text):
            try? catalog.append(text, to: job.id)
            updateRunning(job: job, server: server) { $0.detail = text }
        case let .warning(text):
            try? catalog.append(text, level: .warning, to: job.id)
        case let .progress(progress):
            var running = self.running[job.id.value] ?? RunningJob(
                id: job.id.value,
                serverID: server.id.value,
                kind: "backup",
                startedAt: Date()
            )
            running.percentDone = progress.percentDone
            running.bytesDone = progress.bytesDone
            running.totalBytes = progress.totalBytes
            self.running[job.id.value] = running
            emit(.jobProgress(running))
        case let .snapshotCreated(snapshot):
            if let repository = try? catalog.repository(forServer: server.id) {
                try? catalog.record(snapshot, inRepository: repository.id)
            }
            emit(.catalogChanged)
        case let .databaseDumped(result):
            let description = result.succeeded
                ? "Dumped \(result.target.displayName)"
                    + (result.database.map { " (\($0))" } ?? "")
                    + ": \(result.bytesAdded) bytes added."
                : "Could not dump \(result.target.displayName): \(result.failure ?? "unknown")"
            try? catalog.append(
                description,
                level: result.succeeded ? .info : .warning,
                to: job.id
            )
        case .finished:
            self.running[job.id.value] = nil
        }
    }

    private func handle(queueEvent: JobQueueEvent) {
        switch queueEvent {
        case let .started(job):
            let running = RunningJob(
                id: job.id.value,
                serverID: job.serverID.value,
                kind: "backup",
                startedAt: Date()
            )
            self.running[job.id.value] = running
            emit(.jobStarted(running))
        case let .finished(job, state, error):
            self.running[job.id.value] = nil
            emit(.jobFinished(
                id: job.id.value,
                serverID: job.serverID.value,
                succeeded: state == .succeeded,
                message: error
            ))
            emit(.catalogChanged)
        case .queued, .waiting:
            break
        }
    }

    func takePendingRestore(_ jobID: String) -> RestoreCommand? {
        defer { pendingRestores[jobID] = nil }
        return pendingRestores[jobID]
    }

    func emit(_ event: AgentEvent) {
        for observer in observers.values { observer(event) }
    }
}

/// Breaks the chicken-and-egg between the core and the queue it owns: the
/// queue's work closure needs the core, which does not exist until the queue
/// has been created.
final class QueueRunnerBox: @unchecked Sendable {
    weak var core: AgentCore?

    func run(_ job: QueuedJob) async throws {
        try await core?.runQueued(job)
    }
}

final class ScheduleRunnerBox: @unchecked Sendable {
    weak var core: AgentCore?

    func enqueue(_ entry: ScheduledEntry) async {
        await core?.enqueueScheduled(entry)
    }
}

extension AgentCore {
    /// Test seams. Used only by tests, and named so that is obvious.
    func forgetSecretsForTesting() {
        guard let store = secrets as? InMemorySecretStore,
              let servers = try? catalog.servers()
        else { return }
        for server in servers {
            try? store.delete(.repositoryPassword(server.id))
        }
    }

    func breakRepositoryPathForTesting(serverID: ServerID) {
        guard var repository = try? catalog.repository(forServer: serverID) else { return }
        repository.path = "/nowhere/\(UUID().uuidString)"
        try? catalog.save(repository)
    }
}

public enum AgentError: Error, CustomStringConvertible {
    case unknownServer(String)
    case noRepository(String)
    case noRestoreCommand(String)

    public var description: String {
        switch self {
        case let .unknownServer(id): "No server with id \(id)."
        case let .noRepository(id): "Server \(id) has no repository yet."
        case let .noRestoreCommand(id):
            "Job \(id) has no restore attached to it, so nothing was changed."
        }
    }
}

/// Keychain access, kept off the actor.
///
/// `SecItemCopyMatching` is a synchronous call into securityd, and it can block
/// for a long time — a locked keychain, an access prompt, a wedged securityd.
/// Called directly on `AgentCore` it blocks the actor, which means no status,
/// no new jobs and no answer to anything until it returns: the agent looks dead
/// while being perfectly healthy underneath. Observed, not theorised.
extension AgentCore {
    func secret(_ key: SecretKey) async throws -> Secret {
        let store = secrets
        return try await Task.detached(priority: .userInitiated) {
            try store.read(key)
        }.value
    }

    func secretOrCreate(_ key: SecretKey) async throws -> Secret {
        let store = secrets
        return try await Task.detached(priority: .userInitiated) {
            try store.readOrCreate(key)
        }.value
    }

    func optionalSecret(_ key: SecretKey) async -> Secret? {
        let store = secrets
        return await Task.detached(priority: .userInitiated) {
            try? store.read(key)
        }.value
    }

    func writeSecret(_ value: String, for key: SecretKey) async throws {
        let store = secrets
        try await Task.detached(priority: .userInitiated) {
            try store.write(value, for: key)
        }.value
    }

    func deleteSecret(_ key: SecretKey) async throws {
        let store = secrets
        try await Task.detached(priority: .userInitiated) {
            try store.delete(key)
        }.value
    }

    func hasSecret(_ key: SecretKey) async -> Bool {
        let store = secrets
        return await Task.detached(priority: .userInitiated) {
            store.contains(key)
        }.value
    }
}
