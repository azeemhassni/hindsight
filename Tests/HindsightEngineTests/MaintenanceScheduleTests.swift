import Foundation
import Testing
@testable import HindsightEngine

@Suite("Maintenance scheduling")
struct MaintenanceScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("a repository that has never been maintained is due immediately")
    func neverMaintainedIsDue() {
        #expect(MaintenanceSchedule.default.prunesAreDue(lastPrunedAt: nil, now: now))
        #expect(MaintenanceSchedule.default.checkIsDue(lastCheckedAt: nil, now: now))
    }

    @Test("prunes come round daily by default, checks weekly")
    func defaultCadences() {
        let schedule = MaintenanceSchedule.default
        #expect(!schedule.prunesAreDue(lastPrunedAt: now.addingTimeInterval(-3600), now: now))
        #expect(schedule.prunesAreDue(lastPrunedAt: now.addingTimeInterval(-25 * 3600), now: now))
        #expect(!schedule.checkIsDue(lastCheckedAt: now.addingTimeInterval(-3 * 86400), now: now))
        #expect(schedule.checkIsDue(lastCheckedAt: now.addingTimeInterval(-8 * 86400), now: now))
    }

    @Test("pruning wins when both are due, because it rewrites the packs anyway")
    func prunePreferredOverCheck() {
        // Reading every pack just before a prune rewrites them is wasted work,
        // and a prune is followed by a structural check regardless.
        #expect(
            MaintenancePlanner.decide(
                schedule: .default,
                lastPrunedAt: nil,
                lastCheckedAt: nil,
                now: now
            ) == .prune
        )
    }

    @Test("a check runs once pruning is up to date")
    func checkRunsWhenPruneIsFresh() {
        #expect(
            MaintenancePlanner.decide(
                schedule: .default,
                lastPrunedAt: now.addingTimeInterval(-3600),
                lastCheckedAt: now.addingTimeInterval(-10 * 86400),
                now: now
            ) == .check
        )
    }

    @Test("nothing runs when nothing is due")
    func nothingWhenFresh() {
        #expect(
            MaintenancePlanner.decide(
                schedule: .default,
                lastPrunedAt: now.addingTimeInterval(-3600),
                lastCheckedAt: now.addingTimeInterval(-3600),
                now: now
            ) == .nothing
        )
    }

    @Test("maintenance holds off on battery when asked to")
    func respectsPower() {
        #expect(
            MaintenancePlanner.decide(
                schedule: .default,
                lastPrunedAt: nil,
                lastCheckedAt: nil,
                now: now,
                onACPower: false
            ) == .nothing
        )
        // And runs on battery when the setting is off, because someone who
        // turned it off meant it.
        var schedule = MaintenanceSchedule.default
        schedule.onlyOnACPower = false
        #expect(
            MaintenancePlanner.decide(
                schedule: schedule,
                lastPrunedAt: nil,
                lastCheckedAt: nil,
                now: now,
                onACPower: false
            ) == .prune
        )
    }

    @Test("says how long a full verification pass takes at this cadence")
    func describesFullPass() {
        #expect(MaintenanceSchedule.default.fullPassDescription(divisor: 4) == "about 4 weeks")
        var daily = MaintenanceSchedule.default
        daily.checkIntervalHours = 24
        #expect(daily.fullPassDescription(divisor: 4) == "about 4 days")
    }

    @Test("maps a decision onto the job it needs")
    func mapsToJobKind() {
        #expect(MaintenanceDecision.prune.jobKind == .forgetAndPrune)
        #expect(MaintenanceDecision.check.jobKind == .check(readDataSubset: nil))
        #expect(MaintenanceDecision.nothing.jobKind == nil)
    }
}
