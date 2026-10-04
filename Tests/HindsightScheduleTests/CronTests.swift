import Foundation
import HindsightCore
import Testing
@testable import HindsightSchedule

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func date(_ text: String, zone: String = "UTC") -> Date {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    formatter.timeZone = TimeZone(identifier: zone)!
    return formatter.date(from: text)!
}

private func describe(_ date: Date?, zone: String = "UTC") -> String {
    guard let date else { return "none" }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    formatter.timeZone = TimeZone(identifier: zone)!
    return formatter.string(from: date)
}

@Suite("Cron parsing")
struct CronParsingTests {
    @Test("parses every field form")
    func parsesFields() throws {
        let expression = try CronExpression("*/15 2,14 1-7 jan-mar mon")
        #expect(expression.minutes == [0, 15, 30, 45])
        #expect(expression.hours == [2, 14])
        #expect(expression.daysOfMonth == [1, 2, 3, 4, 5, 6, 7])
        #expect(expression.months == [1, 2, 3])
        #expect(expression.daysOfWeek == [1])
    }

    @Test("treats 0 and 7 as Sunday, as every other cron does")
    func sundayIsBothZeroAndSeven() throws {
        #expect(try CronExpression("0 0 * * 0").daysOfWeek == [0])
        #expect(try CronExpression("0 0 * * 7").daysOfWeek == [0])
        #expect(try CronExpression("0 0 * * sun").daysOfWeek == [0])
    }

    @Test("rejects nonsense", arguments: [
        "", "* * * *", "* * * * * *", "60 * * * *", "* 24 * * *",
        "* * 0 * *", "* * 32 * *", "* * * 13 *", "* * * * 8",
        "*/0 * * * *", "5-1 * * * *", "a * * * *", ", * * * *", "*/x * * * *",
    ])
    func rejectsInvalid(_ text: String) {
        #expect(throws: (any Error).self) { try CronExpression(text) }
    }

    @Test("finds the next minute that matches")
    func findsNextFire() throws {
        let expression = try CronExpression("30 3 * * *")
        let next = expression.nextFireDate(after: date("2026-03-10 04:00"), calendar: utcCalendar())
        #expect(describe(next) == "2026-03-11 03:30")
    }

    @Test("never returns the time it was given")
    func isStrictlyAfter() throws {
        let expression = try CronExpression("0 * * * *")
        let exact = date("2026-03-10 04:00")
        #expect(describe(expression.nextFireDate(after: exact, calendar: utcCalendar())) == "2026-03-10 05:00")
    }

    @Test("combines a restricted day of month and day of week with or, not and")
    func dayFieldsCombineWithOr() throws {
        // The 13th of March 2026 is a Friday; the 1st is a Sunday.
        let expression = try CronExpression("0 0 1 * fri")
        let calendar = utcCalendar()
        let first = expression.nextFireDate(after: date("2026-02-28 00:00"), calendar: calendar)
        #expect(describe(first) == "2026-03-01 00:00")

        let second = expression.nextFireDate(after: date("2026-03-01 00:00"), calendar: calendar)
        #expect(describe(second) == "2026-03-06 00:00")
    }

    @Test("handles 29 February by waiting for a leap year")
    func handlesLeapDay() throws {
        let expression = try CronExpression("0 12 29 2 *")
        let next = expression.nextFireDate(after: date("2026-03-01 00:00"), calendar: utcCalendar())
        #expect(describe(next) == "2028-02-29 12:00")
    }

    @Test("gives up rather than searching forever for a date that cannot happen")
    func givesUpOnImpossibleDates() throws {
        // The 31st of February never arrives.
        let expression = try CronExpression("0 0 31 2 *")
        #expect(expression.nextFireDate(after: date("2026-01-01 00:00"), calendar: utcCalendar()) == nil)
    }
}

@Suite("Schedule evaluation")
struct ScheduleEvaluationTests {
    @Test("hourly fires on the hour")
    func hourly() throws {
        let schedule = try Schedule(cadence: .hourly, timeZoneIdentifier: "UTC")
        let next = try ScheduleEvaluator.nextFireDate(for: schedule, after: date("2026-05-01 10:17"))
        #expect(describe(next) == "2026-05-01 11:00")
    }

