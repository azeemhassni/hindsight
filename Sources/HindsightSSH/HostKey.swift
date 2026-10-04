import Foundation

public struct HostKey: Hashable, Sendable {
    public let host: String
    public let keyType: String
    public let base64Key: String
    /// The `SHA256:…` form OpenSSH shows, which is what the UI presents for
    /// confirmation.
    public let fingerprint: String

    public init(host: String, keyType: String, base64Key: String, fingerprint: String) {
        self.host = host
        self.keyType = keyType
        self.base64Key = base64Key
        self.fingerprint = fingerprint
    }

    /// One `known_hosts` line.
    public var knownHostsLine: String { "\(host) \(keyType) \(base64Key)" }

    /// Ordered by how much Hindsight prefers to pin them.
    public static let preferredKeyTypes = ["ssh-ed25519", "ecdsa-sha2-nistp256", "ssh-rsa"]

    public var preferenceRank: Int {
        Self.preferredKeyTypes.firstIndex(of: keyType) ?? Self.preferredKeyTypes.count
    }

    /// Parses a line of `ssh-keyscan` output. Comment and hash lines are not keys.
    public static func parse(keyscanLine line: String) -> HostKey? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        let fields = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 3 else { return nil }
        return HostKey(host: fields[0], keyType: fields[1], base64Key: fields[2], fingerprint: "")
    }

    /// Parses `ssh-keygen -l` output, which is `bits fingerprint comment (TYPE)`.
    public static func parseFingerprint(_ line: String) -> String? {
        line.split(separator: " ").map(String.init).first { $0.hasPrefix("SHA256:") }
    }

    public func withFingerprint(_ fingerprint: String) -> HostKey {
        HostKey(host: host, keyType: keyType, base64Key: base64Key, fingerprint: fingerprint)
    }
}
