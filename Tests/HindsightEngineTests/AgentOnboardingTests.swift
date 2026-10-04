import Foundation
import HindsightCatalog
import HindsightCore
import HindsightKeychain
import Testing
@testable import HindsightAgentKit

@Suite("Server identifiers")
struct ServerIdentifierTests {
    /// A server id becomes a directory name, a rest-server username and an ssh
    /// alias, so what it accepts is a correctness property, not cosmetics.
    @Test(
        "turns a name into something usable as a path, a username and an alias",
        arguments: [
            ("Web 01", "web-01"),
            ("web-01", "web-01"),
            ("DB_Primary", "db-primary"),
            ("db.example.com", "db-example-com"),
            ("  spaced  out  ", "spaced-out"),
            ("Ünïcode Böx", "n-code-b-x"),
            ("///", "server-"),
        ]
    )
    func buildsIdentifiers(_ example: (String, String)) throws {
        let identifier = AgentCore.identifier(from: example.0)
        if example.1 == "server-" {
            // Nothing usable in the name, so one is generated rather than
            // producing an empty id.
            #expect(identifier.hasPrefix("server-"))
        } else {
            #expect(identifier == example.1)
        }
        // Whatever it produced must survive the validating initialiser, which
        // is what the rest of the system relies on.
        #expect(throws: Never.self) { try ServerID(validating: identifier) }
    }

    @Test("never produces an id too long for a socket path or a username")
    func clampsLength() throws {
        let identifier = AgentCore.identifier(from: String(repeating: "server", count: 40))
        #expect(identifier.count <= ServerID.maximumLength)
        #expect(throws: Never.self) { try ServerID(validating: identifier) }
    }

    @Test("never produces an id that starts or ends with a hyphen")
    func trimsHyphens() throws {
        for name in ["-leading", "trailing-", "--both--", "a//b"] {
            let identifier = AgentCore.identifier(from: name)
            #expect(throws: Never.self, "\(name) produced \(identifier)") {
                try ServerID(validating: identifier)
            }
        }
    }
}

@Suite("Unique server identifiers")
struct UniqueServerIdentifierTests {
    private func core(withServers names: [String]) throws -> AgentCore {
        let catalog = try Catalog.inMemory()
        for name in names {
            let id = try ServerID(validating: AgentCore.identifier(from: name))
            try catalog.save(
                try Server(
                    id: id,
                    name: name,
                    endpoint: try SSHEndpoint(host: "198.51.100.1", user: "root"),
                    authentication: .managedKey,
                    privilege: .root
                )
            )
        }
        return AgentCore(
            configuration: .fallback,
            catalog: catalog,
            secrets: InMemorySecretStore(),
            version: "test"
        )
    }

    @Test("two names that normalise the same get different ids")
    func avoidsCollisions() async throws {
        // Without this, adding "B x" after "Böx" would overwrite it, because
        // both normalise to the same id and the catalog upserts by primary key.
        let core = try core(withServers: ["Böx"])
        let identifier = try await core.uniqueIdentifier(for: "B x")
        #expect(identifier.value != AgentCore.identifier(from: "Böx"))
        #expect(identifier.value.hasSuffix("-2"))
    }

    @Test("an unused name keeps its natural id")
    func keepsNaturalIdentifier() async throws {
        let core = try core(withServers: [])
        #expect(try await core.uniqueIdentifier(for: "Web 01").value == "web-01")
    }

    @Test("a suffixed id is still valid for a path, a username and an alias")
    func suffixedIdentifiersStayValid() async throws {
        let core = try core(withServers: [String(repeating: "verylongname", count: 4)])
        let identifier = try await core.uniqueIdentifier(
            for: String(repeating: "verylongname", count: 4)
        )
        #expect(identifier.value.count <= ServerID.maximumLength)
        #expect(throws: Never.self) { try ServerID(validating: identifier.value) }
    }
}
