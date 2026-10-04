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
    /// Works out exactly what a restore would change, without changing it.
    /// Takes the pre-restore safety snapshot as a side effect, because that
    /// snapshot is what the comparison is made against.
    case previewRestore(RestoreCommand)
    case runRestore(RestoreCommand)
    case updateServerSettings(ServerSettingsUpdate)
    /// Onboarding, step by step. Each is separate because each is a thing that
    /// can fail on its own and be reported on its own.
    case scanHostKey(host: String, port: Int)
    case trustHostKey(host: String, port: Int, keyType: String, base64Key: String)
    case probeServer(AddServerDraft)
    case addServer(AddServerDraft)
    /// Looks for Coolify resources on a server. Runs on the agent because it
    /// needs the ssh connection, and caches what it finds in the catalog.
    case discoverCoolify(serverID: String)
    case backUpResource(serverID: String, resourceUUID: String)
    /// The jobs and their log lines, for the activity view.
    case jobHistory(serverID: String, limit: Int)
    case jobLog(jobID: String)
    /// The settings as they stand, for the settings view to start from.
    case serverSettings(serverID: String)
    /// Reading a repository: the agent does it because it holds the password.
    case listSnapshotDirectory(serverID: String, snapshotID: String, path: String)
    case extractFile(serverID: String, snapshotID: String, path: String)
    /// Assembled by the agent, saved by the app: the passwords are the agent's
    /// to read, and where the file goes is a question for a person.
    case recoveryKit(serverID: String?)
    /// Asks the agent to exit so launchd starts the new one. Sent after an
    /// update, when the running agent is not the one in the app bundle.
    case restartAgent
}

/// One entry of a snapshot's directory listing.
public struct SnapshotNodeReport: Codable, Sendable, Hashable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var sizeBytes: Int64?
    public var modifiedAt: Date?
    public var permissions: String?

    public init(
        path: String,
        name: String,
        isDirectory: Bool,
        sizeBytes: Int64?,
        modifiedAt: Date?,
        permissions: String?
    ) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.permissions = permissions
    }
}

/// A recovery kit, rendered and ready to save.
///
/// The passwords are in here, which is the point of the document: it is what
/// makes the backups readable without this Mac. It crosses XPC only to a peer
/// already pinned to the same signing team.
public struct RecoveryKitReport: Codable, Sendable, Hashable {
    public var markdown: String
    public var json: String
    /// Servers whose password could not be read. A kit missing one would look
    /// like the job was done while leaving those backups unreadable.
    public var missingPasswordServers: [String]
    public var serverCount: Int

    public init(
        markdown: String,
        json: String,
        missingPasswordServers: [String],
        serverCount: Int
    ) {
        self.markdown = markdown
        self.json = json
        self.missingPasswordServers = missingPasswordServers
        self.serverCount = serverCount
    }

    public var isUsable: Bool { missingPasswordServers.isEmpty && serverCount > 0 }
}

/// A server's current settings. The Coolify token is reported as set or not
/// set, never returned: it lives in the Keychain and has no reason to travel.
public struct ServerSettingsReport: Codable, Sendable, Hashable {
    public var serverID: String
    /// Encoded `Cadence`, mirroring `ServerSettingsUpdate`.
    public var cadence: Data?
    public var onlyOnACPower: Bool
    public var keepWithinHours: Int
    public var keepDaily: Int
    public var keepWeekly: Int
    public var keepMonthly: Int
    public var keepYearly: Int
    public var excludePatterns: [String]
    public var bandwidthLimitKiB: Int?
    public var checkRotationDivisor: Int
    public var repositoryPath: String
    public var coolifyTokenIsSet: Bool

    public init(
        serverID: String,
        cadence: Data?,
        onlyOnACPower: Bool,
        keepWithinHours: Int,
        keepDaily: Int,
        keepWeekly: Int,
        keepMonthly: Int,
        keepYearly: Int,
        excludePatterns: [String],
        bandwidthLimitKiB: Int?,
        checkRotationDivisor: Int,
        repositoryPath: String,
        coolifyTokenIsSet: Bool
    ) {
        self.serverID = serverID
        self.cadence = cadence
        self.onlyOnACPower = onlyOnACPower
        self.keepWithinHours = keepWithinHours
        self.keepDaily = keepDaily
        self.keepWeekly = keepWeekly
        self.keepMonthly = keepMonthly
        self.keepYearly = keepYearly
        self.excludePatterns = excludePatterns
        self.bandwidthLimitKiB = bandwidthLimitKiB
        self.checkRotationDivisor = checkRotationDivisor
        self.repositoryPath = repositoryPath
        self.coolifyTokenIsSet = coolifyTokenIsSet
    }
}

/// A Coolify resource, as the protocol carries it.
public struct CoolifyResourceReport: Codable, Sendable, Hashable, Identifiable {
    public var uuid: String
    public var name: String
    /// "application", "service" or "database".
    public var kind: String
    public var projectName: String?
    public var environmentName: String?
    public var engine: String?
    public var isRunning: Bool
    public var volumeCount: Int
    public var lastBackupAt: Date?

