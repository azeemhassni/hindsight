import Foundation
import HindsightCatalog
import HindsightCore
import HindsightKeychain
import HindsightProtocol
import Testing
@testable import HindsightAgentKit

/// Permission to write to a production server.
///
/// The typed hostname proves someone meant *this* server. The token proves
/// someone was at the Mac when they asked: the app only gets one after Touch
/// ID, or the login password. Both are checked here, in the process that does
/// the writing, rather than in the app that asks for it.
@Suite("Authorising a restore")
struct RestoreAuthorizationTests {
    private func makeCore() throws -> (AgentCore, Server) {
        let catalog = try Catalog.inMemory()
        let server = try Server(
            id: try ServerID(validating: "web-01"),
            name: "Web 01",
            endpoint: try SSHEndpoint(host: "127.0.0.1", port: 2222, user: "root"),
            authentication: .managedKey,
            privilege: .root
        )
        try catalog.save(server)
        try catalog.save(
            RepositoryRecord(id: "repo-web-01", serverId: server.id.value, path: "/tmp/repo")
        )
        let core = AgentCore(
            configuration: .fallback,
            catalog: catalog,
            secrets: InMemorySecretStore(),
            version: "test"
        )
        return (core, server)
    }

    private func command(authorization: String?) -> RestoreCommand {
        RestoreCommand(
            serverID: "web-01",
            snapshotID: "aa11bb22",
            paths: [],
            targetPath: nil,
            mode: "standard",
            typedHostname: "127.0.0.1",
            optedInExclusions: [],
            authorization: authorization
        )
    }

    @Test("refuses a restore that carries no authorisation")
    func refusesUnauthorised() async throws {
        let (core, _) = try makeCore()
        let response = await core.handle(.runRestore(command(authorization: nil)))
        guard case let .failed(message) = response else {
            Issue.record("expected a refusal, got \(response)")
            return
        }
        #expect(message.contains("Touch ID"))
    }

    @Test("refuses a token it never issued")
    func refusesForgedToken() async throws {
        let (core, _) = try makeCore()
        let response = await core.handle(.runRestore(command(authorization: "not-a-real-token")))
        guard case .failed = response else {
            Issue.record("expected a refusal, got \(response)")
            return
        }
    }

    @Test("accepts the token it just issued")
    func acceptsFreshToken() async throws {
        let (core, _) = try makeCore()
        let issued = await core.handle(.authorizeRestore(serverID: "web-01"))
        guard case let .restoreAuthorization(token, expiresAt) = issued else {
            Issue.record("expected an authorisation, got \(issued)")
            return
        }
        #expect(token.count == 64)
        #expect(expiresAt > Date())

        let response = await core.handle(.runRestore(command(authorization: token)))
        // Queued: the hostname matches and the token is good.
        guard case .accepted = response else {
            Issue.record("expected the restore to be accepted, got \(response)")
            return
        }
    }

    /// One authentication must not become a standing permission: a token that
    /// could be replayed would let anything that saw it overwrite a server.
    @Test("spends a token, so the same one cannot start a second restore")
    func refusesAReusedToken() async throws {
        let (core, _) = try makeCore()
        let issued = await core.handle(.authorizeRestore(serverID: "web-01"))
        guard case let .restoreAuthorization(token, _) = issued else {
            Issue.record("expected an authorisation, got \(issued)")
            return
        }
        _ = await core.handle(.runRestore(command(authorization: token)))

        let second = await core.handle(.runRestore(command(authorization: token)))
        guard case .failed = second else {
            Issue.record("a spent token must not authorise a second restore, got \(second)")
            return
        }
    }

    @Test("refuses a token that has expired, and says how long they last")
    func refusesAnExpiredToken() async throws {
        let (core, _) = try makeCore()
        let stale = Date().addingTimeInterval(-RestoreAuthorization.lifetime - 60)
        let issued = await core.issueRestoreAuthorization(serverID: "web-01", now: stale)
        guard case let .restoreAuthorization(token, _) = issued else {
            Issue.record("expected an authorisation, got \(issued)")
            return
        }

        let refusal = await core.refusalForRestoreAuthorization(command(authorization: token))
        #expect(refusal?.contains("expired") == true)
        #expect(refusal?.contains("2 minutes") == true)
    }

    @Test("a wrong token takes the same time to reject as a right one")
    func comparesTokensWithoutLeakingTheirShape() {
        let token = AgentCore.makeToken()
        #expect(AgentCore.constantTimeEquals(token, token))
        #expect(!AgentCore.constantTimeEquals(token, String(token.dropLast())))

        // Flipping the last character rather than setting it to a fixed one:
        // a token is hex, so one run in sixteen ended with that character
        // already and compared a token against itself. Found by the suite
        // failing on an unrelated change.
        let last = token.last ?? "0"
        let flipped = String(token.dropLast()) + (last == "0" ? "1" : "0")
        #expect(flipped != token)
        #expect(!AgentCore.constantTimeEquals(token, flipped))
    }

