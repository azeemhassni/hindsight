import Foundation
import HindsightCore
import HindsightProtocol
import Testing
@testable import HindsightUI

@MainActor
@Suite("Model requests for resources, logs and settings")
struct AppModelRequestTests {
    private let tree = CoolifyTreeReport(
        resources: [
            CoolifyResourceReport(
                uuid: "q78pdwdw3qpsm2zdmyqfu6wf",
                name: "acme-db",
                kind: "database",
                projectName: "acme",
                environmentName: "production",
                engine: "postgresql",
                isRunning: true,
                volumeCount: 1,
                lastBackupAt: nil
            ),
        ],
        source: "containerLabels",
        sourceExplanation: "Read from container labels.",
        coolifyVersion: "4.3.23",
        mayBeIncomplete: false
    )

    @Test("keeps a discovered tree per server")
    func keepsTreePerServer() async {
        let model = AppModel()
        model.send = { request in
            guard case .discoverCoolify = request else { return .done }
            return .coolifyTree(self.tree)
        }
        await model.discoverCoolify(serverID: "web-01")
        #expect(model.coolify["web-01"]?.resources.count == 1)
        #expect(model.coolify["db-01"] == nil)
        // The spinner has to stop whatever happened.
        #expect(!model.discoveringCoolify.contains("web-01"))
    }

    @Test("a discovery failure is reported rather than leaving an empty tab")
    func reportsDiscoveryFailure() async {
        let model = AppModel()
        model.send = { _ in .failed(message: "ssh: connect to host port 22: Connection refused") }
        await model.discoverCoolify(serverID: "web-01")
        #expect(model.coolify["web-01"] == nil)
        #expect(model.lastError?.contains("Connection refused") == true)
        #expect(model.activity.last?.level == .error)
    }

    @Test("asks for one resource rather than the whole server")
    func backsUpOneResource() async {
        let model = AppModel()
        var sent: [AgentRequest] = []
        model.send = { request in
            sent.append(request)
            if case .backUpResource = request { return .accepted(jobID: "job-9") }
            return .status(AgentStatus(version: "test", servers: [], runningJobs: []))
        }
        await model.backUpResource(serverID: "web-01", resourceUUID: "abc")

        #expect(sent.contains { request in
            if case let .backUpResource(serverID, uuid) = request {
                serverID == "web-01" && uuid == "abc"
            } else {
                false
            }
        })
        #expect(model.activity.last?.jobID == "job-9")
    }

    @Test("keeps each run's log under its own job")
    func keepsLogsPerJob() async {
        let model = AppModel()
        model.send = { request in
            switch request {
            case .jobHistory:
                return .jobs([
                    JobReport(
                        id: "job-1",
                        kind: "backup",
                        state: "succeeded",
                        queuedAt: Date(),
                        startedAt: Date(),
                        finishedAt: Date(),
                        bytesProcessed: 10,
                        bytesAdded: 5,
                        filesNew: 1,
                        filesChanged: 0,
                        errorText: nil,
                        resourceUUID: nil
                    ),
                ])
            case let .jobLog(jobID):
                return .jobLog([
                    JobLogLine(sequence: 1, at: Date(), level: "info", message: "phase: \(jobID)"),
                ])
            default:
                return .done
            }
        }
        await model.loadJobs(serverID: "web-01")
        await model.loadLog(jobID: "job-1")
        #expect(model.jobs["web-01"]?.count == 1)
        #expect(model.jobLogs["job-1"]?.first?.message == "phase: job-1")
        #expect(model.jobLogs["job-2"] == nil)
    }

    @Test("remembers which jobs finished, so onboarding can wait on one")
    func recordsFinishedJobs() {
        let model = AppModel()
        model.apply(.jobFinished(id: "job-1", serverID: "web-01", succeeded: true, message: nil))
        model.apply(.jobFinished(id: "job-2", serverID: "web-01", succeeded: false, message: "nope"))
        #expect(model.finishedJobs["job-1"] == true)
        #expect(model.finishedJobs["job-2"] == false)
    }

    @Test("builds a settings form from what the agent reports")
    func buildsSettingsFlow() async {
        let model = AppModel()
        let report = ServerSettingsReport(
            serverID: "web-01",
            cadence: try? JSONEncoder().encode(Cadence.dailyAt(try! TimeOfDay(hour: 3, minute: 30))),
            onlyOnACPower: true,
            keepWithinHours: 48,
            keepDaily: 7,
            keepWeekly: 4,
            keepMonthly: 6,
            keepYearly: 1,
            excludePatterns: ["/srv/cache"],
            bandwidthLimitKiB: 1024,
            checkRotationDivisor: 8,
            repositoryPath: "/Volumes/Backups/web-01",
            coolifyTokenIsSet: true
        )
        model.send = { _ in .settings(report) }

        let fetched = await model.serverSettings(serverID: "web-01")
        let flow = SettingsFlow.from(try! #require(fetched), model: model)
        #expect(flow.onlyOnACPower)
        #expect(flow.retention.keepDaily == 7)
        #expect(flow.bandwidthLimitKiB == 1024)
        #expect(flow.excludePatterns == ["/srv/cache"])
        #expect(flow.repositoryPath == "/Volumes/Backups/web-01")
        // A stored token is shown as a placeholder, never read back.
        #expect(flow.coolifyToken == SettingsFlow.tokenPlaceholder)
        // Nothing has been edited, so saving must be a no-op.
        #expect(!flow.hasChanges)
    }
}
