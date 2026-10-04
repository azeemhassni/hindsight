import Foundation
import HindsightCore
import HindsightSchedule

public struct ScheduledEntry: Sendable, Hashable {
    public var serverID: ServerID
    public var resourceUUID: String?
    public var schedule: Schedule
    public var repositoryPath: String
    public var lastFiredAt: Date?

    public init(
        serverID: ServerID,
        resourceUUID: String? = nil,
        schedule: Schedule,
        repositoryPath: String,
        lastFiredAt: Date? = nil
    ) {
        self.serverID = serverID
        self.resourceUUID = resourceUUID
        self.schedule = schedule
        self.repositoryPath = repositoryPath
        self.lastFiredAt = lastFiredAt
    }

    var key: String { serverID.value + "\u{0}" + (resourceUUID ?? "") }
}

public struct SchedulerStatus: Sendable, Hashable {
    public var entry: ScheduledEntry
    public var decision: ScheduleDecision
}

/// Decides what should run and when to wake up next.
///
/// One timer for everything, rather than one per server: a Mac with twenty
/// servers should not keep twenty timers alive, and coalescing makes the
/// wake-up behaviour easy to reason about.
public actor Scheduler {
    public struct Configuration: Sendable {
        /// Never sleep longer than this, so a clock change or a missed
        /// notification cannot leave the agent dormant.
        public var maximumSleep: Duration
        public var minimumSleep: Duration

        public init(maximumSleep: Duration = .seconds(900), minimumSleep: Duration = .seconds(1)) {
            self.maximumSleep = maximumSleep
            self.minimumSleep = minimumSleep
        }
    }

    private var entries: [String: ScheduledEntry] = [:]
    private let configuration: Configuration
    private let power: any PowerSourceReading
    private let clock: @Sendable () -> Date
    private let onDue: @Sendable (ScheduledEntry) async -> Void
    private var timer: Task<Void, Never>?

    public init(
        configuration: Configuration = Configuration(),
        power: any PowerSourceReading = SystemPowerSource(),
        clock: @escaping @Sendable () -> Date = { Date() },
        onDue: @escaping @Sendable (ScheduledEntry) async -> Void
    ) {
        self.configuration = configuration
        self.power = power
        self.clock = clock
        self.onDue = onDue
    }

    public func replaceEntries(_ newEntries: [ScheduledEntry]) {
        entries = Dictionary(uniqueKeysWithValues: newEntries.map { ($0.key, $0) })
    }

    public func upsert(_ entry: ScheduledEntry) {
        entries[entry.key] = entry
    }

    public func remove(serverID: ServerID, resourceUUID: String? = nil) {
        entries[ScheduledEntry(
            serverID: serverID,
            resourceUUID: resourceUUID,
            schedule: try! Schedule(cadence: .hourly),
            repositoryPath: ""
        ).key] = nil
    }

    public func markFired(serverID: ServerID, resourceUUID: String? = nil, at date: Date) {
        let key = serverID.value + "\u{0}" + (resourceUUID ?? "")
        entries[key]?.lastFiredAt = date
    }

    public func statuses() -> [SchedulerStatus] {
        entries.values.compactMap { entry in
            guard let decision = try? ScheduleEvaluator.decide(
                for: entry.schedule,
                lastFiredAt: entry.lastFiredAt,
                now: clock(),
                onACPower: power.isOnACPower()
            ) else { return nil }
            return SchedulerStatus(entry: entry, decision: decision)
        }
        .sorted { $0.entry.key < $1.entry.key }
    }

    /// Runs one pass: fires everything due and reports when to look again.
    @discardableResult
    public func tick() async -> Duration {
        let now = clock()
        let onPower = power.isOnACPower()
        var soonest: Date?

        for entry in entries.values.sorted(by: { $0.key < $1.key }) {
            guard let decision = try? ScheduleEvaluator.decide(
                for: entry.schedule,
                lastFiredAt: entry.lastFiredAt,
                now: now,
                onACPower: onPower
            ) else { continue }

            if decision.isDue {
                entries[entry.key]?.lastFiredAt = now
                await onDue(entry)
            }

            if let next = decision.nextFireDate {
                soonest = min(soonest ?? next, next)
            }
        }

        guard let soonest else { return configuration.maximumSleep }
        let interval = soonest.timeIntervalSince(clock())
        if interval <= 0 { return configuration.minimumSleep }
        return min(.seconds(interval), configuration.maximumSleep)
    }

    public func start() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let sleep = await self.tick()
                try? await Task.sleep(for: sleep)
            }
        }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Called when the Mac wakes or power changes: re-evaluate immediately
    /// rather than waiting out a sleep that was scheduled before.
    public func wakeUp() async {
        await tick()
        if timer != nil {
            stop()
            start()
        }
    }
}
