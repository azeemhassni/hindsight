import CryptoKit
import Foundation
import HindsightCore

/// Credentials for the bundled rest-server.
///
/// rest-server accepts `{SHA}` and bcrypt entries (verified in its
/// `htpasswd.go`). Hindsight writes `{SHA}`, which needs no dependency and no
/// external `htpasswd` binary — macOS ships none.
///
/// An unsalted digest is normally a poor choice, but this password is 256 bits
/// of fresh randomness generated per session, so there is nothing to guess. The
/// file is owner-only, the server listens on loopback, and the credential
/// unlocks exactly one repository path.
public struct RestServerCredential: Sendable {
    public let username: String
    public let password: Secret

    public init(username: String, password: Secret) {
        self.username = username
        self.password = password
    }

    public static func generate(username: String) -> RestServerCredential {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let value = Data(bytes).base64EncodedString()
        return RestServerCredential(
            username: username,
            password: Secret(label: "rest-server/\(username)", value: value)
        )
    }

    public var htpasswdLine: String {
        let digest = Insecure.SHA1.hash(data: Data(password.value.utf8))
        return "\(username):{SHA}\(Data(digest).base64EncodedString())"
    }

    /// The credential as it appears in a `rest:` URL. Percent-encoded because a
    /// base64 password contains `+` and `/`.
    public var urlUserInfo: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let user = username.addingPercentEncoding(withAllowedCharacters: allowed) ?? username
        let secret = password.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? password.value
        return "\(user):\(secret)"
    }

    public func write(to url: URL) throws {
        try Data((htpasswdLine + "\n").utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
