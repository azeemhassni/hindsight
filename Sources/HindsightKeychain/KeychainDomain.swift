import Foundation
import HindsightCore
import Security

/// Which keychain the secrets live in.
///
/// Two processes share one repository password, and how they share it decides
/// whether anyone is asked for permission:
///
/// - **Signed**: the data-protection keychain with a team-prefixed access
///   group. Both binaries carry the same `keychain-access-groups` entitlement,
///   macOS checks the team, and neither is prompted.
/// - **Unsigned**: the file-based login keychain, where access groups do not
///   apply and the item's own ACL decides. A second binary reading an item the
///   first one created raises a system prompt — which is exactly what a local
///   unsigned build does, and why it is worth naming rather than hiding.
public enum KeychainDomain: Sendable, Hashable {
    case dataProtection(accessGroup: String)
    case file

    /// Chosen from what this binary is actually entitled to.
    ///
    /// Asking for the data-protection keychain without a `keychain-access-groups`
    /// entitlement fails with -34018 — "the Keychain refused access" — which is
    /// what a build that assumed the entitlement did.
    public static var automatic: KeychainDomain {
        if let group = CodeIdentity.keychainAccessGroups.first {
            return .dataProtection(accessGroup: group)
        }
        return .file
    }

    var accessGroup: String? {
        switch self {
        case let .dataProtection(group): group
        case .file: nil
        }
    }

    public var usesDataProtection: Bool {
        switch self {
        case .dataProtection: true
        case .file: false
        }
    }

    /// Named in errors, because the same status means different things in each.
    public var name: String {
        switch self {
        case let .dataProtection(group): "data-protection keychain (group \(group))"
        case .file: "login keychain"
        }
    }

    public var explanation: String {
        switch self {
        case let .dataProtection(group):
            "Shared through the keychain access group \(group)."
        case .file:
            """
            Secrets live in the login keychain, readable by the agent that \
            created them. Any other process is asked for permission, which is \
            what stops one from reading them quietly.
            """
        }
    }
}
