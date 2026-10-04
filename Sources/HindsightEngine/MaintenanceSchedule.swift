import Foundation
import HindsightCore

/// When maintenance should run for a repository.
///
/// Separate from the backup schedule because the two want different cadences:
/// backups are frequent and cheap, pruning rewrites the repository and reading
/// all the data is expensive. Keeping them apart also means a slow check never
/// delays a backup — the repository lock already serialises them.
public struct MaintenanceSchedule: Sendable, Hashable, Codable {
    /// Retention is applied once a day by default: more often wastes effort,
    /// less often lets a repository grow past what the policy intends.
    public var pruneIntervalHours: Int
    /// One slice of the read-data rotation per run.
    public var checkIntervalHours: Int
    public var onlyOnACPower: Bool

    public init(
        pruneIntervalHours: Int = 24,
        checkIntervalHours: Int = 24 * 7,
        onlyOnACPower: Bool = true
    ) {
        self.pruneIntervalHours = pruneIntervalHours
        self.checkIntervalHours = checkIntervalHours
        self.onlyOnACPower = onlyOnACPower
    }

    public static let `default` = MaintenanceSchedule()

    public func prunesAreDue(lastPrunedAt: Date?, now: Date = Date()) -> Bool {
        guard let lastPrunedAt else { return true }
        return now.timeIntervalSince(lastPrunedAt) >= Double(pruneIntervalHours) * 3600
    }

    public func checkIsDue(lastCheckedAt: Date?, now: Date = Date()) -> Bool {
        guard let lastCheckedAt else { return true }
        return now.timeIntervalSince(lastCheckedAt) >= Double(checkIntervalHours) * 3600
    }

    /// How long a full pass over the repository takes at this cadence.
    public func fullPassDescription(divisor: Int) -> String {
        let hours = checkIntervalHours * max(1, divisor)
        let days = Double(hours) / 24
        if days < 14 { return "about \(Int(days.rounded())) days" }
        return "about \(Int((days / 7).rounded())) weeks"
    }
}

public enum MaintenanceDecision: Sendable, Hashable {
    case prune
    case check
    case nothing

    public var jobKind: JobKind? {
        switch self {
        case .prune: .forgetAndPrune
        case .check: .check(readDataSubset: nil)
        case .nothing: nil
        }
    }
}

public enum MaintenancePlanner {
    /// Decides what, if anything, a repository needs now.
    ///
    /// Pruning comes first when both are due: it is followed by a structural
    /// check anyway, and running the expensive read-data pass over packs that
    /// a prune is about to rewrite would be wasted work.
    public static func decide(
        schedule: MaintenanceSchedule,
        lastPrunedAt: Date?,
        lastCheckedAt: Date?,
        now: Date = Date(),
        onACPower: Bool = true
    ) -> MaintenanceDecision {
        if schedule.onlyOnACPower, !onACPower { return .nothing }
        if schedule.prunesAreDue(lastPrunedAt: lastPrunedAt, now: now) { return .prune }
        if schedule.checkIsDue(lastCheckedAt: lastCheckedAt, now: now) { return .check }
        return .nothing
    }
}
