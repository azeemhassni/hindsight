import Foundation
import LocalAuthentication

/// Proof that the person is at the Mac.
///
/// Required before a restore, which is the only thing Hindsight does that
/// writes to a production server. A typed hostname proves someone meant *this*
/// server; this proves someone was there at all.
public protocol UserPresenceCheck: Sendable {
    /// `reason` is shown in the system prompt, so it says what is about to
    /// happen rather than "authenticate".
    func confirm(reason: String) async -> UserPresenceOutcome
}

public enum UserPresenceOutcome: Sendable, Hashable {
    case confirmed
    /// The person said no, or dismissed the prompt.
    case declined
    /// Nothing to ask with: no biometry, no password, no interactive session.
    case unavailable(String)

    public var isConfirmed: Bool { self == .confirmed }

    public var explanation: String? {
        switch self {
        case .confirmed:
            nil
        case .declined:
            "The restore was not confirmed, so nothing was changed on the server."
        case let .unavailable(reason):
            """
            This Mac could not ask for confirmation (\(reason)), and a restore \
            is not started without it.
            """
        }
    }
}

/// Touch ID, falling back to the login password.
///
/// `deviceOwnerAuthentication` is deliberate: a Mac without a fingerprint
/// sensor, or a finger that will not read, asks for the password instead of
/// locking someone out of their own restore.
public struct TouchIDPresence: UserPresenceCheck {
    public init() {}

    public func confirm(reason: String) async -> UserPresenceOutcome {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var problem: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else {
            return .unavailable(problem?.localizedDescription ?? "no authentication is available")
        }

        do {
            let confirmed = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            return confirmed ? .confirmed : .declined
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .systemCancel, .appCancel, .userFallback, .authenticationFailed:
                return .declined
            default:
                return .unavailable(error.localizedDescription)
            }
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }
}

/// For tests and previews.
public struct StubPresence: UserPresenceCheck {
    public let outcome: UserPresenceOutcome

    public init(_ outcome: UserPresenceOutcome = .confirmed) {
        self.outcome = outcome
    }

    public func confirm(reason: String) async -> UserPresenceOutcome { outcome }
}
