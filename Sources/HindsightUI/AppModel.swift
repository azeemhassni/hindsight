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
    public var lastError: String?
    /// The most recent restore outcome, so an open sheet can reflect it.
    public var lastRestoreEvent: AgentEvent?

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
        case .accepted, .done, .restorePreview, .hostKey, .probe, .serverAdded:
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
        case .done, .status, .restorePreview, .hostKey, .probe, .serverAdded, .none:
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

    public func apply(_ event: AgentEvent) {
        switch event {
        case let .jobStarted(job):
            append(.init(level: .info, message: "Backup started for \(job.serverID).", jobID: job.id))
        case let .jobProgress(job):
            if let index = status?.runningJobs.firstIndex(where: { $0.id == job.id }) {
                status?.runningJobs[index] = job
            } else {
                status?.runningJobs.append(job)
            }
        case let .jobFinished(id, serverID, succeeded, message):
            status?.runningJobs.removeAll { $0.id == id }
            append(.init(
                level: succeeded ? .info : .error,
                message: succeeded
                    ? "Backup finished for \(serverID)."
                    : "Backup failed for \(serverID): \(message ?? "no reason given")",
                jobID: id
            ))
        case .catalogChanged:
            break
        case let .integrityProblem(serverID, message):
            append(.init(level: .error, message: "\(serverID): \(message)", jobID: nil))
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
        }
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
    public var lastBackupAt: Date?
    public var lastCheckPassed: Bool?
    public var scheduleExplanation: String

    public init(
        id: String,
        name: String,
        lastBackupAt: Date?,
        lastCheckPassed: Bool?,
        scheduleExplanation: String
    ) {
        self.id = id
        self.name = name
        self.lastBackupAt = lastBackupAt
        self.lastCheckPassed = lastCheckPassed
        self.scheduleExplanation = scheduleExplanation
    }
}
