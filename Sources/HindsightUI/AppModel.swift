import Foundation
import HindsightProtocol
import Observation

/// The app's view of the agent.
///
/// The agent owns the schedule, the jobs and the catalog; the app is a client.
/// Everything here is either a cached copy of what the agent last said or a
/// request waiting to be sent, which is why nothing in the interface writes
/// state directly.
@MainActor
@Observable
public final class AppModel {
    public enum Connection: Sendable, Equatable {
        case connecting
        case connected
        /// Backups keep running without the app, so this is informational
        /// rather than an error state.
        case unavailable(reason: String)
    }

    public var connection: Connection = .connecting
    public var status: AgentStatus?
    public var activity: [ActivityEntry] = []
    public var selectedServerID: String?
    /// Which part of the selected server is on screen. In the model rather
    /// than the view so the View menu can move between them.
    public var tab: ServerTab = .overview
    public var lastError: String?
    /// Set when macOS is waiting for the person to allow the background agent
    /// in Login Items. Backups do not run until they do, so the window says so
    /// rather than looking merely disconnected.
    public var agentNeedsApproval = false
    /// The most recent restore outcome, so an open sheet can reflect it.
    public var lastRestoreEvent: AgentEvent?
    /// Job history per server, and the log of whichever job is open.
    public var jobs: [String: [JobReport]] = [:]
    public var jobLogs: [String: [JobLogLine]] = [:]
    /// Jobs that have finished during this session, and whether they worked.
    /// Onboarding watches this to know the first backup is done.
    public var finishedJobs: [String: Bool] = [:]
    /// Bumped whenever the catalog behind the window has changed.
    ///
    /// Snapshots and history are read straight out of SQLite, which cannot
    /// tell SwiftUI anything. A view that reads the catalog reads this too, so
    /// there is something to invalidate on when the agent writes to it.
    public private(set) var catalogRevision = 0
    /// Set when a job has finished and whatever is expensive to recompute —
    /// repository sizes — is worth recomputing. Read and cleared by the app.
    public private(set) var repositoryContentsChanged = 0

    /// One refresh per burst. A backup emits a catalog change per snapshot,
    /// and eleven database dumps in a minute should cost one round trip to the
    /// agent rather than eleven.
    private var refreshIsScheduled = false

    /// Replaced rather than appended by the transport, so the view can be
    /// driven in tests without any XPC at all.
    public var send: (@MainActor (AgentRequest) async -> AgentResponse?)?

    public init() {}

