import Foundation

public enum SnapshotKind: String, Hashable, Sendable, Codable, CaseIterable {
    case filesystem
    case databaseDump
    case metadata
    /// Taken immediately before a restore, of exactly what the restore would
    /// overwrite. Doubles as the restore's diff baseline and its undo path.
    case safety
}

public struct Snapshot: Identifiable, Hashable, Sendable, Codable {
    public let id: SnapshotID
    public var time: Date
    public var hostname: String
    public var paths: [String]
    public var tags: Set<String>
    public var kind: SnapshotKind
    public var parent: SnapshotID?
    public var sizeBytes: Int64?
    public var dataAddedBytes: Int64?

    public init(
        id: SnapshotID,
        time: Date,
        hostname: String,
        paths: [String],
        tags: Set<String> = [],
        kind: SnapshotKind,
        parent: SnapshotID? = nil,
        sizeBytes: Int64? = nil,
        dataAddedBytes: Int64? = nil
    ) {
        self.id = id
        self.time = time
        self.hostname = hostname
        self.paths = paths
        self.tags = tags
        self.kind = kind
        self.parent = parent
        self.sizeBytes = sizeBytes
        self.dataAddedBytes = dataAddedBytes
    }
}

/// restic tags are flat strings, so Hindsight uses a `namespace:value` convention
/// and keeps construction and parsing in one place: a tag typo would silently
/// detach a resource's entire backup history.
public enum SnapshotTag: Hashable, Sendable {
    case hindsight
    case profile(String)
    case databaseEngine(String)
    case databaseName(String)
    case restore(JobID)
    case safety

    public var rawValue: String {
        switch self {
        case .hindsight: "hindsight"
        case let .profile(name): "profile:\(name)"
        case let .databaseEngine(engine): "db:\(engine)"
        case let .databaseName(name): "dbname:\(name)"
        case let .restore(id): "restore:\(id.value)"
        case .safety: "safety"
        }
    }

    public init?(rawValue: String) {
        if rawValue == "hindsight" { self = .hindsight; return }
        if rawValue == "safety" { self = .safety; return }
        guard let separator = rawValue.firstIndex(of: ":") else { return nil }
        let namespace = String(rawValue[rawValue.startIndex..<separator])
        let value = String(rawValue[rawValue.index(after: separator)...])
        guard !value.isEmpty else { return nil }
        switch namespace {
        case "profile": self = .profile(value)
        case "db": self = .databaseEngine(value)
        case "dbname": self = .databaseName(value)
        case "restore": self = .restore(JobID(unchecked: value))
        default: return nil
        }
    }
}

extension Set<String> {
    public func contains(_ tag: SnapshotTag) -> Bool { contains(tag.rawValue) }
}
