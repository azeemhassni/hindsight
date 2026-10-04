import Foundation

public struct TimeOfDay: Hashable, Sendable, Codable, Comparable {
    public let hour: Int
    public let minute: Int

    public init(hour: Int, minute: Int) throws {
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            throw ValidationError.invalidTimeOfDay(hour: hour, minute: minute)
        }
        self.hour = hour
        self.minute = minute
    }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }
}

public enum Weekday: Int, Hashable, Sendable, Codable, CaseIterable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday
}

public enum Cadence: Hashable, Sendable, Codable {
    case hourly
    case everyHours(Int)
    case dailyAt(TimeOfDay)
    case weeklyAt(Weekday, TimeOfDay)
    /// Stored as the user typed it. Parsing happens in the scheduler, so an
    /// unparseable expression surfaces as a schedule error rather than being
    /// silently normalised away.
    case cron(String)

    public func validated() throws -> Cadence {
        if case let .everyHours(hours) = self, !(1...24).contains(hours) {
            throw ValidationError.invalidHourInterval(hours)
        }
        return self
    }
}

public struct Schedule: Hashable, Sendable, Codable {
    public var cadence: Cadence
    public var onlyOnACPower: Bool
    /// nil means the Mac's current zone. An explicit zone makes "daily at
    /// 03:00" mean the same instant after the user travels, and makes DST
    /// behaviour testable.
    public var timeZoneIdentifier: String?

    public init(cadence: Cadence, onlyOnACPower: Bool = false, timeZoneIdentifier: String? = nil) throws {
        if let identifier = timeZoneIdentifier, TimeZone(identifier: identifier) == nil {
            throw ValidationError.unknownTimeZone(identifier)
        }
        self.cadence = try cadence.validated()
        self.onlyOnACPower = onlyOnACPower
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public var timeZone: TimeZone {
        timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
    }
}
