import Foundation
import GRDB
import HindsightCore
import Testing
@testable import HindsightCatalog

@Suite("Catalog concurrency", .timeLimit(.minutes(1)))
struct CatalogConcurrencyTests {
    /// The agent writes while the app reads. With WAL this must never block or
    /// fail: a backup that aborts because a window was open would be absurd.
    @Test("readers never block the writer and never see SQLITE_BUSY")
    func readersDoNotBlockTheWriter() async throws {
        let url = temporaryCatalogURL()
        let catalog = try Catalog.open(at: url)
        let server = try makeServer()
        try catalog.save(server)
        try catalog.save(RepositoryRecord(id: "r1", serverId: server.id.value, path: "/tmp/repo"))

        let reader = try CatalogReader.open(at: url)
        let writes = 200

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<writes {
                    let snapshot = try makeSnapshot(
                        id: String(format: "%064x", index),
                        time: Date(timeIntervalSince1970: TimeInterval(index)),
                        tags: ["hindsight"]
                    )
                    try catalog.record(snapshot, inRepository: "r1")
                }
            }

            for _ in 0..<6 {
                group.addTask {
                    for _ in 0..<60 {
                        _ = try reader.read { database in
                            try SnapshotRecord.fetchCount(database)
                        }
                    }
                }
            }

            try await group.waitForAll()
        }

        #expect(try catalog.snapshots(inRepository: "r1").count == writes)
        let seenByReader = try reader.read { try SnapshotRecord.fetchCount($0) }
        #expect(seenByReader == writes)
    }

    @Test("a read-only catalog refuses to write")
    func readOnlyCannotWrite() throws {
        let url = temporaryCatalogURL()
        let catalog = try Catalog.open(at: url)
        try catalog.save(try makeServer())

        let reader = try CatalogReader.open(at: url)
        #expect(throws: (any Error).self) {
            try reader.read { database in
                try database.execute(sql: "DELETE FROM server")
            }
        }
        #expect(try catalog.servers().count == 1)
    }

    @Test("concurrent writers serialise instead of corrupting each other")
    func concurrentWritersSerialise() async throws {
        let url = temporaryCatalogURL()
        let catalog = try Catalog.open(at: url)
        let server = try makeServer()
        try catalog.save(server)
        let jobID = JobID.generate()
        try catalog.save(JobRecord(id: jobID, serverId: server.id, kind: .backup))

        try await withThrowingTaskGroup(of: Void.self) { group in
            for writer in 0..<8 {
                group.addTask {
                    for line in 0..<25 {
                        try catalog.append("writer \(writer) line \(line)", to: jobID)
                    }
                }
            }
            try await group.waitForAll()
        }

        let events = try catalog.events(for: jobID, limit: 10_000)
        #expect(events.count == 200)
        // Sequence numbers are allocated under the write lock, so they must be
        // a contiguous run with no duplicates.
        #expect(Set(events.map(\.sequence)).count == 200)
        #expect(events.map(\.sequence) == Array(1...200))
    }
}
