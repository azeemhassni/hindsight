import Foundation
import GRDB
import HindsightCore

/// Rows are plain `Codable` records rather than hand-written column mappings.
/// Nested values such as `Platform` and `Cadence` are stored as JSON by GRDB,
/// which keeps the schema stable while the domain types evolve.

public struct ServerRecord: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    public static let databaseTableName = "server"

    public var id: String
    public var name: String
    public var host: String
    public var port: Int
    public var user: String
    public var authentication: SSHAuthentication
    public var privilege: Privilege
    public var platform: Platform?
    public var coolifyVersion: String?
    public var createdAt: Date
    public var lastSeenAt: Date?
    public var pausedAt: Date?

    public init(server: Server, createdAt: Date = Date(), lastSeenAt: Date? = nil) {
        id = server.id.value
        name = server.name
        host = server.endpoint.host
        port = server.endpoint.port
        user = server.endpoint.user
        authentication = server.authentication
        privilege = server.privilege
        platform = server.platform
        coolifyVersion = server.coolifyVersion
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        pausedAt = server.pausedAt
    }

    public func toServer() throws -> Server {
        try Server(
            id: ServerID(validating: id),
            name: name,
            endpoint: SSHEndpoint(host: host, port: port, user: user),
            authentication: authentication,
            privilege: privilege,
            platform: platform,
            coolifyVersion: coolifyVersion,
            pausedAt: pausedAt
        )
    }
}

public struct RepositoryRecord: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    public static let databaseTableName = "repository"

    public var id: String
    public var serverId: String
    public var path: String
    public var createdAt: Date
    public var lastPrunedAt: Date?
    public var lastCheckedAt: Date?
    /// Which slice of `check --read-data-subset` runs next.
    public var checkRotationIndex: Int
    public var checkRotationDivisor: Int
    /// Upload ceiling for backups to this repository, in KiB/s. Nil means no
    /// limit, which is restic's own default.
    public var bandwidthLimitKiB: Int?

    public init(
        id: String,
        serverId: String,
        path: String,
        createdAt: Date = Date(),
        lastPrunedAt: Date? = nil,
        lastCheckedAt: Date? = nil,
        checkRotationIndex: Int = 0,
        checkRotationDivisor: Int = 4,
        bandwidthLimitKiB: Int? = nil
    ) {
        self.id = id
        self.serverId = serverId
        self.path = path
        self.createdAt = createdAt
        self.lastPrunedAt = lastPrunedAt
        self.lastCheckedAt = lastCheckedAt
        self.checkRotationIndex = checkRotationIndex
        self.checkRotationDivisor = checkRotationDivisor
        self.bandwidthLimitKiB = bandwidthLimitKiB
    }
}

public struct ScheduleRecord: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    public static let databaseTableName = "schedule"

    public var id: String
    public var serverId: String
    public var resourceUUID: String?
    public var cadence: Cadence
    public var onlyOnACPower: Bool
    public var timeZoneIdentifier: String?
    public var nextFireAt: Date?
    public var enabled: Bool

    public init(
        id: String,
        serverId: String,
        resourceUUID: String? = nil,
        schedule: Schedule,
        nextFireAt: Date? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.serverId = serverId
        self.resourceUUID = resourceUUID
        cadence = schedule.cadence
        onlyOnACPower = schedule.onlyOnACPower
        timeZoneIdentifier = schedule.timeZoneIdentifier
        self.nextFireAt = nextFireAt
        self.enabled = enabled
    }

    public func toSchedule() throws -> Schedule {
        try Schedule(
            cadence: cadence,
            onlyOnACPower: onlyOnACPower,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }
}

public struct RetentionPolicyRecord: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    public static let databaseTableName = "retentionPolicy"

    public var id: String
    public var serverId: String
    public var scope: RetentionPolicy.Scope
    public var keepWithinHours: Int
    public var keepDaily: Int
    public var keepWeekly: Int
    public var keepMonthly: Int
    public var keepYearly: Int

    public init(id: String, serverId: String, policy: RetentionPolicy) {
        self.id = id
        self.serverId = serverId
        scope = policy.scope
        keepWithinHours = policy.keepWithinHours
        keepDaily = policy.keepDaily
        keepWeekly = policy.keepWeekly
        keepMonthly = policy.keepMonthly
        keepYearly = policy.keepYearly
    }

    public func toPolicy() throws -> RetentionPolicy {
        try RetentionPolicy(
            scope: scope,
            keepWithinHours: keepWithinHours,
            keepDaily: keepDaily,
            keepWeekly: keepWeekly,
            keepMonthly: keepMonthly,
            keepYearly: keepYearly
        )
    }
}

