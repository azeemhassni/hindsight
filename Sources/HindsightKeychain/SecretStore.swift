import Foundation
import HindsightCore

/// Names of the secrets Hindsight keeps.
///
/// A closed set rather than free-form strings, so a typo cannot silently
/// create a second, empty secret where one was expected.
public enum SecretKey: Hashable, Sendable {
    case repositoryPassword(ServerID)
    case restServerCredential(ServerID)
    case sshPrivateKey(ServerID)
    case coolifyToken(ServerID)

    public var account: String {
        switch self {
        case let .repositoryPassword(id): "repo-password/\(id.value)"
        case let .restServerCredential(id): "rest-credential/\(id.value)"
        case let .sshPrivateKey(id): "ssh-key/\(id.value)"
        case let .coolifyToken(id): "coolify-token/\(id.value)"
        }
    }

    public var label: String {
        switch self {
        case let .repositoryPassword(id): "Hindsight repository password for \(id.value)"
        case let .restServerCredential(id): "Hindsight transfer credential for \(id.value)"
        case let .sshPrivateKey(id): "Hindsight SSH key for \(id.value)"
        case let .coolifyToken(id): "Hindsight Coolify token for \(id.value)"
        }
    }
}

public enum SecretStoreError: Error, Hashable, Sendable, CustomStringConvertible {
    case notFound(account: String)
    case keychainFailure(account: String, status: Int32)
    case notUTF8(account: String)

    public var description: String {
        switch self {
        case let .notFound(account):
            """
            \(account) is not in the Keychain. If this is a repository \
            password, the backups it protects cannot be read without it — \
            restore it from the recovery kit.
            """
        case let .keychainFailure(account, status):
            "The Keychain refused access to \(account) (status \(status))."
        case let .notUTF8(account):
            "The Keychain item \(account) is not text."
        }
    }
}

public protocol SecretStore: Sendable {
    func read(_ key: SecretKey) throws -> Secret
    func contains(_ key: SecretKey) -> Bool
    func write(_ value: String, for key: SecretKey) throws
    func delete(_ key: SecretKey) throws
}

extension SecretStore {
    /// Returns the existing secret, or generates and stores one.
    ///
    /// Used for repository passwords, which Hindsight generates: a person
    /// should never have to invent one, and it should never be weak.
    public func readOrCreate(_ key: SecretKey, generator: () -> String = { Self.randomPassword() }) throws -> Secret {
        if contains(key) { return try read(key) }
        let value = generator()
        try write(value, for: key)
        return Secret(label: key.account, value: value)
    }

    public static func randomPassword(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }
}

/// An in-memory store, for tests and previews. Never used by the app or agent.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init(_ initial: [SecretKey: String] = [:]) {
        for (key, value) in initial { values[key.account] = value }
    }

    public func read(_ key: SecretKey) throws -> Secret {
        lock.lock()
        defer { lock.unlock() }
        guard let value = values[key.account] else {
            throw SecretStoreError.notFound(account: key.account)
        }
        return Secret(label: key.account, value: value)
    }

    public func contains(_ key: SecretKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return values[key.account] != nil
    }

    public func write(_ value: String, for key: SecretKey) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key.account] = value
    }

    public func delete(_ key: SecretKey) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key.account] = nil
    }
}
