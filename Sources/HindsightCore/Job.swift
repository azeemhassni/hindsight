public enum JobKind: Hashable, Sendable, Codable {
    case backup
    case databaseDump
    case metadata
    case forgetAndPrune
    case check(readDataSubset: String?)
    case restore
    case copy
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
