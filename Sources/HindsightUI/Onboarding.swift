import Foundation
import HindsightCore

/// The steps of adding a server, as a state machine.
///
/// Modelled separately from the views so the order, the gates, and above all
/// the rule that the recovery kit cannot be skipped are testable without
/// driving an interface.
public enum OnboardingStep: Int, Sendable, Hashable, CaseIterable, Comparable {
    case connectionDetails
    case confirmHostKey
    case checkPrivileges
    case detectServer
    case chooseRepository
    case firstBackup
    case exportRecoveryKit
    case done

    public static func < (lhs: OnboardingStep, rhs: OnboardingStep) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var title: String {
        switch self {
        case .connectionDetails: "Add a server"
        case .confirmHostKey: "Confirm the server's identity"
        case .checkPrivileges: "Check access"
        case .detectServer: "Look around the server"
        case .chooseRepository: "Choose where backups are kept"
        case .firstBackup: "First backup"
        case .exportRecoveryKit: "Save the recovery kit"
        case .done: "Ready"
        }
    }

    public var explanation: String {
        switch self {
        case .connectionDetails:
            "Where the server is, and which key to use."
        case .confirmHostKey:
            """
            Check this fingerprint against what the server shows. Confirming it \
            is what lets Hindsight notice later if the connection is being \
            intercepted.
            """
        case .checkPrivileges:
            """
            Backups need to read files that belong to root. Either connect as \
            root, or allow passwordless sudo for the few commands Hindsight \
            runs.
            """
        case .detectServer:
            "Which distribution, which architecture, Docker, Coolify, disks."
        case .chooseRepository:
            """
            Backups are kept on this Mac. An external disk is a good choice; \
            whatever you pick needs room to grow.
            """
        case .firstBackup:
            "The first run copies everything, so it takes the longest."
        case .exportRecoveryKit:
            """
            Save the repository password somewhere other than this Mac. \
            Without it the backups cannot be read, by anyone, ever.
            """
        case .done:
            "Hindsight will keep this server backed up on the schedule you chose."
        }
    }
}

public struct OnboardingState: Sendable, Hashable {
    public var step: OnboardingStep = .connectionDetails
    public var host: String = ""
    public var port: Int = 22
    public var user: String = "root"
    public var name: String = ""
    public var hostKeyFingerprint: String?
    public var hostKeyConfirmed = false
    public var privilegeMode: Privilege?
    public var sudoAvailable: Bool?
    public var detectedPlatform: Platform?
    public var detectedCoolifyVersion: String?
    public var repositoryPath: String?
    public var firstBackupCompleted = false
    public var recoveryKitExported = false

    public init() {}

    /// Whether the current step is satisfied. The wizard advances only when it
    /// is, so no step can be stepped over.
    public var canAdvance: Bool {
        switch step {
        case .connectionDetails:
            !host.trimmingCharacters(in: .whitespaces).isEmpty
                && !user.trimmingCharacters(in: .whitespaces).isEmpty
                && (1...65535).contains(port)
        case .confirmHostKey:
            hostKeyFingerprint != nil && hostKeyConfirmed
        case .checkPrivileges:
            privilegeMode != nil
        case .detectServer:
            detectedPlatform != nil
        case .chooseRepository:
            repositoryPath?.isEmpty == false
        case .firstBackup:
            firstBackupCompleted
        case .exportRecoveryKit:
            // The one step with no way past it. Losing the password means
            // losing the backups, so finishing without saving it would be
            // setting up a failure for later.
            recoveryKitExported
        case .done:
            true
        }
    }

    public var blockingReason: String? {
        guard !canAdvance else { return nil }
        switch step {
        case .connectionDetails: return "Enter a host, a user, and a port."
        case .confirmHostKey: return "Confirm the fingerprint to continue."
        case .checkPrivileges:
            if sudoAvailable == false {
                return """
                Passwordless sudo is not available for this user. Either \
                connect as root, or add the sudoers line shown above.
                """
            }
            return "Checking access…"
        case .detectServer: return "Still looking around the server…"
        case .chooseRepository: return "Choose where to keep this server's backups."
        case .firstBackup: return "The first backup has not finished yet."
        case .exportRecoveryKit:
            return """
            Save the recovery kit before finishing. Without it, these backups \
            cannot be read if this Mac is lost.
            """
        case .done: return nil
        }
    }

    public mutating func advance() {
        guard canAdvance, step != .done else { return }
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    public mutating func goBack() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        // Confirming a host key is not something to re-do by accident; going
        // back to it clears the confirmation so it has to be read again.
        if step == .checkPrivileges { hostKeyConfirmed = false }
        step = previous
    }

    public var suggestedName: String {
        name.isEmpty ? host : name
    }

    /// The sudoers line to paste, scoped to what Hindsight actually runs.
    public func sudoersLine(user: String, resticPath: String) -> String {
        """
        \(user) ALL=(root) NOPASSWD: \(resticPath), /bin/sh, /usr/bin/docker, \
        /usr/bin/sha256sum, /bin/rm, /bin/mv, /bin/mkdir, /usr/bin/test
        """
    }
}
