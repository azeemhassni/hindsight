import Foundation
import HindsightCatalog
import HindsightCore
import HindsightProtocol
import Testing
@testable import HindsightAgentKit
@testable import HindsightEngine

/// What the agent's request surface promises, checked without any XPC.
@Suite("Agent wiring")
struct AgentWiringTests {
    @Test("a restore command carries everything the agent needs to refuse it")
    func restoreCommandIsSelfContained() throws {
        let command = RestoreCommand(
            serverID: "web-01",
            snapshotID: "aa11bb22",
            paths: ["/srv/app"],
            targetPath: nil,
            mode: "standard",
            typedHostname: "web-01.example.com",
            optedInExclusions: ["bootloader"]
        )
        let decoded = try AgentCoding.decode(
            RestoreCommand.self,
            from: try AgentCoding.encode(command)
        )
        #expect(decoded == command)
        // The typed hostname travels with the command so the agent, not the
        // app, is what checks it.
        #expect(decoded.typedHostname == "web-01.example.com")
    }

    @Test("a preview report counts the changes a person has to weigh")
    func previewReportSummarises() {
        let report = RestorePreviewReport(
            changes: [
                RestoreChange(path: "/srv/a", kind: "added"),
                RestoreChange(path: "/srv/b", kind: "modified"),
                RestoreChange(path: "/srv/c", kind: "removed"),
                RestoreChange(path: "/srv/d", kind: "removed"),
                RestoreChange(path: "/srv/e", kind: "metadata"),
            ],
            safetySnapshotID: "ffee",
            bytesAdded: 2048,
            bytesRemoved: 512
        )
        #expect(report.addedCount == 1)
        #expect(report.modifiedCount == 1)
        #expect(report.removedCount == 2)
        #expect(report.safetySnapshotID == "ffee")
    }

    @Test("a settings update carries only what changed")
    func settingsUpdateIsSparse() throws {
        var update = ServerSettingsUpdate(serverID: "web-01")
        update.keepDaily = 14
        update.bandwidthLimitKiB = 2048

        let decoded = try AgentCoding.decode(
            ServerSettingsUpdate.self,
            from: try AgentCoding.encode(update)
        )
        #expect(decoded.keepDaily == 14)
        // Everything untouched stays nil, so applying an update cannot reset a
        // setting the person did not open.
        #expect(decoded.keepWeekly == nil)
        #expect(decoded.cadence == nil)
        #expect(decoded.bandwidthLimitKiB == 2048)
    }

    @Test("a cadence survives the round trip through the settings update")
    func cadenceRoundTrips() throws {
        var update = ServerSettingsUpdate(serverID: "web-01")
        update.cadence = try JSONEncoder().encode(Cadence.everyHours(12))

        let decoded = try AgentCoding.decode(
            ServerSettingsUpdate.self,
            from: try AgentCoding.encode(update)
        )
        let cadence = try JSONDecoder().decode(Cadence.self, from: try #require(decoded.cadence))
        #expect(cadence == .everyHours(12))
    }

    @Test("user excludes are stored and replaced, never duplicated")
    func userExcludesRoundTrip() throws {
        let catalog = try Catalog.inMemory()
        let server = try Server(
            id: try ServerID(validating: "web-01"),
            name: "Web 01",
            endpoint: try SSHEndpoint(host: "198.51.100.10", user: "root"),
            authentication: .managedKey,
            privilege: .root
        )
        try catalog.save(server)

        try catalog.replaceUserExcludes(["/var/log/*.log", "/srv/cache"], forServer: server.id)
        #expect(try catalog.userExcludes(forServer: server.id) == ["/var/log/*.log", "/srv/cache"])

        // Replacing is replacing, not appending.
        try catalog.replaceUserExcludes(["/srv/cache"], forServer: server.id)
        #expect(try catalog.userExcludes(forServer: server.id) == ["/srv/cache"])

        // Blank entries are dropped rather than stored as patterns that match
        // nothing.
        try catalog.replaceUserExcludes(["  ", "/opt/tmp"], forServer: server.id)
        #expect(try catalog.userExcludes(forServer: server.id) == ["/opt/tmp"])
    }

    @Test("notification text is trimmed to something readable at a glance")
    func notificationTextIsShort() {
        let long = String(repeating: "a very long error message ", count: 40)
        let trimmed = Notifier.firstLine(of: long)
        #expect(trimmed.count <= 180)
        #expect(trimmed.hasSuffix("…"))

        // Only the first line: a Swift error description can be a whole shell
        // script.
        #expect(Notifier.firstLine(of: "first line\nsecond line") == "first line")
    }
}
