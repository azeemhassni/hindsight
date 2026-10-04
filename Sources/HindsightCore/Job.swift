public enum JobKind: Hashable, Sendable, Codable {
    case backup
    case databaseDump
    case metadata
    case forgetAndPrune
    case check(readDataSubset: String?)
    case restore
    case copy

    /// A stable short name, used in the catalog and over the protocol.
    public var name: String {
        switch self {
        case .backup: "backup"
        case .databaseDump: "database dump"
        case .metadata: "metadata"
        case .forgetAndPrune: "forget and prune"
        case .check: "integrity check"
        case .restore: "restore"
        case .copy: "second copy"
        }
    }
}

public enum JobState: String, Hashable, Sendable, Codable, CaseIterable {
    case queued
    /// Another job holds the repository lock.
    case waitingForRepository
    /// A schedule asked for this run but the Mac is on battery and the
    /// schedule is AC-only.
    case deferredOnBattery
    case running
    case succeeded
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: true
        case .queued, .waitingForRepository, .deferredOnBattery, .running: false
        }
    }
}
