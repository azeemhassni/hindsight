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
        case .accepted, .done:
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