    public var servers: [ServerStatus] {
        (status?.servers ?? []).sorted { left, right in
            if left.health.severity != right.health.severity {
                return left.health.severity < right.health.severity
            }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    public var selectedServer: ServerStatus? {
        servers.first { $0.id == selectedServerID } ?? servers.first
    }

    public var runningJobs: [RunningJob] { status?.runningJobs ?? [] }

    public func runningJob(forServer id: String) -> RunningJob? {
        runningJobs.first { $0.serverID == id }
    }

    public var menuBarSummary: String {
        switch connection {
        case .connecting:
            return "Connecting…"
        case let .unavailable(reason):
            return reason
        case .connected:
            if let job = runningJobs.first {
                let percent = job.percentDone.map { Format.percent($0) } ?? ""
                return "Backing up \(job.serverID) \(percent)".trimmingCharacters(in: .whitespaces)
            }
            guard let status, !status.servers.isEmpty else { return "No servers yet" }
            if status.hasFailures { return "Needs attention" }
            return "Last backup \(Format.age(of: status.lastBackupAt))"
        }
    }

    public func refresh() async {
        guard let send else { return }
        guard let response = await send(.status) else {
            connection = .unavailable(reason: "The Hindsight agent is not responding.")
            return
        }
        switch response {
        case let .status(value):
            status = value
            connection = .connected
        case let .failed(message):
            lastError = message
        default:
            break
        }
    }

    public func backUpNow(serverID: String) async {
        guard let send else { return }
        switch await send(.backUpNow(serverID: serverID)) {
        case let .accepted(jobID):
            append(.init(level: .info, message: "Backup started for \(serverID).", jobID: jobID))
        case let .failed(message):
            lastError = message
            append(.init(level: .error, message: message, jobID: nil))
        default:
            break
        }
        await refresh()
    }

    /// Works out what a restore would change, without changing it.
    public func previewRestore(_ command: RestoreCommand) async -> RestorePreviewReport? {
        guard let send else { return nil }
        switch await send(.previewRestore(command)) {
        case let .restorePreview(report):
            return report
        case let .failed(message):
            lastError = message
            append(.init(level: .error, message: message, jobID: nil))
            return nil
        default:
            return nil
        }
    }

    /// Asks the agent for permission to write to a server. Short-lived and
    /// single-use; the restore carries it back.
    public func authorizeRestore(serverID: String) async -> String? {
        guard let send else { return nil }
        switch await send(.authorizeRestore(serverID: serverID)) {
        case let .restoreAuthorization(token, _):
            return token
        case let .failed(message):
            lastError = message
            return nil
        default:
            return nil
        }
    }

    public func runRestore(_ command: RestoreCommand) async -> String? {
        guard let send else { return nil }
        switch await send(.runRestore(command)) {
        case let .accepted(jobID):
            append(.init(
                level: .info,
                message: "Restore started for \(command.serverID).",
                jobID: jobID
            ))
            await refresh()
            return jobID
        case let .failed(message):
            lastError = message
            append(.init(level: .error, message: message, jobID: nil))
            return nil
        default:
            return nil
        }
    }

    @discardableResult
    public func updateSettings(_ update: ServerSettingsUpdate) async -> Bool {
        guard let send else { return false }
        switch await send(.updateServerSettings(update)) {
        case .done:
            await refresh()
            return true
        case let .failed(message):
            lastError = message
            append(.init(level: .error, message: message, jobID: nil))
            return false
        default:
            return false
        }
    }

    // MARK: Onboarding

    public func scanHostKey(host: String, port: Int) async -> HostKeyReport? {
        guard let send else { return nil }
        switch await send(.scanHostKey(host: host, port: port)) {
        case let .hostKey(report): return report
        case let .failed(message):
            lastError = message
            return nil
        default: return nil
        }
    }

    @discardableResult
    public func trustHostKey(host: String, port: Int, report: HostKeyReport) async -> Bool {
        guard let send else { return false }
        switch await send(.trustHostKey(
            host: host,
            port: port,
            keyType: report.keyType,
            base64Key: report.base64Key
        )) {
        case .done: return true
        case let .failed(message):
            lastError = message
            return false
        default: return false
        }
    }

    public func probeServer(_ draft: AddServerDraft) async -> ServerProbeReport? {
        guard let send else { return nil }
        switch await send(.probeServer(draft)) {
        case let .probe(report): return report
        case let .failed(message):
            lastError = message
            return nil
        default: return nil
        }
    }

    public func addServer(_ draft: AddServerDraft) async -> String? {
        guard let send else { return nil }
        switch await send(.addServer(draft)) {
        case let .serverAdded(serverID):
            await refresh()
            return serverID
        case let .failed(message):
            lastError = message
            return nil
        default: return nil
        }
    }

    /// Records a machine purely as somewhere to restore onto.
    public func addRestoreTarget(_ draft: AddServerDraft) async -> String? {
        guard let send else { return nil }
        switch await send(.addRestoreTarget(draft)) {
        case let .serverAdded(serverID):
            await refresh()
            return serverID
        case let .failed(message):
            lastError = message
            return nil
        default: return nil
        }
    }

    /// Builds the cloud-init seed that turns a fresh cloud image into a copy
    /// of this server.
    public func replicaSeed(
        serverID: String,
        snapshotID: String?,
        destinationDirectory: String
    ) async -> (path: String, notes: String, warnings: [String])? {
        guard let send else { return nil }
        switch await send(.replicaSeed(
            serverID: serverID,
            snapshotID: snapshotID,
            destinationDirectory: destinationDirectory
        )) {
        case let .replicaSeed(path, notes, warnings):
            note("Wrote a replica seed to \(path).")
            return (path, notes, warnings)
        case let .failed(message):
            lastError = message
            note("Could not build the replica image: \(message)", level: .error)
            return nil
        default:
            return nil
        }
    }

    /// Stops or restarts scheduled backups for one server.
    @discardableResult
    public func setPaused(_ paused: Bool, serverID: String) async -> Bool {
        guard let send else { return false }
        switch await send(.setPaused(serverID: serverID, paused: paused)) {
        case .done:
            note(
                paused
                    ? "Paused scheduled backups for \(serverID)."
                    : "Resumed scheduled backups for \(serverID)."
            )
            await refresh()
            return true
        case let .failed(message):
            lastError = message
            return false
        default:
            return false
        }
    }

    /// Stops whatever is running or queued for a server.
    @discardableResult
    public func stopWork(serverID: String) async -> Bool {
        guard let send else { return false }
        switch await send(.stopWork(serverID: serverID)) {
        case .done:
            note("Stopped the work in progress for \(serverID).")
            await refresh()
            return true
        case let .failed(message):
            lastError = message
            await refresh()
            return false
        default:
            return false
        }
    }

    /// Forgets a server, and optionally its backups with it.
    @discardableResult
    public func removeServer(serverID: String, deleteBackups: Bool) async -> Bool {
        guard let send else { return false }
        switch await send(.removeServer(serverID: serverID, deleteBackups: deleteBackups)) {
        case .done:
            note(
                deleteBackups
                    ? "Removed \(serverID) and deleted its backups."
                    : "Removed \(serverID). Its backups were kept."
            )
            if selectedServerID == serverID { selectedServerID = nil }
            await refresh()
            return true
        case let .failed(message):
            lastError = message
            return false
        default:
            return false
        }
    }

    public func runMaintenance(serverID: String) async {
        guard let send else { return }
        if case let .failed(message) = await send(.runMaintenance(serverID: serverID)) {
            lastError = message
        }
        await refresh()
    }

    public func checkIntegrity(serverID: String) async {
        guard let send else { return }
        if case let .failed(message) = await send(.checkIntegrity(serverID: serverID)) {
            lastError = message
        }
        await refresh()
    }

    /// Asks for fresh state soon, collapsing a burst into one request.
    ///
    /// Trailing edge rather than cancel-and-retry: a steady stream of events
    /// would push a cancelled refresh back for ever, where this one is
    /// guaranteed to run within the window of the first event that asked.
    public func scheduleRefresh() {
        guard !refreshIsScheduled else { return }
        refreshIsScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            self.refreshIsScheduled = false
            await self.refresh()
            self.catalogRevision &+= 1
        }
    }

    public func apply(_ event: AgentEvent) {
        switch event {
        case let .jobStarted(job):
            append(.init(level: .info, message: "Backup started for \(job.serverID).", jobID: job.id))
            // So the sidebar shows the run starting rather than waiting for
            // the first progress report.
            scheduleRefresh()
        case let .jobProgress(job):
            if let index = status?.runningJobs.firstIndex(where: { $0.id == job.id }) {
                status?.runningJobs[index] = job
            } else {
                status?.runningJobs.append(job)
            }
        case let .jobFinished(id, serverID, succeeded, message):
            status?.runningJobs.removeAll { $0.id == id }
            finishedJobs[id] = succeeded
            append(.init(
                level: succeeded ? .info : .error,
                message: succeeded
                    ? "Backup finished for \(serverID)."
                    : "Backup failed for \(serverID): \(message ?? "no reason given")",
                jobID: id
            ))
            // Health, the last backup time and the snapshot counts all change
            // when a job ends, and none of them are in this event.
            repositoryContentsChanged &+= 1
            scheduleRefresh()
        case .catalogChanged:
            // The agent saying the data behind the window moved. This used to
            // do nothing at all, which is why the window only caught up when
            // something else happened to ask.
            scheduleRefresh()
        case let .integrityProblem(serverID, message):
            append(.init(level: .error, message: "\(serverID): \(message)", jobID: nil))
            scheduleRefresh()
        case let .restoreFinished(serverID, succeeded, safetySnapshotID, message):
            lastRestoreEvent = event
            append(.init(
                level: succeeded ? .info : .error,
                message: succeeded
                    ? "Restore of \(serverID) finished. It can be undone from snapshot "
                        + "\(safetySnapshotID.map { String($0.prefix(8)) } ?? "—")."
                    : "Restore of \(serverID) failed: \(message ?? "no reason given")",
                jobID: nil
            ))
            repositoryContentsChanged &+= 1
            scheduleRefresh()
        }
    }


    /// Asks the agent to exit so launchd starts the version in this bundle.
    public func restartAgent() async {
        guard let send else { return }
        _ = await send(.restartAgent)
        note("Restarted the background agent to match this version of the app.")
    }

    // MARK: Reading a repository

    /// Lists one directory of a snapshot through the agent.
    ///
    /// Not read directly any more: reading a repository needs its password,
    /// and the agent is the only process that holds one.
    public func snapshotDirectory(
        serverID: String,
        snapshotID: String,
        path: String
    ) async -> [SnapshotNodeReport] {
        guard let send else { return [] }
        switch await send(
            .listSnapshotDirectory(serverID: serverID, snapshotID: snapshotID, path: path)
        ) {
        case let .snapshotNodes(nodes):
            return nodes
        case let .failed(message):
            note("Could not read this snapshot: \(message)", level: .error)
            return []
        default:
            return []
        }
    }

    /// Searches a whole snapshot by name.
    ///
    /// The agent reads the snapshot to answer this, so it is slow by nature
    /// and the interface shows it running rather than pretending otherwise.
    public func searchSnapshot(
        serverID: String,
        snapshotID: String,
        term: String,
        limit: Int = 500
    ) async -> (nodes: [SnapshotNodeReport], truncated: Bool, failure: String?) {
        guard let send else { return ([], false, "The agent is not connected.") }
        switch await send(
            .searchSnapshot(
                serverID: serverID,
                snapshotID: snapshotID,
                term: term,
                limit: limit
            )
        ) {
        case let .snapshotMatches(nodes, truncated):
            return (nodes, truncated, nil)
        case let .failed(message):
            note("Could not search this snapshot: \(message)", level: .error)
            return ([], false, message)
        default:
            return ([], false, "The agent did not answer.")
        }
    }

    /// Extracts one file for Quick Look, returning where the agent put it.
    public func extractFile(
        serverID: String,
        snapshotID: String,
        path: String
    ) async -> String? {
        guard let send else { return nil }
        switch await send(.extractFile(serverID: serverID, snapshotID: snapshotID, path: path)) {
        case let .extractedFile(path):
            return path
        case let .failed(message):
            note("Could not read \(path) out of this snapshot: \(message)", level: .error)
            return nil
        default:
            return nil
        }
    }

    public func recoveryKit(serverID: String?) async -> RecoveryKitReport? {
        guard let send else { return nil }
        switch await send(.recoveryKit(serverID: serverID)) {
        case let .kit(report):
            return report
        case let .failed(message):
            note(message, level: .error)
            return nil
        default:
            return nil
        }
    }

    // MARK: Settings

    public func serverSettings(serverID: String) async -> ServerSettingsReport? {
        guard let send else { return nil }
        switch await send(.serverSettings(serverID: serverID)) {
        case let .settings(report):
            return report
        case let .failed(message):
            lastError = message
            return nil
        default:
            return nil
        }
    }

    // MARK: History

    public func loadJobs(serverID: String, limit: Int = 100) async {
        guard let send else { return }
        switch await send(.jobHistory(serverID: serverID, limit: limit)) {
        case let .jobs(reports):
            jobs[serverID] = reports
        case let .failed(message):
            lastError = message
        default:
            break
        }
    }

    public func loadLog(jobID: String) async {
        guard let send else { return }
        switch await send(.jobLog(jobID: jobID)) {
        case let .jobLog(lines):
            jobLogs[jobID] = lines
        case let .failed(message):
            lastError = message
        default:
            break
        }
    }

    /// Lets the app record something the window should show — a repository it
    /// could not read, say. The activity list is the one place in the window
    /// where a message like that can be read in full and copied.
    public func note(_ message: String, level: ActivityEntry.Level = .info) {
        if level == .error { lastError = message }
        append(.init(level: level, message: message, jobID: nil))
    }

    /// Bounded, so a long-running app cannot grow without limit.
    private func append(_ entry: ActivityEntry) {
        activity.append(entry)
        if activity.count > 2000 {
            activity.removeFirst(activity.count - 2000)
        }
    }
}

public struct ActivityEntry: Sendable, Hashable, Identifiable {
    public enum Level: String, Sendable, Hashable {
        case info
        case warning
        case error

