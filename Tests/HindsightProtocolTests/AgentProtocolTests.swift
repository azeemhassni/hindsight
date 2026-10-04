import Foundation
import Testing
@testable import HindsightProtocol

@Suite("Agent protocol")
struct AgentProtocolTests {
    @Test("round-trips every request")
    func roundTripsRequests() throws {
        let requests: [AgentRequest] = [
            .status,
            .backUpNow(serverID: "web-01"),
            .cancelJob(jobID: "job-1"),
            .reloadSchedules,
            .runMaintenance(serverID: "web-01"),
            .checkIntegrity(serverID: "web-01"),
        ]
        for request in requests {
            let data = try AgentCoding.encode(request)
            #expect(try AgentCoding.decode(AgentRequest.self, from: data) == request)
        }
    }

    @Test("round-trips a status with dates intact")
    func roundTripsStatus() throws {
        let status = AgentStatus(
            version: "0.1.0",
            servers: [
                ServerStatus(
                    id: "web-01",
                    name: "Web 01",
                    health: .healthy,
                    lastBackupAt: Date(timeIntervalSince1970: 1_800_000_000),
                    nextBackupAt: Date(timeIntervalSince1970: 1_800_003_600),
                    scheduleExplanation: "Not due yet.",
                    lastCheckPassed: true
                ),
            ],
            runningJobs: []
        )
        let response = try AgentCoding.decode(
            AgentResponse.self,
            from: try AgentCoding.encode(AgentResponse.status(status))
        )
        guard case let .status(roundTripped) = response else {
            Issue.record("expected a status")
            return
        }
        #expect(roundTripped == status)
        #expect(roundTripped.servers[0].lastBackupAt == status.servers[0].lastBackupAt)
    }

    @Test("summarises what the menu bar needs")
    func summarisesForMenuBar() {
        let status = AgentStatus(
            version: "0.1.0",
            servers: [
                ServerStatus(
                    id: "a", name: "A", health: .healthy,
                    lastBackupAt: Date(timeIntervalSince1970: 100),
                    nextBackupAt: Date(timeIntervalSince1970: 900),
                    scheduleExplanation: "", lastCheckPassed: true
                ),
                ServerStatus(
                    id: "b", name: "B", health: .failing,
                    lastBackupAt: Date(timeIntervalSince1970: 300),
                    nextBackupAt: Date(timeIntervalSince1970: 500),
                    scheduleExplanation: "", lastCheckPassed: false
                ),
            ],
            runningJobs: []
        )
        #expect(status.lastBackupAt == Date(timeIntervalSince1970: 300))
        #expect(status.nextBackupAt == Date(timeIntervalSince1970: 500))
        #expect(status.hasFailures)
    }

    @Test("round-trips events")
    func roundTripsEvents() throws {
        let events: [AgentEvent] = [
            .jobStarted(RunningJob(id: "1", serverID: "web-01", kind: "backup", startedAt: Date(timeIntervalSince1970: 1))),
            .jobProgress(RunningJob(
                id: "1", serverID: "web-01", kind: "backup",
                startedAt: Date(timeIntervalSince1970: 1),
                percentDone: 0.5, bytesDone: 10, totalBytes: 20
            )),
            .jobFinished(id: "1", serverID: "web-01", succeeded: false, message: "boom"),
            .catalogChanged,
            .integrityProblem(serverID: "web-01", message: "pack damaged"),
        ]
        for event in events {
            let data = try AgentCoding.encode(event)
            #expect(try AgentCoding.decode(AgentEvent.self, from: data) == event)
        }
    }

    @Test("builds a code-signing requirement that names the team")
    func buildsCodeSigningRequirement() {
        let requirement = ConnectionSecurity.codeSigningRequirement(teamIdentifier: "ABCDE12345")
        #expect(requirement.contains("ABCDE12345"))
        #expect(requirement.contains("anchor apple generic"))
        #expect(requirement.contains("app.hindsight"))
    }
}