    public var id: String { uuid }

    public init(
        uuid: String,
        name: String,
        kind: String,
        projectName: String?,
        environmentName: String?,
        engine: String?,
        isRunning: Bool,
        volumeCount: Int,
        lastBackupAt: Date?
    ) {
        self.uuid = uuid
        self.name = name
        self.kind = kind
        self.projectName = projectName
        self.environmentName = environmentName
        self.engine = engine
        self.isRunning = isRunning
        self.volumeCount = volumeCount
        self.lastBackupAt = lastBackupAt
    }
}

public struct CoolifyTreeReport: Codable, Sendable, Hashable {
    public var resources: [CoolifyResourceReport]
    /// "api", "containerLabels" or "database".
    public var source: String
    public var sourceExplanation: String
    public var coolifyVersion: String?
    /// True when the source returned nothing but could not prove the instance
    /// is empty — an API token scoped to a team with no servers, say.
    public var mayBeIncomplete: Bool

    public init(
        resources: [CoolifyResourceReport],
        source: String,
        sourceExplanation: String,
        coolifyVersion: String?,
        mayBeIncomplete: Bool
    ) {
        self.resources = resources
        self.source = source
        self.sourceExplanation = sourceExplanation
        self.coolifyVersion = coolifyVersion
        self.mayBeIncomplete = mayBeIncomplete
    }

    /// Grouped for display: project, then environment.
    public var grouped: [(project: String, environments: [(name: String, resources: [CoolifyResourceReport])])] {
        var byProject: [String: [String: [CoolifyResourceReport]]] = [:]
        for resource in resources {
            let project = resource.projectName ?? "Ungrouped"
            let environment = resource.environmentName ?? "default"
            byProject[project, default: [:]][environment, default: []].append(resource)
        }
        return byProject.keys.sorted().map { project in
            let environments = (byProject[project] ?? [:]).keys.sorted().map { environment in
                (
                    name: environment,
                    resources: (byProject[project]?[environment] ?? [])
                        .sorted { $0.name < $1.name }
                )
            }
            return (project: project, environments: environments)
        }
    }
}

/// One job in the history, with enough to judge it at a glance.
public struct JobReport: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: String
    public var state: String
    public var queuedAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var bytesProcessed: Int64?
    public var bytesAdded: Int64?
    public var filesNew: Int?
    public var filesChanged: Int?
    public var errorText: String?
    public var resourceUUID: String?

    public init(
        id: String,
        kind: String,
        state: String,
        queuedAt: Date,
        startedAt: Date?,
        finishedAt: Date?,
        bytesProcessed: Int64?,
        bytesAdded: Int64?,
        filesNew: Int?,
        filesChanged: Int?,
        errorText: String?,
        resourceUUID: String?
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.queuedAt = queuedAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.bytesProcessed = bytesProcessed
        self.bytesAdded = bytesAdded
        self.filesNew = filesNew
        self.filesChanged = filesChanged
        self.errorText = errorText
        self.resourceUUID = resourceUUID
    }

    public var succeeded: Bool { state == "succeeded" }
    public var isFinished: Bool { finishedAt != nil }
}

public struct JobLogLine: Codable, Sendable, Hashable, Identifiable {
    public var sequence: Int
    public var at: Date
    /// "debug", "info", "warning" or "error".
    public var level: String
    public var message: String

    public var id: Int { sequence }

    public init(sequence: Int, at: Date, level: String, message: String) {
        self.sequence = sequence
        self.at = at
        self.level = level
        self.message = message
    }
}

/// A server being added, before it exists in the catalog.
public struct AddServerDraft: Codable, Sendable, Hashable {
    public var name: String
    public var host: String
    public var port: Int
    public var user: String
    /// Path to an existing key, or nil to have Hindsight generate one.
    public var identityFile: String?
    public var repositoryPath: String?

    public init(
        name: String,
        host: String,
        port: Int,
        user: String,
        identityFile: String? = nil,
        repositoryPath: String? = nil
    ) {
        self.name = name
        self.host = host
        self.port = port
        self.user = user
        self.identityFile = identityFile
        self.repositoryPath = repositoryPath
    }
}

public struct HostKeyReport: Codable, Sendable, Hashable {
    public var keyType: String
    public var base64Key: String
    /// The `SHA256:…` form, which is what a person compares against the server.
    public var fingerprint: String

    public init(keyType: String, base64Key: String, fingerprint: String) {
        self.keyType = keyType
        self.base64Key = base64Key
        self.fingerprint = fingerprint
    }
}

public struct ServerProbeReport: Codable, Sendable, Hashable {
    public var prettyName: String
    public var architecture: String
    public var hasPasswordlessSudo: Bool
    public var dockerVersion: String?
    public var coolifyVersion: String?
    public var homeDirectory: String
    /// Set only when the target is a deliberately marked test machine.
    public var isTestTarget: Bool