public struct SnapshotRecord: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    public static let databaseTableName = "snapshot"

    public var resticID: String
    public var repositoryId: String
    public var time: Date
    public var hostname: String
    public var paths: [String]
    public var kind: SnapshotKind
    public var parentResticID: String?
    public var sizeBytes: Int64?
    public var dataAddedBytes: Int64?
    public var recordedAt: Date

    public init(snapshot: Snapshot, repositoryId: String, recordedAt: Date = Date()) {
        resticID = snapshot.id.value
        self.repositoryId = repositoryId
        time = snapshot.time
        hostname = snapshot.hostname
        paths = snapshot.paths
        kind = snapshot.kind
        parentResticID = snapshot.parent?.value
        sizeBytes = snapshot.sizeBytes
        dataAddedBytes = snapshot.dataAddedBytes
        self.recordedAt = recordedAt
    }

    public func toSnapshot(tags: Set<String>) -> Snapshot {
        Snapshot(
            id: SnapshotID(unchecked: resticID),
            time: time,
            hostname: hostname,
            paths: paths,
            tags: tags,
            kind: kind,
            parent: parentResticID.map { SnapshotID(unchecked: $0) },
            sizeBytes: sizeBytes,
            dataAddedBytes: dataAddedBytes
        )
    }
}

struct SnapshotTagRecord: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    static let databaseTableName = "snapshotTag"

    var snapshotResticID: String
    var tag: String
}

public struct JobRecord: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    public static let databaseTableName = "job"

    public var id: String
    public var serverId: String?
    public var kind: JobKind
    public var resourceUUID: String?
    public var state: JobState
    public var queuedAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var bytesProcessed: Int64?
    public var bytesAdded: Int64?
    public var filesNew: Int?
    public var filesChanged: Int?
    public var snapshotResticID: String?
    public var errorText: String?

    public init(
        id: JobID,
        serverId: ServerID?,
        kind: JobKind,
        resourceUUID: String? = nil,
        state: JobState = .queued,
        queuedAt: Date = Date()
    ) {
        self.id = id.value
        self.serverId = serverId?.value
        self.kind = kind
        self.resourceUUID = resourceUUID
        self.state = state
        self.queuedAt = queuedAt
    }
}

public struct JobEventRecord: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    public static let databaseTableName = "jobEvent"

    public var id: Int64?
    public var jobId: String
    public var sequence: Int
    public var at: Date
    public var level: JobEventLevel
    public var message: String

    public init(jobId: String, sequence: Int, at: Date = Date(), level: JobEventLevel, message: String) {
        self.jobId = jobId
        self.sequence = sequence
        self.at = at
        self.level = level
        self.message = message
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public enum JobEventLevel: String, Codable, Hashable, Sendable, CaseIterable {
    case debug
    case info
    case warning
    case error
}

public struct IntegrityCheckRecord: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    public static let databaseTableName = "integrityCheck"

    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case structure
        case readDataSubset
        case readAll
    }

    public enum Outcome: String, Codable, Hashable, Sendable, CaseIterable {
        case passed
        case failed
    }

    public var id: String
    public var repositoryId: String
    public var kind: Kind
    public var subsetIndex: Int?
    public var subsetDivisor: Int?
    public var startedAt: Date
    public var finishedAt: Date?
    public var outcome: Outcome?
    public var errorText: String?

    public init(
        id: String = UUID().uuidString.lowercased(),
        repositoryId: String,
        kind: Kind,
        subsetIndex: Int? = nil,
        subsetDivisor: Int? = nil,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.repositoryId = repositoryId
        self.kind = kind
        self.subsetIndex = subsetIndex
        self.subsetDivisor = subsetDivisor
        self.startedAt = startedAt
    }
}

public struct CoolifyResourceRecord: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    public static let databaseTableName = "coolifyResource"

    public var uuid: String
    public var serverId: String
    public var kind: String
    public var name: String
    public var projectName: String?
    public var environmentName: String?
    /// Which path produced this: the API, container labels, or Coolify's own
    /// database. Kept so the interface can say how complete the picture is.
    public var discoverySource: String
    public var lastSeenAt: Date

    public init(
        uuid: String,
        serverId: String,
        kind: String,
        name: String,
        projectName: String?,
        environmentName: String?,
        discoverySource: String,
        lastSeenAt: Date = Date()
    ) {
        self.uuid = uuid
        self.serverId = serverId
        self.kind = kind
        self.name = name
        self.projectName = projectName
        self.environmentName = environmentName
        self.discoverySource = discoverySource
        self.lastSeenAt = lastSeenAt
    }
}
