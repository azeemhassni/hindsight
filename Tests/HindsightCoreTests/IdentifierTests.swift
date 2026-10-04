import Foundation
import Testing
@testable import HindsightCore

@Suite("Identifiers")
struct IdentifierTests {
    @Test("accepts a filesystem-safe server id")
    func acceptsValidServerID() throws {
        let id = try ServerID(validating: "web-01")
        #expect(id.value == "web-01")
        #expect(id.description == "web-01")
    }

    @Test(
        "rejects server ids that are unsafe as a path component or username",
        arguments: ["", "Web01", "web_01", "web 01", "-web", "web-", "../etc", "a/b", String(repeating: "a", count: 37)]
    )
    func rejectsUnsafeServerID(_ raw: String) {
        #expect(throws: (any Error).self) { try ServerID(validating: raw) }
    }

    @Test("generated server ids are valid")
    func generatedServerIDIsValid() throws {
        let generated = ServerID.generate()
        #expect(throws: Never.self) { try ServerID(validating: generated.value) }
    }

    @Test("accepts hexadecimal snapshot ids and abbreviates them")
    func acceptsSnapshotID() throws {
        let id = try SnapshotID(validating: "A1B2C3D4E5F60718")
        #expect(id.value == "a1b2c3d4e5f60718")
        #expect(id.short == "a1b2c3d4")
    }

    @Test("rejects non-hexadecimal snapshot ids", arguments: ["", "zzzz", "a1b2 c3", String(repeating: "a", count: 65)])
    func rejectsSnapshotID(_ raw: String) {
        #expect(throws: (any Error).self) { try SnapshotID(validating: raw) }
    }

    @Test("identifiers encode as plain strings")
    func encodesAsString() throws {
        let data = try JSONEncoder().encode(ServerID(unchecked: "web-01"))
        #expect(String(decoding: data, as: UTF8.self) == "\"web-01\"")
        let decoded = try JSONDecoder().decode(ServerID.self, from: data)
        #expect(decoded.value == "web-01")
    }
}