        public var symbolName: String {
            switch self {
            case .info: "info.circle"
            case .warning: "exclamationmark.triangle"
            case .error: "xmark.octagon"
            }
        }
    }

    public var id = UUID()
    public var at = Date()
    public var level: Level
    public var message: String
    public var jobID: String?

    public init(id: UUID = UUID(), at: Date = Date(), level: Level, message: String, jobID: String?) {
        self.id = id
        self.at = at
        self.level = level
        self.message = message
        self.jobID = jobID
    }

    /// What gets copied when someone needs to paste an error somewhere.
    public var copyableText: String {
        let formatter = ISO8601DateFormatter()
        return "[\(formatter.string(from: at))] \(level.rawValue.uppercased()): \(message)"
    }
}

extension AppModel {
    /// Shows what the catalog knows when the agent cannot be reached.
    ///
    /// The agent is the source of truth for *live* state — what is running,
    /// what is due next — but history is in the catalog, and an app that shows
    /// an empty window because a connection failed is less useful and more
    /// alarming than one that shows yesterday's state and says so.
    public func populateFromCatalog(_ servers: [CatalogServerSummary]) {
        let now = Date()
        status = AgentStatus(
            version: status?.version ?? "offline",
            servers: servers.map { summary in
                ServerStatus(
                    id: summary.id,
                    name: summary.name,
                    hostname: summary.hostname,
                    health: Self.health(
                        lastBackupAt: summary.lastBackupAt,
                        lastCheckPassed: summary.lastCheckPassed,
                        now: now
                    ),
                    lastBackupAt: summary.lastBackupAt,
                    nextBackupAt: nil,
                    scheduleExplanation: summary.scheduleExplanation,
                    lastCheckPassed: summary.lastCheckPassed
                )
            },
            runningJobs: []
        )
    }

    static func health(
        lastBackupAt: Date?,
        lastCheckPassed: Bool?,
        now: Date
    ) -> ServerStatus.Health {
        guard let lastBackupAt else { return .unknown }
        if lastCheckPassed == false { return .failing }
        return now.timeIntervalSince(lastBackupAt) > 48 * 3600 ? .stale : .healthy
    }
}

/// What the app can learn about a server without the agent.
public struct CatalogServerSummary: Sendable, Hashable {
    public var id: String
    public var name: String
    public var hostname: String
    public var lastBackupAt: Date?
    public var lastCheckPassed: Bool?
    public var scheduleExplanation: String

    public init(
        id: String,
        name: String,
        hostname: String,
        lastBackupAt: Date?,
        lastCheckPassed: Bool?,
        scheduleExplanation: String
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.lastBackupAt = lastBackupAt
        self.lastCheckPassed = lastCheckPassed
        self.scheduleExplanation = scheduleExplanation
    }
}
