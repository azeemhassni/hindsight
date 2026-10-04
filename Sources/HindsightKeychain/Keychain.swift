import Foundation
import HindsightCore
import Security

/// The real store: the login Keychain.
///
/// `kSecAttrAccessibleAfterFirstUnlock` is deliberate. The agent runs scheduled
/// backups without anyone present, so a secret that needs an unlocked screen
/// would mean backups silently stop whenever the Mac is left locked.
public struct Keychain: SecretStore {
    public let service: String
    /// Set so the app and the agent, signed by the same team, share items.
    /// Requires the keychain-access-groups entitlement; nil in unsigned builds.
    public let accessGroup: String?

    public init(service: String = "app.hindsight", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func baseQuery(_ key: SecretKey) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    public func read(_ key: SecretKey) throws -> Secret {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else {
            throw SecretStoreError.notFound(account: key.account)
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw SecretStoreError.keychainFailure(account: key.account, status: status)
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw SecretStoreError.notUTF8(account: key.account)
        }
        return Secret(label: key.account, value: value)
    }

    public func contains(_ key: SecretKey) -> Bool {
        var query = baseQuery(key)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public func write(_ value: String, for key: SecretKey) throws {
        let data = Data(value.utf8)

        if contains(key) {
            let status = SecItemUpdate(
                baseQuery(key) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard status == errSecSuccess else {
                throw SecretStoreError.keychainFailure(account: key.account, status: status)
            }
            return
        }

        var query = baseQuery(key)
        query[kSecValueData as String] = data
        query[kSecAttrLabel as String] = key.label
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecretStoreError.keychainFailure(account: key.account, status: status)
        }
    }

    public func delete(_ key: SecretKey) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychainFailure(account: key.account, status: status)
        }
    }
}
