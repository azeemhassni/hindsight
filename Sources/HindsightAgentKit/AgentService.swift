import Foundation
import HindsightCatalog
import HindsightCore
import HindsightEngine
import HindsightKeychain
import HindsightProtocol
import HindsightRestic
import HindsightSSH
import HindsightSchedule

/// The agent's behaviour, independent of XPC.
///
/// Keeping the logic here rather than in the listener means it can be tested
/// by calling `handle(_:)` directly, with no connection and no entitlements.
public actor AgentCore {
    private let configuration: AgentConfiguration
    private let catalog: Catalog
    private let secrets: any SecretStore
    private let version: String
    private var queue: JobQueue!
    private var scheduler: Scheduler!
    private var running: [String: RunningJob] = [:]
    private var observers: [UUID: @Sendable (AgentEvent) -> Void] = [:]

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
    }

    public func handleWake() async {
        await scheduler?.wakeUp()
    }

    public func stop() async {
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

        case .runMaintenance, .checkIntegrity:
            // Wired up with the maintenance scheduling in a later milestone;
            // reporting it plainly beats pretending it happened.
            return .failed(message: "Not available yet.")
        }
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

    private func reloadSchedules() async {
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

        let plan = BackupPlan(
            server: server,
            destination: SSHDestination(server: server, identityFile: identityFile),
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
            _ = repository
            throw error
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

    private func emit(_ event: AgentEvent) {
        for observer in observers.values { observer(event) }
    }
}

public enum AgentError: Error, CustomStringConvertible {
    case unknownServer(String)
    case noRepository(String)

    public var description: String {
        switch self {
        case let .unknownServer(id): "No server with id \(id)."
        case let .noRepository(id): "Server \(id) has no repository yet."
        }
    }
}
