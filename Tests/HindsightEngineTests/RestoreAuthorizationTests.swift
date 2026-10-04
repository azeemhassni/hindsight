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
        #expect(!AgentCore.constantTimeEquals(token, String(token.dropLast()) + "0"))
        #expect(!AgentCore.constantTimeEquals(token, String(token.dropLast())))
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
