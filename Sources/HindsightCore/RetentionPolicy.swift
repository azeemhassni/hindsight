public struct RetentionPolicy: Hashable, Sendable, Codable {
    public enum Scope: String, Hashable, Sendable, Codable, CaseIterable {
        case filesystem
        case databaseDumps
    }

    public var scope: Scope
    public var keepWithinHours: Int
    public var keepDaily: Int
    public var keepWeekly: Int
    public var keepMonthly: Int
    public var keepYearly: Int

    public init(
        scope: Scope,
        keepWithinHours: Int,
        keepDaily: Int,
        keepWeekly: Int,
        keepMonthly: Int,
        keepYearly: Int
    ) throws {
        let rules = [
            ("keep-within-hours", keepWithinHours),
            ("keep-daily", keepDaily),
            ("keep-weekly", keepWeekly),
            ("keep-monthly", keepMonthly),
            ("keep-yearly", keepYearly),
        ]
        for (name, value) in rules where value < 0 {
            throw ValidationError.negativeRetentionCount(name, value)
        }
        // A policy where every rule is zero would expire the entire repository
        // on the next prune. Refuse it rather than let a UI slip delete history.
        guard rules.contains(where: { $0.1 > 0 }) else { throw ValidationError.retentionKeepsNothing }

        self.scope = scope
        self.keepWithinHours = keepWithinHours
        self.keepDaily = keepDaily
        self.keepWeekly = keepWeekly
        self.keepMonthly = keepMonthly
        self.keepYearly = keepYearly
    }

    public static let filesystemDefault = try! RetentionPolicy(
        scope: .filesystem,
        keepWithinHours: 24,
        keepDaily: 7,
        keepWeekly: 4,
        keepMonthly: 12,
        keepYearly: 2
    )

    public static let databaseDumpsDefault = try! RetentionPolicy(
        scope: .databaseDumps,
        keepWithinHours: 24,
        keepDaily: 14,
        keepWeekly: 8,
        keepMonthly: 12,
        keepYearly: 2
    )
}
