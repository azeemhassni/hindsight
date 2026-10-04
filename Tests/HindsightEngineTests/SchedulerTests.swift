import Foundation
import HindsightCore
import HindsightSchedule
import Testing
@testable import HindsightEngine

private struct FixedPower: PowerSourceReading {
    let onAC: Bool
    func isOnACPower() -> Bool { onAC }
}

private actor Clock {
    private(set) var now: Date
    init(_ start: Date) { now = start }
    func advance(by interval: TimeInterval) { now = now.addingTimeInterval(interval) }
    func read() -> Date { now }
}

private actor Recorder {
    private(set) var fired: [String] = []
    func record(_ key: String) { fired.append(key) }
    var count: Int { fired.count }
}

private func makeEntry(
    id: String,
    cadence: Cadence = .hourly,
    onlyOnAC: Bool = false,
    lastFired: Date? = nil,
    repositoryPath: String? = nil
) throws -> ScheduledEntry {
    ScheduledEntry(
        serverID: try ServerID(validating: id),
        schedule: try Schedule(cadence: cadence, onlyOnACPower: onlyOnAC, timeZoneIdentifier: "UTC"),
        repositoryPath: repositoryPath ?? "/tmp/repos/\(id)",
        lastFiredAt: lastFired
    )
}

@Suite("Scheduler", .timeLimit(.minutes(1)))
struct SchedulerTests {
    @Test("fires a server that has never been backed up")
    func firesNewServer() async throws {
        let recorder = Recorder()
        let scheduler = Scheduler(
            power: AlwaysOnACPower(),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            onDue: { entry in await recorder.record(entry.serverID.value) }
        )
        await scheduler.replaceEntries([try makeEntry(id: "web-01")])

        await scheduler.tick()
        #expect(await recorder.fired == ["web-01"])
    }

    @Test("does not fire the same window twice")
    func firesOncePerWindow() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let recorder = Recorder()
        let scheduler = Scheduler(
            power: AlwaysOnACPower(),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            onDue: { entry in await recorder.record(entry.serverID.value) }
        )
        await scheduler.replaceEntries([try makeEntry(id: "web-01")])

        await scheduler.tick()
        await scheduler.tick()
        await scheduler.tick()
        _ = await clock.read()

        #expect(await recorder.count == 1, "a single due window must fire once")
    }

    @Test("holds an AC-only schedule on battery and releases it on power")
    func respectsPower() async throws {
        let recorder = Recorder()
        let onBattery = Scheduler(
            power: FixedPower(onAC: false),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            onDue: { entry in await recorder.record(entry.serverID.value) }
        )
        let entry = try makeEntry(
            id: "web-01",
            onlyOnAC: true,
            lastFired: Date(timeIntervalSince1970: 1_799_000_000)
        )
        await onBattery.replaceEntries([entry])
        await onBattery.tick()
        #expect(await recorder.count == 0)

        let onPower = Scheduler(
            power: FixedPower(onAC: true),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            onDue: { entry in await recorder.record(entry.serverID.value) }
        )
        await onPower.replaceEntries([entry])
        await onPower.tick()
        #expect(await recorder.count == 1)
    }

    @Test("reports why each server is or is not due")
    func reportsStatus() async throws {
        let scheduler = Scheduler(
            power: FixedPower(onAC: false),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            onDue: { _ in }
        )
        await scheduler.replaceEntries([
            try makeEntry(id: "web-01", onlyOnAC: true, lastFired: Date(timeIntervalSince1970: 1_799_000_000)),
            // Backed up at this exact moment, so the next hourly window is an
            // hour away.
            try makeEntry(id: "web-02", lastFired: Date(timeIntervalSince1970: 1_800_000_000)),
        ])

        let statuses = await scheduler.statuses()
        #expect(statuses.count == 2)
        #expect(statuses[0].decision.reason == .waitingForACPower)
        #expect(statuses[1].decision.reason == .notYetDue)
        #expect(statuses[1].decision.nextFireDate != nil)
    }

    @Test("sleeps until the next run, bounded by the maximum")
    func sleepsUntilNextRun() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = Scheduler(
            configuration: Scheduler.Configuration(maximumSleep: .seconds(900)),
            power: AlwaysOnACPower(),
            clock: { now },
            onDue: { _ in }
        )
        await scheduler.replaceEntries([
            try makeEntry(id: "web-01", cadence: .hourly, lastFired: now),
        ])

        let sleep = await scheduler.tick()
        #expect(sleep <= .seconds(900), "a long gap must still wake up periodically")
        #expect(sleep > .zero)
    }
}

@Suite("Job queue", .timeLimit(.minutes(1)))
struct JobQueueTests {
    private func job(_ id: String, repository: String) throws -> QueuedJob {
        QueuedJob(
            serverID: try ServerID(validating: id),
            kind: .backup,
            repositoryPath: repository
        )
    }

    @Test("runs jobs for different repositories at the same time")
    func runsDifferentRepositoriesConcurrently() async throws {
        let overlap = Recorder()
        let queue = JobQueue { job in
            await overlap.record("start-\(job.serverID.value)")
            try await Task.sleep(for: .milliseconds(200))
            await overlap.record("end-\(job.serverID.value)")
        }

        await queue.enqueue(try job("web-01", repository: "/repos/a"))
        await queue.enqueue(try job("web-02", repository: "/repos/b"))
        await queue.drain()

        let fired = await overlap.fired
        // Both started before either finished.
        #expect(fired.prefix(2).allSatisfy { $0.hasPrefix("start-") })
        #expect(fired.count == 4)
    }

    @Test("makes jobs for one repository take turns, and says which is waiting")
    func serialisesSameRepository() async throws {
        let order = Recorder()
        let queue = JobQueue { job in
            await order.record("start-\(job.serverID.value)")
            try await Task.sleep(for: .milliseconds(150))
            await order.record("end-\(job.serverID.value)")
        }

        let events = EventBox()
        await queue.observe { event in
            if case let .waiting(job, behind) = event {
                Task { await events.record("waiting \(job.serverID.value) behind \(behind.value.prefix(4))") }
            }
        }

        let first = try job("web-01", repository: "/repos/shared")
        let second = try job("web-02", repository: "/repos/shared")
        await queue.enqueue(first)
        await queue.enqueue(second)
        #expect(await queue.pendingCount(forRepository: "/repos/shared") == 1)
        await queue.drain()

        #expect(await order.fired == ["start-web-01", "end-web-01", "start-web-02", "end-web-02"])
        #expect(await events.count >= 1, "the waiting job should be reported, not hidden")
    }

    @Test("reports a failure without stopping the queue")
    func reportsFailures() async throws {
        struct Boom: Error {}
        let queue = JobQueue { job in
            if job.serverID.value == "web-01" { throw Boom() }
        }

        let states = EventBox()
        await queue.observe { event in
            if case let .finished(job, state, _) = event {
                Task { await states.record("\(job.serverID.value)=\(state.rawValue)") }
            }
        }

        await queue.enqueue(try job("web-01", repository: "/repos/shared"))
        await queue.enqueue(try job("web-02", repository: "/repos/shared"))
        await queue.drain()
        try await Task.sleep(for: .milliseconds(100))

        let recorded = await states.values
        #expect(recorded.contains("web-01=failed"))
        #expect(recorded.contains("web-02=succeeded"))
    }
}

private actor EventBox {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
    var count: Int { values.count }
    var fired: [String] { values }
}
