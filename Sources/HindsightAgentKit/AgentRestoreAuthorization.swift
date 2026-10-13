import Foundation
import HindsightCore
import HindsightProtocol

/// Permission to write to a server.
///
/// A restore is the one thing Hindsight does that changes a production server,
/// so it takes two independent things to start one: the server's hostname,
/// typed out and checked here rather than in the app, and a token this agent
/// issued moments earlier. The app only gets a token after the person has
/// proved they are present — Touch ID, or the login password.
///
/// Single-use and short-lived on purpose. A token that could be replayed would
/// turn one authentication into a standing permission to overwrite a server.
struct RestoreAuthorization: Sendable, Hashable {
    var token: String
    var expiresAt: Date

    static let lifetime: TimeInterval = 120

    func isValid(now: Date = Date()) -> Bool { now < expiresAt }
}

extension AgentCore {
    func issueRestoreAuthorization(serverID: String, now: Date = Date()) -> AgentResponse {
        guard let id = try? ServerID(validating: serverID),
              (try? catalog.server(id)) != nil
        else { return .failed(message: "No server with id \(serverID).") }

        let authorization = RestoreAuthorization(
            token: Self.makeToken(),
            expiresAt: now.addingTimeInterval(RestoreAuthorization.lifetime)
        )
        restoreAuthorizations[id.value] = authorization
        return .restoreAuthorization(
            token: authorization.token,
            expiresAt: authorization.expiresAt
        )
    }

    /// Checks a token and spends it. Returns nil when it is good; otherwise the
    /// reason, in words a person can act on.
    func refusalForRestoreAuthorization(
        _ command: RestoreCommand,
        now: Date = Date()
    ) -> String? {
        guard let offered = command.authorization, !offered.isEmpty else {
            return """
            This restore was not authorised. Confirm it with Touch ID or your \
            login password, which is what tells the agent a person asked for it.
            """
        }
        // Keyed by the machine being written to, not the one the snapshot came
        // from. For a restore onto a replacement server those differ, and
        // permission for one must never be permission for the other.
        guard let held = restoreAuthorizations[command.writtenServerID] else {
            return "That authorisation is not one this agent issued. Try the restore again."
        }
        // Spent either way: a token offered once is finished, right or wrong.
        restoreAuthorizations[command.writtenServerID] = nil

        guard held.isValid(now: now) else {
            return """
            That authorisation has expired. Confirm the restore again — \
            permission to write to a server lasts \
            \(Int(RestoreAuthorization.lifetime / 60)) minutes.
            """
        }
        guard Self.constantTimeEquals(held.token, offered) else {
            return "That authorisation is not one this agent issued. Try the restore again."
        }
        return nil
    }

    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Compared without an early exit, so the time taken says nothing about
    /// how much of the token was right.
    static func constantTimeEquals(_ left: String, _ right: String) -> Bool {
        let a = Array(left.utf8)
        let b = Array(right.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<a.count {
            difference |= a[index] ^ b[index]
        }
        return difference == 0
    }
}
