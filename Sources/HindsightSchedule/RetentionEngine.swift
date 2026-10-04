import Foundation
import HindsightCore

public struct RetentionDecision: Sendable, Hashable {
    public var keep: [Snapshot]
    public var remove: [Snapshot]
    /// Why each kept snapshot survived, for the UI to explain a policy change
    /// before anything is deleted.
    public var reasons: [String: [String]]

    public init(keep: [Snapshot], remove: [Snapshot], reasons: [String: [String]]) {
        self.keep = keep
        self.remove = remove
        self.reasons = reasons
    }

    public var keepIDs: Set<String> { Set(keep.map(\.id.value)) }
    public var removeIDs: Set<String> { Set(remove.map(\.id.value)) }
}

/// Grandfather-father-son retention, modelled on restic's own policy.
///
/// This exists to answer one question the UI must answer honestly: which
/// snapshots would a policy change delete? restic can answer it too, with
/// `forget --dry-run`, and **restic is the authority** — this engine is the
/// prediction shown while editing a policy, and it is checked against restic's
/// dry run in the tests. Where the two disagree, this one is wrong.
public enum RetentionEngine {
    /// Buckets are keyed on the snapshot's local calendar, as restic does.
    public static func apply(
        _ policy: RetentionPolicy,
        to snapshots: [Snapshot],
        timeZone: TimeZone = .current
    ) -> RetentionDecision {
        let ordered = snapshots.sorted { $0.time > $1.time }
        guard !ordered.isEmpty else {
            return RetentionDecision(keep: [], remove: [], reasons: [:])
        }

        // restic measures its window from the newest snapshot that is not in
        // the future, so a snapshot with a bad clock cannot drag the window
        // forward and expire everything real.
        let now = Date()
        let latest = ordered.first { $0.time < now } ?? ordered[0]

        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone

        var reasons: [String: [String]] = [:]
        var kept: Set<String> = []

        // Verified against restic 0.19.1: the window is measured from the
        // newest snapshot, not from the current time, and the boundary is
        // exclusive. A repository that has not been backed up for a week
        // therefore still keeps its most recent snapshots, which is what
        // anyone would want, and a snapshot exactly on the boundary goes.
        if policy.keepWithinHours > 0 {
            let cutoff = latest.time.addingTimeInterval(-Double(policy.keepWithinHours) * 3600)
            for snapshot in ordered where snapshot.time > cutoff {
                kept.insert(snapshot.id.value)
                reasons[snapshot.id.value, default: []].append("within \(policy.keepWithinHours)h")
            }
        }

        var buckets: [(name: String, remaining: Int, key: (Date) -> String, last: String?)] = []
        if policy.keepDaily > 0 {
            buckets.append(("daily", policy.keepDaily, { Self.dayKey($0, calendar) }, nil))
        }
        if policy.keepWeekly > 0 {
            buckets.append(("weekly", policy.keepWeekly, { Self.weekKey($0, calendar) }, nil))
        }
        if policy.keepMonthly > 0 {
            buckets.append(("monthly", policy.keepMonthly, { Self.monthKey($0, calendar) }, nil))
        }
        if policy.keepYearly > 0 {
            buckets.append(("yearly", policy.keepYearly, { Self.yearKey($0, calendar) }, nil))
        }

        for (position, snapshot) in ordered.enumerated() {
            let isOldest = position == ordered.count - 1
            for index in buckets.indices where buckets[index].remaining > 0 {
                let key = buckets[index].key(snapshot.time)
                let isNewBucket = key != buckets[index].last
                // restic also keeps the oldest snapshot while a bucket still
                // has room, which maximises how far back the history reaches.
                // Without this rule a policy with more slots than history would
                // silently drop its earliest snapshot.
                guard isNewBucket || isOldest else { continue }
                buckets[index].last = key
                buckets[index].remaining -= 1
                kept.insert(snapshot.id.value)
                reasons[snapshot.id.value, default: []]
                    .append(isNewBucket ? buckets[index].name : "oldest \(buckets[index].name)")
            }
        }

        return RetentionDecision(
            keep: ordered.filter { kept.contains($0.id.value) },
            remove: ordered.filter { !kept.contains($0.id.value) },
            reasons: reasons
        )
    }

    /// restic groups snapshots by host and paths before applying a policy, so a
    /// per-group decision is the only one that matches what it will do.
    public static func applyPerGroup(
        _ policy: RetentionPolicy,
        to snapshots: [Snapshot],
        timeZone: TimeZone = .current
    ) -> RetentionDecision {
        var groups: [String: [Snapshot]] = [:]
        for snapshot in snapshots {
            let key = snapshot.hostname + "\u{0}" + snapshot.paths.joined(separator: "\u{1}")
            groups[key, default: []].append(snapshot)
        }

        var keep: [Snapshot] = []
        var remove: [Snapshot] = []
        var reasons: [String: [String]] = [:]
        for key in groups.keys.sorted() {
            let decision = apply(policy, to: groups[key] ?? [], timeZone: timeZone)
            keep += decision.keep
            remove += decision.remove
            reasons.merge(decision.reasons) { current, _ in current }
        }

        return RetentionDecision(
            keep: keep.sorted { $0.time > $1.time },
            remove: remove.sorted { $0.time > $1.time },
            reasons: reasons
        )
    }

    static func dayKey(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    static func weekKey(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return "\(parts.yearForWeekOfYear ?? 0)-w\(parts.weekOfYear ?? 0)"
    }

    static func monthKey(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)"
    }

    static func yearKey(_ date: Date, _ calendar: Calendar) -> String {
        "\(calendar.dateComponents([.year], from: date).year ?? 0)"
    }
}