    @Test("every N hours stays aligned to midnight, so a restart does not shift it")
    func everyNHoursIsAligned() throws {
        let schedule = try Schedule(cadence: .everyHours(6), timeZoneIdentifier: "UTC")
        #expect(describe(try ScheduleEvaluator.nextFireDate(for: schedule, after: date("2026-05-01 01:00"))) == "2026-05-01 06:00")
        #expect(describe(try ScheduleEvaluator.nextFireDate(for: schedule, after: date("2026-05-01 06:00"))) == "2026-05-01 12:00")
        #expect(describe(try ScheduleEvaluator.nextFireDate(for: schedule, after: date("2026-05-01 19:30"))) == "2026-05-02 00:00")
    }

    @Test("daily fires at the configured local time")
    func dailyAtTime() throws {
        let schedule = try Schedule(cadence: .dailyAt(TimeOfDay(hour: 3, minute: 15)), timeZoneIdentifier: "UTC")
        #expect(describe(try ScheduleEvaluator.nextFireDate(for: schedule, after: date("2026-05-01 03:14"))) == "2026-05-01 03:15")
        #expect(describe(try ScheduleEvaluator.nextFireDate(for: schedule, after: date("2026-05-01 03:15"))) == "2026-05-02 03:15")
    }

    @Test("weekly fires on the configured weekday")
    func weeklyAtTime() throws {
        let schedule = try Schedule(
            cadence: .weeklyAt(.sunday, TimeOfDay(hour: 2, minute: 0)),
            timeZoneIdentifier: "UTC"
        )
        // 2026-05-01 is a Friday.
        #expect(describe(try ScheduleEvaluator.nextFireDate(for: schedule, after: date("2026-05-01 00:00"))) == "2026-05-03 02:00")
    }

    @Test("keeps the wall-clock time across the spring clock change")
    func survivesSpringForward() throws {
        // Berlin moves 02:00 to 03:00 on 29 March 2026.
        let schedule = try Schedule(
            cadence: .dailyAt(TimeOfDay(hour: 2, minute: 30)),
            timeZoneIdentifier: "Europe/Berlin"
        )
        let next = try ScheduleEvaluator.nextFireDate(
            for: schedule,
            after: date("2026-03-28 03:00", zone: "Europe/Berlin")
        )
        // 02:30 does not exist that night, so the run lands at the next valid
        // time rather than being skipped for the day.
        let described = describe(next, zone: "Europe/Berlin")
        #expect(described.hasPrefix("2026-03-29"), "expected a run on the 29th, got \(described)")
    }

    @Test("keeps the wall-clock time across the autumn clock change")
    func survivesFallBack() throws {
        // Berlin repeats 02:00–03:00 on 25 October 2026.
        let schedule = try Schedule(
            cadence: .dailyAt(TimeOfDay(hour: 2, minute: 30)),
            timeZoneIdentifier: "Europe/Berlin"
        )
        let next = try ScheduleEvaluator.nextFireDate(
            for: schedule,
            after: date("2026-10-24 12:00", zone: "Europe/Berlin")
        )
        #expect(describe(next, zone: "Europe/Berlin") == "2026-10-25 02:30")

        // And it fires only once that day, not twice.
        let following = try ScheduleEvaluator.nextFireDate(for: schedule, after: next!)
        #expect(describe(following, zone: "Europe/Berlin") == "2026-10-26 02:30")
    }

    @Test("a schedule in another time zone does not drift when the Mac moves")
    func respectsItsOwnTimeZone() throws {
        let berlin = try Schedule(
            cadence: .dailyAt(TimeOfDay(hour: 3, minute: 0)),
            timeZoneIdentifier: "Europe/Berlin"
        )
        let tokyo = try Schedule(
            cadence: .dailyAt(TimeOfDay(hour: 3, minute: 0)),
            timeZoneIdentifier: "Asia/Tokyo"
        )
        let from = date("2026-05-01 00:00")
        let berlinNext = try ScheduleEvaluator.nextFireDate(for: berlin, after: from)
        let tokyoNext = try ScheduleEvaluator.nextFireDate(for: tokyo, after: from)
        #expect(berlinNext != tokyoNext)
    }
}

