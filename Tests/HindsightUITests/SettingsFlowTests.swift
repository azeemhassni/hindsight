import Foundation
import HindsightCore
import HindsightProtocol
import Testing
@testable import HindsightUI

@MainActor
@Suite("Settings flow")
struct SettingsFlowTests {
    private func makeFlow(
        captured: Captured? = nil
    ) throws -> SettingsFlow {
        let model = AppModel()
        model.send = { request in
            if case let .updateServerSettings(update) = request {
                await captured?.record(update)
            }
            return .done
        }
        return SettingsFlow(
            model: model,
            serverID: "web-01",
            cadence: .everyHours(6),
            onlyOnACPower: true,
            retention: .filesystemDefault,
            bandwidthLimitKiB: nil,
            repositoryPath: "/Volumes/Backups/repos/web-01",
            coolifyTokenIsSet: true,
            checkRotationDivisor: 4,
            excludePatterns: ["/srv/cache"]
        )
    }

    @Test("nothing to save until something changes")
    func noChangesNoSave() throws {
        let flow = try makeFlow()
        #expect(!flow.hasChanges)
        #expect(flow.update() == nil)
    }

    @Test("sends only the fields that changed")
    func sendsOnlyChanges() async throws {
        let captured = Captured()
        let flow = try makeFlow(captured: captured)
        flow.retention.keepDaily = 14

        #expect(flow.hasChanges)
        #expect(await flow.save())

        let update = try #require(await captured.updates.first)
        #expect(update.keepDaily == 14)
        // Everything untouched stays nil, so saving one field cannot reset
        // another that was set somewhere else.
        #expect(update.keepWeekly == nil)
        #expect(update.cadence == nil)
        #expect(update.excludePatterns == nil)
        #expect(update.coolifyToken == nil)
    }

    @Test("does not resend a token that was never retyped")
    func doesNotResendStoredToken() async throws {
        let captured = Captured()
        let flow = try makeFlow(captured: captured)
        // The field shows a placeholder for a token that is already stored;
        // leaving it alone must not overwrite the real one.
        #expect(flow.coolifyToken == SettingsFlow.tokenPlaceholder)
        flow.onlyOnACPower = false
        _ = await flow.save()

        let update = try #require(await captured.updates.first)
        #expect(update.coolifyToken == nil)
        #expect(update.onlyOnACPower == false)
    }

    @Test("an emptied token field removes the stored token")
    func emptyTokenRemovesIt() async throws {
        let captured = Captured()
        let flow = try makeFlow(captured: captured)
        flow.coolifyToken = ""
        _ = await flow.save()

        let update = try #require(await captured.updates.first)
        #expect(update.coolifyToken == "")
    }

    @Test("refuses to save a policy that keeps nothing")
    func refusesEmptyRetention() async throws {
        let captured = Captured()
        let flow = try makeFlow(captured: captured)
        flow.retention.keepWithinHours = 0
        flow.retention.keepDaily = 0
        flow.retention.keepWeekly = 0
        flow.retention.keepMonthly = 0
        flow.retention.keepYearly = 0

        #expect(flow.keepsNothing)
        #expect(flow.blockingReason?.contains("keeps nothing") == true)
        #expect(!(await flow.save()))
        #expect(await captured.updates.isEmpty, "a destructive policy was sent anyway")
    }

    @Test("refuses a bandwidth limit of zero")
    func refusesZeroBandwidth() async throws {
        let flow = try makeFlow()
        flow.bandwidthLimitKiB = 0
        #expect(flow.blockingReason?.contains("greater than zero") == true)
        #expect(!(await flow.save()))
    }

    @Test("sends a changed cadence in a form the agent can decode")
    func sendsCadence() async throws {
        let captured = Captured()
        let flow = try makeFlow(captured: captured)
        flow.cadence = .dailyAt(try TimeOfDay(hour: 2, minute: 30))
        _ = await flow.save()

        let update = try #require(await captured.updates.first)
        let data = try #require(update.cadence)
        let decoded = try JSONDecoder().decode(Cadence.self, from: data)
        #expect(decoded == .dailyAt(try TimeOfDay(hour: 2, minute: 30)))
    }

    @Test("reports a refusal from the agent rather than looking saved")
    func reportsFailure() async throws {
        let model = AppModel()
        model.send = { _ in .failed(message: "the catalog is read only") }
        let flow = SettingsFlow(
            model: model,
            serverID: "web-01",
            cadence: .hourly,
            onlyOnACPower: false,
            retention: .filesystemDefault,
            bandwidthLimitKiB: nil,
            repositoryPath: "/tmp",
            coolifyTokenIsSet: false,
            checkRotationDivisor: 4,
            excludePatterns: []
        )
        flow.retention.keepDaily = 9
        #expect(!(await flow.save()))
        #expect(flow.lastSaveFailed?.contains("read only") == true)
    }
}

private actor Captured {
    private(set) var updates: [ServerSettingsUpdate] = []
    func record(_ update: ServerSettingsUpdate) { updates.append(update) }
}
