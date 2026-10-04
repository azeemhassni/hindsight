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
    private var queue: JobQueue!
    private var scheduler: Scheduler!
    private var running: [String: RunningJob] = [:]
    private var observers: [UUID: @Sendable (AgentEvent) -> Void] = [:]
    /// Restores waiting to run, keyed by job. The command is held here rather
    /// than in the queue so the queue stays a plain scheduler.
    private var pendingRestores: [String: RestoreCommand] = [:]
    private var maintenanceSweep: Task<Void, Never>?
    let maintenanceSchedule = MaintenanceSchedule.default
    let notifier = Notifier()

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
    }

    public func start() async {
        queue = JobQueue { [weak self] job in
            try await self?.run(job)
        }
        await queue.observe { [weak self] event in
            Task { await self?.handle(queueEvent: event) }
        }

        scheduler = Scheduler(power: SystemPowerSource()) { [weak self] entry in
            await self?.enqueueBackup(for: entry)
        }
        await reloadSchedules()
        await scheduler.start()

        notifier.requestAuthorizationIfNeeded()
        startMaintenanceSweep()
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
        await scheduler?.wakeUp()
    }

    public func stop() async {
        maintenanceSweep?.cancel()
        maintenanceSweep = nil
        await scheduler?.stop()
        await queue?.cancelAll()
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

        case let .runRestore(command):
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

        case let .addServer(draft):
            do {
                let id = try await addServer(draft)
                return .serverAdded(serverID: id.value)
            } catch {
                return .failed(message: "\(error)")
            }

        case let .updateServerSettings(update):
            do {
                try apply(update)
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
        let statuses = await scheduler?.statuses() ?? []
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

            return ServerStatus(
                id: server.id.value,
                name: server.name,
                health: Self.health(lastBackupAt: lastBackup, lastCheckPassed: lastCheck?.outcome == .passed),
                lastBackupAt: lastBackup,
                nextBackupAt: schedule?.decision.nextFireDate,
                scheduleExplanation: schedule?.decision.explanation ?? "No schedule.",
                lastCheckPassed: lastCheck.map { $0.outcome == .passed }
            )
        }

        return AgentStatus(version: version, servers: servers, runningJobs: Array(running.values))
    }

    public static func health(lastBackupAt: Date?, lastCheckPassed: Bool) -> ServerStatus.Health {
        guard let lastBackupAt else { return .unknown }
        if !lastCheckPassed { return .failing }
        return Date().timeIntervalSince(lastBackupAt) > 48 * 3600 ? .stale : .healthy
    }

    func reloadSchedules() async {
        guard let servers = try? catalog.servers() else { return }
        var entries: [ScheduledEntry] = []
        for server in servers {
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
                        resourceUUID: record.resourceUUID,
                        schedule: schedule,
                        repositoryPath: repository.path,
                        lastFiredAt: lastFired
                    )
                )
            }
        }
        await scheduler.replaceEntries(entries)
    }

    private func enqueueBackup(for entry: ScheduledEntry) async {
        await queue.enqueue(
            QueuedJob(
                serverID: entry.serverID,
                kind: .backup,
                resourceUUID: entry.resourceUUID,
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
        let client = SSHClient(paths: paths, policy: .fromEnvironment())
        let engine = BackupEngine(
            client: client,
            binaryStore: BinaryStore(directory: configuration.binaryDirectory),
            hindsightVersion: version
        )

        let identityFile = switch server.authentication {
        case .managedKey: paths.configurationDirectory.appendingPathComponent("\(server.id.value).key").path
        case let .existingKey(path): path
        }

        // The profile's own excludes live in code so an upgrade can improve
        // them; anything a person added is layered on top.
        let extraExcludes = (try? userExcludes(forServer: server.id)) ?? []
        let profile = try BackupProfile(
            includePaths: BackupProfile.fullServer.includePaths,
            excludePatterns: BackupProfile.fullServer.excludePatterns + extraExcludes,
            oneFileSystem: BackupProfile.fullServer.oneFileSystem,
            excludeCaches: BackupProfile.fullServer.excludeCaches
        )

        let plan = BackupPlan(
            server: server,
            destination: SSHDestination(server: server, identityFile: identityFile),
            profile: profile,
            repositoryRoot: configuration.repositoryRoot,
            repositoryPassword: try secrets.readOrCreate(.repositoryPassword(server.id))
        )

        do {
            for try await event in engine.run(plan) {
                await apply(event, to: job, server: server)
            }
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
        // gone.
        if let local = try? localClient(for: server, repository: repository),
           let listed = try? await local.snapshots() {
            try? catalog.record(
                listed.map { $0.toSnapshot() },
                inRepository: repository.id
            )
            _ = try? catalog.retainOnly(
                resticIDs: Set(listed.map(\.id)),
                inRepository: repository.id
            )
        }

        record.finishedAt = Date()
        try catalog.save(record)
        try? catalog.trimEvents(for: job.id, keeping: 2000)
    }

    private func apply(_ event: BackupEvent, to job: QueuedJob, server: Server) async {
        switch event {
        case let .phase(phase):
            try? catalog.append("phase: \(phase.rawValue)", to: job.id)
        case let .message(text):
            try? catalog.append(text, to: job.id)
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
