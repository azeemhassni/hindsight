import Foundation
import Testing
@testable import HindsightCore

@Suite("Snapshot tags")
struct SnapshotTagTests {
    static let examples: [SnapshotTag] = [
        .hindsight,
        .safety,
        .profile("full"),
        .coolifyResource("b8c1f0e2-1111-2222-3333-444455556666"),
        .coolifyProject("acme"),
        .coolifyEnvironment("production"),
        .databaseEngine("postgres"),
        .databaseName("app_production"),
        .restore(JobID(unchecked: "job-1")),
    ]

    @Test("round-trips every tag through its raw value", arguments: examples)
    func roundTrips(_ tag: SnapshotTag) throws {
        let parsed = SnapshotTag(rawValue: tag.rawValue)
        #expect(parsed == tag, "\(tag.rawValue) did not round-trip")
    }

    @Test("uses the documented wire format")
    func wireFormat() {
        #expect(SnapshotTag.coolifyResource("abc").rawValue == "coolify:abc")
        #expect(SnapshotTag.databaseEngine("mysql").rawValue == "db:mysql")
        #expect(SnapshotTag.databaseName("shop").rawValue == "dbname:shop")
        #expect(SnapshotTag.profile("full").rawValue == "profile:full")
    }

    @Test("rejects malformed tags", arguments: ["", "coolify", "coolify:", "nonsense:value", ":value"])
    func rejectsMalformed(_ raw: String) {
        #expect(SnapshotTag(rawValue: raw) == nil)
    }

    @Test("a tag set can be queried with typed tags")
    func queriesTagSet() {
        let tags: Set<String> = ["hindsight", "coolify:abc"]
        #expect(tags.contains(.coolifyResource("abc")))
        #expect(tags.contains(.hindsight))
        #expect(!tags.contains(.coolifyResource("def")))
    }

    @Test("snapshots round-trip through Codable")
    func snapshotCodable() throws {
        let snapshot = Snapshot(
            id: try SnapshotID(validating: "deadbeefdeadbeef"),
            time: Date(timeIntervalSince1970: 1_760_000_000),
            hostname: "web-01",
            paths: ["/etc", "/home"],
            tags: [SnapshotTag.hindsight.rawValue, SnapshotTag.profile("full").rawValue],
            kind: .filesystem,
            sizeBytes: 1024,
            dataAddedBytes: 128
        )
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
    }
}
