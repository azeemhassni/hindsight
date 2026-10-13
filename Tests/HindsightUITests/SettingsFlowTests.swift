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

/// What the sheet asks you to type has to be what the agent checks.
///
/// The agent compares the typed value against the ssh host it is connected to;
/// the sheet used to ask for the server's display name, so a restore would be
/// refused after someone typed exactly what they were asked for.
@MainActor
@Suite("Restore confirmation")
struct RestoreConfirmationTests {
    private func flow(host: String) -> RestoreFlow {
        let flow = RestoreFlow(
            model: AppModel(),
            serverID: "web-01",
            serverHostname: host
        )
        flow.snapshotID = "aa11"
        flow.preview = RestorePreviewReport(
            changes: [],
            safetySnapshotID: "ffee",
            bytesAdded: 0,
            bytesRemoved: 0
        )
        return flow
    }

    @Test("the hostname to confirm is the ssh host")
    func confirmsTheSSHHost() {
        let flow = flow(host: "connection.example.dev")
        #expect(flow.hostnameToConfirm == "connection.example.dev")

        flow.typedHostname = "Example server"
        #expect(!flow.canConfirm, "a display name must not confirm a restore")

        flow.typedHostname = "connection.example.dev"
        #expect(flow.canConfirm)
    }

    @Test("restoring onto another machine confirms that machine")
    func confirmsTheTarget() {
        let flow = flow(host: "old.example.dev")
        flow.targetServerID = "web-02"
        flow.targetHostname = "new.example.dev"

        #expect(flow.hostnameToConfirm == "new.example.dev")
        #expect(flow.writtenServerID == "web-02")

        // The source's hostname must not unlock a write to the target.
        flow.typedHostname = "old.example.dev"
        #expect(!flow.canConfirm)

        flow.typedHostname = "new.example.dev"
        #expect(flow.canConfirm)
    }

    @Test("the Touch ID prompt names both machines when they differ")
    func promptNamesBothEnds() {
        let flow = flow(host: "old.example.dev")
        #expect(flow.confirmationReason.contains("to old.example.dev"))

        flow.targetServerID = "web-02"
        flow.targetHostname = "new.example.dev"
        #expect(flow.confirmationReason.contains("from old.example.dev"))
        #expect(flow.confirmationReason.contains("onto new.example.dev"))
        #expect(flow.title.contains("onto new.example.dev"))
    }
}