@Suite("Catch-up and power")
struct CatchUpTests {
    @Test("a server that has never been backed up is due immediately")
    func neverRunIsDue() throws {
        let schedule = try Schedule(cadence: .hourly)
        let decision = try ScheduleEvaluator.decide(for: schedule, lastFiredAt: nil)
        #expect(decision.isDue)
        #expect(decision.reason == .neverRun)
    }

    @Test("not due before its time")
    func notYetDue() throws {
        let schedule = try Schedule(cadence: .hourly, timeZoneIdentifier: "UTC")
        let decision = try ScheduleEvaluator.decide(
            for: schedule,
            lastFiredAt: date("2026-05-01 10:00"),
            now: date("2026-05-01 10:30")
        )
        #expect(!decision.isDue)
        #expect(decision.reason == .notYetDue)
        #expect(describe(decision.nextFireDate) == "2026-05-01 11:00")
    }

    @Test("twelve hours asleep produces one catch-up run, not twelve")
    func catchesUpOnce() throws {
        let schedule = try Schedule(cadence: .hourly, timeZoneIdentifier: "UTC")
        let decision = try ScheduleEvaluator.decide(
            for: schedule,
            lastFiredAt: date("2026-05-01 00:00"),
            now: date("2026-05-01 12:05")
        )
        #expect(decision.isDue)
        #expect(decision.reason == .caughtUpAfterMissingWindows(12))
        // And it realigns from now rather than replaying the backlog.
        #expect(describe(decision.nextFireDate) == "2026-05-01 13:00")
    }

    @Test("an AC-only schedule waits on battery and runs when power returns")
    func defersOnBattery() throws {
        let schedule = try Schedule(cadence: .hourly, onlyOnACPower: true, timeZoneIdentifier: "UTC")
        let onBattery = try ScheduleEvaluator.decide(
            for: schedule,
            lastFiredAt: date("2026-05-01 00:00"),
            now: date("2026-05-01 12:05"),
            onACPower: false
        )
        #expect(!onBattery.isDue)
        #expect(onBattery.reason == .waitingForACPower)

        let onPower = try ScheduleEvaluator.decide(
            for: schedule,
            lastFiredAt: date("2026-05-01 00:00"),
            now: date("2026-05-01 12:05"),
            onACPower: true
        )
        #expect(onPower.isDue)
    }

    @Test("a schedule without the AC restriction runs on battery")
    func runsOnBatteryWhenAllowed() throws {
        let schedule = try Schedule(cadence: .hourly, onlyOnACPower: false, timeZoneIdentifier: "UTC")
        let decision = try ScheduleEvaluator.decide(
            for: schedule,
            lastFiredAt: date("2026-05-01 00:00"),
            now: date("2026-05-01 12:05"),
            onACPower: false
        )
        #expect(decision.isDue)
    }

    @Test("explains itself in words a person can read")
    func explainsItself() throws {
        let schedule = try Schedule(cadence: .hourly, onlyOnACPower: true, timeZoneIdentifier: "UTC")
        let decision = try ScheduleEvaluator.decide(
            for: schedule,
            lastFiredAt: date("2026-05-01 00:00"),
            now: date("2026-05-01 12:05"),
            onACPower: false
        )
        #expect(decision.explanation == "Waiting for mains power.")
    }

    @Test("a cron cadence is evaluated like any other")
    func cronCadence() throws {
        let schedule = try Schedule(cadence: .cron("0 4 * * *"), timeZoneIdentifier: "UTC")
        let decision = try ScheduleEvaluator.decide(
            for: schedule,
            lastFiredAt: date("2026-05-01 04:00"),
            now: date("2026-05-02 05:00")
        )
        #expect(decision.isDue)
        #expect(describe(decision.nextFireDate) == "2026-05-03 04:00")
    }

    @Test("an unparseable cron expression surfaces as an error, not a silent no-op")
    func badCronThrows() throws {
        let schedule = try Schedule(cadence: .cron("not a cron"), timeZoneIdentifier: "UTC")
        #expect(throws: CronError.self) {
            try ScheduleEvaluator.decide(for: schedule, lastFiredAt: Date(), now: Date())
        }
    }
}