    @Test("every token is different")
    func issuesDistinctTokens() {
        let tokens = Set((0..<64).map { _ in AgentCore.makeToken() })
        #expect(tokens.count == 64)
    }

    @Test("a preview needs no authorisation, because it changes nothing")
    func previewNeedsNoAuthorisation() async throws {
        let (core, _) = try makeCore()
        let response = await core.handle(.previewRestore(command(authorization: nil)))
        // It fails for want of a repository on disk, not for want of permission.
        guard case let .failed(message) = response else { return }
        #expect(!message.contains("Touch ID"))
    }
}

/// Restoring one server's snapshot onto a different machine.
///
/// The source owns the repository and its password; the target owns the ssh
/// connection and the files being overwritten. Permission belongs to the
/// target, because the target is what changes.
@Suite("Restoring onto another server")
struct CrossServerRestoreTests {
    private func makeCore() throws -> AgentCore {
        let catalog = try Catalog.inMemory()
        for (id, host) in [("web-01", "127.0.0.1"), ("web-02", "127.0.0.2")] {
            let server = try Server(
                id: try ServerID(validating: id),
                name: id,
                endpoint: try SSHEndpoint(host: host, port: 2222, user: "root"),
                authentication: .managedKey,
                privilege: .root
            )
            try catalog.save(server)
        }
        // Only the source has a repository: the target is a machine to write
        // to, not somewhere backups are kept.
        try catalog.save(
            RepositoryRecord(id: "repo-web-01", serverId: "web-01", path: "/tmp/repo")
        )
        return AgentCore(
            configuration: .fallback,
            catalog: catalog,
            secrets: InMemorySecretStore(),
            version: "test"
        )
    }

    private func command(target: String?, authorization: String?) -> RestoreCommand {
        RestoreCommand(
            serverID: "web-01",
            targetServerID: target,
            snapshotID: "aa11bb22",
            paths: [],
            targetPath: nil,
            mode: "standard",
            typedHostname: "127.0.0.2",
            optedInExclusions: [],
            authorization: authorization
        )
    }

    @Test("resolves the repository from the source and the connection from the target")
    func resolvesBothEnds() async throws {
        let core = try makeCore()
        let ends = try await core.restoreEnds(for: command(target: "web-02", authorization: nil))

        #expect(ends.source.id.value == "web-01")
        #expect(ends.repository.path == "/tmp/repo")
        #expect(ends.target.id.value == "web-02")
        #expect(ends.target.endpoint.host == "127.0.0.2")
    }

    @Test("an ordinary restore has the same server at both ends")
    func defaultsToTheSourceServer() async throws {
        let core = try makeCore()
        let ends = try await core.restoreEnds(for: command(target: nil, authorization: nil))
        #expect(ends.source.id == ends.target.id)

        // Naming the source explicitly is the same thing.
        let named = try await core.restoreEnds(for: command(target: "web-01", authorization: nil))
        #expect(named.source.id == named.target.id)
    }

    @Test("refuses a target the agent does not know")
    func refusesAnUnknownTarget() async throws {
        let core = try makeCore()
        await #expect(throws: (any Error).self) {
            try await core.restoreEnds(for: command(target: "web-99", authorization: nil))
        }
    }

    @Test("a target with no repository of its own is still a valid target")
    func targetNeedsNoRepository() async throws {
        let core = try makeCore()
        let ends = try await core.restoreEnds(for: command(target: "web-02", authorization: nil))
        #expect(ends.target.id.value == "web-02")
    }

    /// The token says a person was at the Mac and meant to write to a
    /// particular machine. Permission to overwrite the server the snapshot
    /// came from must not become permission to overwrite a different one.
    @Test("permission for one machine is not permission for another")
    func permissionDoesNotTransfer() async throws {
        let core = try makeCore()

        // Authorised for the source, then aimed at the target.
        guard case let .restoreAuthorization(token, _) =
            await core.issueRestoreAuthorization(serverID: "web-01")
        else {
            Issue.record("expected a token")
            return
        }
        let refusal = await core.refusalForRestoreAuthorization(
            command(target: "web-02", authorization: token)
        )
        #expect(refusal != nil, "a token for web-01 must not authorise writing to web-02")
        #expect(refusal?.contains("not one this agent issued") == true)
    }

    @Test("a token issued for the target authorises the restore")
    func permissionForTheTargetWorks() async throws {
        let core = try makeCore()
        guard case let .restoreAuthorization(token, _) =
            await core.issueRestoreAuthorization(serverID: "web-02")
        else {
            Issue.record("expected a token")
            return
        }
        let refusal = await core.refusalForRestoreAuthorization(
            command(target: "web-02", authorization: token)
        )
        #expect(refusal == nil)
    }

    @Test("the machine written to is the target, and that is what is authorised")
    func writtenServerIsTheTarget() {
        #expect(command(target: "web-02", authorization: nil).writtenServerID == "web-02")
        #expect(command(target: nil, authorization: nil).writtenServerID == "web-01")
    }
}
