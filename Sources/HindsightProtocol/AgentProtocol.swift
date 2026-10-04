import Foundation

/// The Mach service the agent registers and the app connects to.
public let hindsightAgentMachServiceName = "app.hindsight.agent"

/// The XPC surface, deliberately tiny.
///
/// One method each way, carrying JSON. An `@objc` protocol can only speak
/// Objective-C types, so every richer alternative means `NSSecureCoding`
/// boilerplate for each message and a versioning problem at every change.
/// Encoding `Codable` requests keeps the contract in Swift types that are
/// checked by the compiler and testable without any XPC at all.
@objc public protocol HindsightAgentService {
    func perform(_ request: Data, reply: @escaping @Sendable (Data?) -> Void)
}

/// The app's side of the connection, for live job progress.
@objc public protocol HindsightAgentObserver {
    func receive(_ event: Data)
}

public enum AgentRequest: Codable, Sendable, Hashable {
    case status
    case backUpNow(serverID: String)
    case cancelJob(jobID: String)
    case reloadSchedules
    case runMaintenance(serverID: String)
    case checkIntegrity(serverID: String)
}

public enum AgentResponse: Codable, Sendable, Hashable {
    case status(AgentStatus)
    case accepted(jobID: String)
    case done
    case failed(message: String)
}

public struct AgentStatus: Codable, Sendable, Hashable {
    public var version: String
    public var servers: [ServerStatus]
    public var runningJobs: [RunningJob]

    public init(version: String, servers: [ServerStatus], runningJobs: [RunningJob]) {
        self.version = version
        self.servers = servers
        self.runningJobs = runningJobs
    }

    /// What the menu bar shows at a glance.
    public var lastBackupAt: Date? {
        servers.compactMap(\.lastBackupAt).max()
    }

    public var nextBackupAt: Date? {
        servers.compactMap(\.nextBackupAt).min()
    }

    public var hasFailures: Bool {
        servers.contains { $0.health == .failing }
    }
}

public struct ServerStatus: Codable, Sendable, Hashable {
    public enum Health: String, Codable, Sendable, Hashable {
        case healthy
        case stale
        case failing
        case unknown
    }

    public var id: String
    public var name: String
    public var health: Health
    public var lastBackupAt: Date?
    public var nextBackupAt: Date?
    public var scheduleExplanation: String
    public var lastCheckPassed: Bool?

    public init(
        id: String,
        name: String,
        health: Health,
        lastBackupAt: Date?,
        nextBackupAt: Date?,
        scheduleExplanation: String,
        lastCheckPassed: Bool?
    ) {
        self.id = id
        self.name = name
        self.health = health
        self.lastBackupAt = lastBackupAt
        self.nextBackupAt = nextBackupAt
        self.scheduleExplanation = scheduleExplanation
        self.lastCheckPassed = lastCheckPassed
    }
}

public struct RunningJob: Codable, Sendable, Hashable {
    public var id: String
    public var serverID: String
    public var kind: String
    public var startedAt: Date
    public var percentDone: Double?
    public var bytesDone: Int64?
    public var totalBytes: Int64?

    public init(
        id: String,
        serverID: String,
        kind: String,
        startedAt: Date,
        percentDone: Double? = nil,
        bytesDone: Int64? = nil,
        totalBytes: Int64? = nil
    ) {
        self.id = id
        self.serverID = serverID
        self.kind = kind
        self.startedAt = startedAt
        self.percentDone = percentDone
        self.bytesDone = bytesDone
        self.totalBytes = totalBytes
    }
}

public enum AgentEvent: Codable, Sendable, Hashable {
    case jobStarted(RunningJob)
    case jobProgress(RunningJob)
    case jobFinished(id: String, serverID: String, succeeded: Bool, message: String?)
    case catalogChanged
    case integrityProblem(serverID: String, message: String)
}

public enum AgentCoding {
    public static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
