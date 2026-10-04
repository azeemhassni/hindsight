import Foundation
import Security

/// Who this process is, according to its own code signature.
///
/// Used instead of a compiled-in or configured team identifier: the keychain
/// access group and the XPC peer requirement both embed the team, and reading
/// it from the running binary means a build signed with a different identity
/// pins itself to that identity rather than to a stale constant.
public enum CodeIdentity {
    /// The team identifier of the running process, or nil when it is unsigned
    /// or signed ad-hoc — which is what a local build without an identity is.
    public static let teamIdentifier: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }

        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any]
        else { return nil }

        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        return team?.isEmpty == false ? team : nil
    }()

    public static var isSigned: Bool { teamIdentifier != nil }

    /// A hash of this process's own code, as macOS computes it.
    ///
    /// Used to tell one build from another: after an update the app's bundle
    /// holds a new agent while launchd is still running the old one, and the
    /// two are otherwise indistinguishable — same path, same version string.
    public static let binaryIdentity: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode
        else { return nil }
        return identity(ofStaticCode: staticCode)
    }()

    /// The same hash, for a bundle or executable on disk.
    public static func binaryIdentity(ofBundleAt url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }
        return identity(ofStaticCode: staticCode)
    }

    private static func identity(ofStaticCode staticCode: SecStaticCode) -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let unique = dictionary[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    /// The keychain access groups this process is actually entitled to.
    ///
    /// Read from the signature rather than assumed from the team identifier:
    /// asking for a group without the entitlement fails with -34018, and a
    /// build signed without one is the normal case here — the agent is the only
    /// process that touches secrets, so it shares nothing.
    public static let keychainAccessGroups: [String] = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return [] }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode
        else { return [] }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let groups = entitlements["keychain-access-groups"] as? [String]
        else { return [] }
        return groups
    }()
}
