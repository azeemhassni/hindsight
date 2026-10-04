import Foundation
import HindsightCore

public enum CronError: Error, Hashable, Sendable, CustomStringConvertible {
    case wrongNumberOfFields(found: Int, text: String)
    case badField(name: String, value: String)
    case valueOutOfRange(name: String, value: Int, allowed: ClosedRange<Int>)
    case emptyField(name: String)
    case stepMustBePositive(name: String, value: String)

    public var description: String {
        switch self {
        case let .wrongNumberOfFields(found, text):
            """
            A cron expression needs five fields — minute, hour, day of month, \
            month, day of week — but \(text.debugDescription) has \(found).
            """
        case let .badField(name, value):
            "The \(name) field \(value.debugDescription) is not valid."
        case let .valueOutOfRange(name, value, allowed):
            "\(value) is outside the allowed range for \(name) (\(allowed.lowerBound)–\(allowed.upperBound))."
        case let .emptyField(name):
            "The \(name) field is empty."
        case let .stepMustBePositive(name, value):
            "The step in the \(name) field \(value.debugDescription) must be greater than zero."
        }
    }
}

/// A five-field cron expression.
///
/// Written rather than taken from a dependency because the semantics are small
/// and the one subtlety — that a restricted day-of-month and a restricted
/// day-of-week combine as "or", not "and" — is easier to get right and test
/// than to audit in someone else's code.
public struct CronExpression: Sendable, Hashable {
    public let text: String
    let minutes: Set<Int>
    let hours: Set<Int>
    let daysOfMonth: Set<Int>
    let months: Set<Int>
    let daysOfWeek: Set<Int>
    let dayOfMonthRestricted: Bool
    let dayOfWeekRestricted: Bool

    public init(_ text: String) throws {
        let fields = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5 else {
            throw CronError.wrongNumberOfFields(found: fields.count, text: text)
        }

        self.text = text
        minutes = try Self.parse(fields[0], name: "minute", range: 0...59)
        hours = try Self.parse(fields[1], name: "hour", range: 0...23)
        daysOfMonth = try Self.parse(fields[2], name: "day of month", range: 1...31)
        months = try Self.parse(fields[3], name: "month", range: 1...12, aliases: Self.monthAliases)
        // Both 0 and 7 mean Sunday, as every other cron does.
        let weekdays = try Self.parse(fields[4], name: "day of week", range: 0...7, aliases: Self.weekdayAliases)
        daysOfWeek = Set(weekdays.map { $0 == 7 ? 0 : $0 })
        dayOfMonthRestricted = fields[2] != "*"
        dayOfWeekRestricted = fields[4] != "*"
    }

    static let monthAliases = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    ]

    static let weekdayAliases = [
        "sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6,
    ]

    static func parse(
        _ field: String,
        name: String,
        range: ClosedRange<Int>,
        aliases: [String: Int] = [:]
    ) throws -> Set<Int> {
        guard !field.isEmpty else { throw CronError.emptyField(name: name) }

        var values: Set<Int> = []
        for part in field.split(separator: ",", omittingEmptySubsequences: false) {
            guard !part.isEmpty else { throw CronError.badField(name: name, value: field) }

            var step = 1
            var body = String(part)
            if let slash = body.firstIndex(of: "/") {
                let stepText = String(body[body.index(after: slash)...])
                guard let parsed = Int(stepText), parsed > 0 else {
                    throw CronError.stepMustBePositive(name: name, value: String(part))
                }
                step = parsed
                body = String(body[body.startIndex..<slash])
            }

            let bounds: ClosedRange<Int>
            if body == "*" {
                bounds = range
            } else if let dash = body.dropFirst().firstIndex(of: "-") {
                let lower = try Self.number(String(body[body.startIndex..<dash]), name: name, range: range, aliases: aliases)
                let upper = try Self.number(String(body[body.index(after: dash)...]), name: name, range: range, aliases: aliases)
                guard lower <= upper else { throw CronError.badField(name: name, value: String(part)) }
                bounds = lower...upper
            } else {
                let value = try Self.number(body, name: name, range: range, aliases: aliases)
                bounds = value...value
            }

            for value in stride(from: bounds.lowerBound, through: bounds.upperBound, by: step) {
                values.insert(value)
            }
        }

        guard !values.isEmpty else { throw CronError.badField(name: name, value: field) }
        return values
    }

    private static func number(
        _ text: String,
        name: String,
        range: ClosedRange<Int>,
        aliases: [String: Int]
    ) throws -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let value: Int
        if let alias = aliases[trimmed.lowercased()] {
            value = alias
        } else if let parsed = Int(trimmed) {
            value = parsed
        } else {
            throw CronError.badField(name: name, value: text)
        }
        guard range.contains(value) else {
            throw CronError.valueOutOfRange(name: name, value: value, allowed: range)
        }
        return value
    }

    func matches(_ components: DateComponents) -> Bool {
        guard let minute = components.minute,
              let hour = components.hour,
              let day = components.day,
              let month = components.month,
              let weekday = components.weekday
        else { return false }

        guard minutes.contains(minute), hours.contains(hour), months.contains(month) else { return false }

        // Calendar weekdays are 1-based from Sunday; cron's are 0-based.
        let cronWeekday = weekday - 1
        let dayMatches = daysOfMonth.contains(day)
        let weekdayMatches = daysOfWeek.contains(cronWeekday)

        switch (dayOfMonthRestricted, dayOfWeekRestricted) {
        case (false, false): return true
        case (true, false): return dayMatches
        case (false, true): return weekdayMatches
        // Classic cron: when both are restricted, either one matching is enough.
        case (true, true): return dayMatches || weekdayMatches
        }
    }

    /// The next time this expression fires, strictly after `date`.
    ///
    /// Searches day by day and then minute by minute within a matching day,
    /// rather than minute by minute across years.
    public func nextFireDate(
        after date: Date,
        calendar: Calendar,
        searchLimitInDays: Int = 366 * 5
    ) -> Date? {
        var day = calendar.startOfDay(for: date)

        for _ in 0...searchLimitInDays {
            let dayComponents = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            if let month = dayComponents.month, months.contains(month), dayMatchesDate(dayComponents) {
                for hour in hours.sorted() {
                    for minute in minutes.sorted() {
                        var candidateComponents = DateComponents()
                        candidateComponents.year = dayComponents.year
                        candidateComponents.month = dayComponents.month
                        candidateComponents.day = dayComponents.day
                        candidateComponents.hour = hour
                        candidateComponents.minute = minute
                        // A time that does not exist on this day, because the
                        // clock jumped forward, simply does not fire.
                        guard let candidate = calendar.date(from: candidateComponents) else { continue }
                        if candidate > date { return candidate }
                    }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }

    private func dayMatchesDate(_ components: DateComponents) -> Bool {
        guard let day = components.day, let weekday = components.weekday else { return false }
        let dayMatches = daysOfMonth.contains(day)
        let weekdayMatches = daysOfWeek.contains(weekday - 1)
        switch (dayOfMonthRestricted, dayOfWeekRestricted) {
        case (false, false): return true
        case (true, false): return dayMatches
        case (false, true): return weekdayMatches
        case (true, true): return dayMatches || weekdayMatches
        }
    }
}
