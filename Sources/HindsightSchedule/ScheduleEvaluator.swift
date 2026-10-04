import Foundation
import HindsightCore

/// Works out when a schedule should next run, and whether one is overdue.
public enum ScheduleEvaluator {
    public static func calendar(for schedule: Schedule) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = schedule.timeZone
        return calendar
    }

    /// The next fire time strictly after `date`.
    public static func nextFireDate(
        for schedule: Schedule,
        after date: Date
    ) throws -> Date? {
        let calendar = calendar(for: schedule)

        switch schedule.cadence {
        case .hourly:
            return calendar.nextDate(
                after: date,
                matching: DateComponents(minute: 0),
                matchingPolicy: .nextTime
            )

        case let .everyHours(interval):
            // Aligned to midnight rather than to the last run, so the times are
            // predictable and survive a restart: every 6 hours always means
            // 00:00, 06:00, 12:00, 18:00.
            var candidate = calendar.startOfDay(for: date)
            for _ in 0..<(24 / max(1, interval) * 4 + 8) {
                for hour in stride(from: 0, to: 24, by: interval) {
                    guard let time = calendar.date(
                        bySettingHour: hour,
                        minute: 0,
                        second: 0,
                        of: candidate,
                        matchingPolicy: .nextTime
                    ) else { continue }
                    if time > date { return time }
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: candidate) else { return nil }
                candidate = next
            }
            return nil

        case let .dailyAt(time):
            return calendar.nextDate(
                after: date,
                matching: DateComponents(hour: time.hour, minute: time.minute),
                matchingPolicy: .nextTime
            )

        case let .weeklyAt(weekday, time):
            return calendar.nextDate(
                after: date,
                matching: DateComponents(hour: time.hour, minute: time.minute, weekday: weekday.rawValue),
                matchingPolicy: .nextTime
            )

        case let .cron(expression):
            return try CronExpression(expression).nextFireDate(after: date, calendar: calendar)
        }
    }

    /// Whether a run is due, and when to look again.
    ///
    /// A window missed while the Mac was asleep produces exactly one run, not
    /// one per missed window: catching up on twelve hourly backups at once
    /// would hammer a server to produce eleven snapshots nobody wants.
    public static func decide(
        for schedule: Schedule,
        lastFiredAt: Date?,
        now: Date = Date(),
        onACPower: Bool = true
    ) throws -> ScheduleDecision {
        guard let reference = lastFiredAt else {
            // Never run: due immediately, so adding a server backs it up now.
            return ScheduleDecision(
                isDue: true,
                reason: .neverRun,
                nextFireDate: try nextFireDate(for: schedule, after: now)
            )
        }

        guard let due = try nextFireDate(for: schedule, after: reference) else {
            return ScheduleDecision(isDue: false, reason: .noFutureFireDate, nextFireDate: nil)
        }

        guard due <= now else {
            return ScheduleDecision(isDue: false, reason: .notYetDue, nextFireDate: due)
        }

        if schedule.onlyOnACPower, !onACPower {
            return ScheduleDecision(
                isDue: false,
                reason: .waitingForACPower,
                nextFireDate: due
            )
        }

        let missed = try countMissedWindows(for: schedule, since: reference, until: now)
        return ScheduleDecision(
            isDue: true,
            reason: missed > 1 ? .caughtUpAfterMissingWindows(missed) : .due,
            nextFireDate: try nextFireDate(for: schedule, after: now)
        )
    }

    static func countMissedWindows(
        for schedule: Schedule,
        since: Date,
        until: Date,
        limit: Int = 1000
    ) throws -> Int {
        var count = 0
        var cursor = since
        while count < limit {
            guard let next = try nextFireDate(for: schedule, after: cursor), next <= until else { break }
            count += 1
            cursor = next
        }
        return count
    }
}

public struct ScheduleDecision: Sendable, Hashable {
    public enum Reason: Sendable, Hashable {
        case neverRun
        case due
        case caughtUpAfterMissingWindows(Int)
        case notYetDue
        case waitingForACPower
        case noFutureFireDate
    }

    public var isDue: Bool
    public var reason: Reason
    public var nextFireDate: Date?

    public var explanation: String {
        switch reason {
        case .neverRun: "This server has never been backed up."
        case .due: "A scheduled backup is due."
        case let .caughtUpAfterMissingWindows(count):
            "\(count) scheduled backups were missed; running once to catch up."
        case .notYetDue: "Not due yet."
        case .waitingForACPower: "Waiting for mains power."
        case .noFutureFireDate: "This schedule has no future run."
        }
    }
}
