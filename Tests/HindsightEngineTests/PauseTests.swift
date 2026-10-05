import Foundation
import HindsightCatalog
import HindsightCore
import HindsightKeychain
import HindsightProtocol
import Testing
@testable import HindsightAgentKit

/// Pausing a server.
///
/// A paused server takes no scheduled backups. The schedule itself is left
/// alone, so resuming brings back exactly what was there rather than a default.
@Suite("Pausing a server")
struct PauseTests {
    private func makeCore() throws -> (AgentCore, Catalog, ServerID) {
        let catalog = try Catalog.inMemory()
        let id = try ServerID(validating: "web-01")
        try catalog.save(
            try Server(
                id: id,
                name: "Web 01",
                endpoint: try SSHEndpoint(host: "127.0.0.1", port: 2222, user: "root"),
                authentication: .managedKey,
                privilege: .root
            )
        )
        try catalog.save(
            RepositoryRecord(id: "repo-web-01", serverId: id.value, path: "/tmp/repo")
        )
        try catalog.save(
            ScheduleRecord(
                id: "schedule-web-01",
                serverId: id.value,
                schedule: try Schedule(cadence: .everyHours(6), onlyOnACPower: false),
                nextFireAt: nil,
                enabled: true
            )
        )
        let core = AgentCore(
            configuration: .fallback,
            catalog: catalog,
            secrets: InMemorySecretStore(),
            version: "test"
        )
        return (core, catalog, id)
    }

    @Test("a paused server reports itself as paused, with no next backup")
    func reportsPaused() async throws {
        let (core, _, id) = try makeCore()
        await core.start()
        #expect(await core.handle(.setPaused(serverID: id.value, paused: true)) == .done)

        guard case let .status(status) = await core.handle(.status),
              let server = status.servers.first
        else {
            Issue.record("expected a status")
            return
        }
        #expect(server.isPaused)
        #expect(server.nextBackupAt == nil)
        #expect(server.scheduleExplanation.contains("Paused"))
        await core.stop()
    }

    /// The point of the feature: nothing fires while it is paused.
    @Test("a paused server contributes no scheduled entries")
    func scheduleIsEmptyWhilePaused() async throws {
        let (core, catalog, id) = try makeCore()
        await core.start()
        #expect(await core.scheduledEntryCountForTesting() == 1)

        _ = await core.handle(.setPaused(serverID: id.value, paused: true))
        #expect(await core.scheduledEntryCountForTesting() == 0)

        // The schedule itself is untouched, so resuming restores it exactly.
        #expect(try catalog.schedules(forServer: id).first?.enabled == true)

        _ = await core.handle(.setPaused(serverID: id.value, paused: false))
        #expect(await core.scheduledEntryCountForTesting() == 1)
        await core.stop()
    }

    @Test("pausing twice keeps the time it was first paused")
    func pauseIsIdempotent() async throws {
        let (core, catalog, id) = try makeCore()
        _ = await core.handle(.setPaused(serverID: id.value, paused: true))
        let first = try catalog.server(id)?.pausedAt
        _ = await core.handle(.setPaused(serverID: id.value, paused: true))
        #expect(try catalog.server(id)?.pausedAt == first)
    }

    @Test("resuming clears it")
    func resumeClearsIt() async throws {
        let (core, catalog, id) = try makeCore()
        _ = await core.handle(.setPaused(serverID: id.value, paused: true))
        _ = await core.handle(.setPaused(serverID: id.value, paused: false))
        #expect(try catalog.server(id)?.isPaused == false)
    }

    @Test("refuses a server it does not have")
    func refusesUnknownServer() async throws {
        let (core, _, _) = try makeCore()
        guard case .failed = await core.handle(.setPaused(serverID: "nope", paused: true)) else {
            Issue.record("expected a refusal")
            return
        }
    }

    /// Pressing the button is a more recent instruction than pausing was.
    @Test("backing up by hand still works while paused")
    func manualBackupStillWorks() async throws {
        let (core, _, id) = try makeCore()
        await core.start()
        _ = await core.handle(.setPaused(serverID: id.value, paused: true))
        guard case .accepted = await core.handle(.backUpNow(serverID: id.value)) else {
            Issue.record("a manual backup should still be accepted while paused")
            return
        }
        await core.stop()
    }
}