    public init(
        prettyName: String,
        architecture: String,
        hasPasswordlessSudo: Bool,
        dockerVersion: String?,
        coolifyVersion: String?,
        homeDirectory: String,
        isTestTarget: Bool
    ) {
        self.prettyName = prettyName
        self.architecture = architecture
        self.hasPasswordlessSudo = hasPasswordlessSudo
        self.dockerVersion = dockerVersion
        self.coolifyVersion = coolifyVersion
        self.homeDirectory = homeDirectory
        self.isTestTarget = isTestTarget
    }
}

/// A restore, described in terms the protocol can carry.
///
/// Deliberately plain types: the protocol layer must not depend on the restore
/// engine, so the engine's enums are named here as strings and validated on the
/// agent's side rather than trusted.
public struct RestoreCommand: Codable, Sendable, Hashable {
    public var serverID: String
    public var snapshotID: String
    /// The paths to restore. Empty means the whole snapshot.
    public var paths: [String]
    /// nil restores in place; otherwise everything lands under this directory.
    public var targetPath: String?
    public var mode: String
    /// The server's hostname as the person typed it. The agent refuses the
    /// restore unless it matches, so a mistyped confirmation cannot proceed.
    public var typedHostname: String
    public var optedInExclusions: [String]

    public init(
        serverID: String,
        snapshotID: String,
        paths: [String],
        targetPath: String? = nil,
        mode: String,
        typedHostname: String,
        optedInExclusions: [String] = []
    ) {
        self.serverID = serverID
        self.snapshotID = snapshotID
        self.paths = paths
        self.targetPath = targetPath
        self.mode = mode
        self.typedHostname = typedHostname
        self.optedInExclusions = optedInExclusions
    }
}

public struct RestoreChange: Codable, Sendable, Hashable {
    public var path: String
    /// "added", "removed", "modified" or "metadata".
    public var kind: String

    public init(path: String, kind: String) {
        self.path = path
        self.kind = kind
    }
}

public struct RestorePreviewReport: Codable, Sendable, Hashable {
    public var changes: [RestoreChange]
    public var safetySnapshotID: String
    public var bytesAdded: Int64
    public var bytesRemoved: Int64

    public init(
        changes: [RestoreChange],
        safetySnapshotID: String,
        bytesAdded: Int64,
        bytesRemoved: Int64
    ) {
        self.changes = changes
        self.safetySnapshotID = safetySnapshotID
        self.bytesAdded = bytesAdded
        self.bytesRemoved = bytesRemoved
    }

    public var addedCount: Int { changes.count { $0.kind == "added" } }
    public var removedCount: Int { changes.count { $0.kind == "removed" } }
    public var modifiedCount: Int { changes.count { $0.kind == "modified" } }
}

public struct ServerSettingsUpdate: Codable, Sendable, Hashable {
    public var serverID: String
    /// Encoded `Cadence`, so the protocol does not restate the domain model.
    public var cadence: Data?
    public var onlyOnACPower: Bool?
    public var keepWithinHours: Int?
    public var keepDaily: Int?
    public var keepWeekly: Int?
    public var keepMonthly: Int?
    public var keepYearly: Int?
    public var excludePatterns: [String]?
    public var bandwidthLimitKiB: Int?
    public var checkRotationDivisor: Int?
    /// Stored in the Keychain by the agent, never written to the catalog.
    public var coolifyToken: String?

    public init(serverID: String) {
        self.serverID = serverID
    }
}

public enum AgentResponse: Codable, Sendable, Hashable {
    case status(AgentStatus)
    case accepted(jobID: String)
    case restorePreview(RestorePreviewReport)
    case hostKey(HostKeyReport)
    case probe(ServerProbeReport)
    case serverAdded(serverID: String)
    case coolifyTree(CoolifyTreeReport)
    case jobs([JobReport])
    case jobLog([JobLogLine])
    case settings(ServerSettingsReport)
    case snapshotNodes([SnapshotNodeReport])
    case extractedFile(path: String)
    case kit(RecoveryKitReport)
    case done
    case failed(message: String)
}

public struct AgentStatus: Codable, Sendable, Hashable {
    public var version: String
    public var servers: [ServerStatus]
    public var runningJobs: [RunningJob]
    /// Which build of the agent is actually running, so the app can notice
    /// that an update left the old one in place.
    public var binaryIdentity: String?

    public init(
        version: String,
        servers: [ServerStatus],
        runningJobs: [RunningJob],
        binaryIdentity: String? = nil
    ) {
        self.version = version
        self.servers = servers
        self.runningJobs = runningJobs
        self.binaryIdentity = binaryIdentity
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
    case restoreFinished(serverID: String, succeeded: Bool, safetySnapshotID: String?, message: String?)
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
