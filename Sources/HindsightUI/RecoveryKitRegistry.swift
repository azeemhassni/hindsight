import Foundation

/// Remembers which servers have had a recovery kit saved.
///
/// Not a secret and not state the agent needs, so it lives in the app's own
/// preferences. Its only purpose is to keep asking: a server whose password
/// exists nowhere but this Mac is one disk failure away from backups that
/// cannot be read, and that deserves to stay visible rather than be mentioned
/// once during setup.
public protocol RecoveryKitRegistry: Sendable {
    func wasExported(forServer id: String) -> Bool
    func markExported(forServer id: String)
}

/// `UserDefaults` is thread-safe but not `Sendable`, so the unchecked
/// conformance is the accurate description rather than a shortcut.
public struct DefaultsRecoveryKitRegistry: RecoveryKitRegistry, @unchecked Sendable {
    let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func wasExported(forServer id: String) -> Bool {
        defaults.bool(forKey: Self.key(id))
    }

    public func markExported(forServer id: String) {
        defaults.set(true, forKey: Self.key(id))
    }

    static func key(_ id: String) -> String { "recoveryKitExported.\(id)" }
}

/// For previews and tests.
public final class InMemoryRecoveryKitRegistry: RecoveryKitRegistry, @unchecked Sendable {
    private let lock = NSLock()
    private var exported: Set<String> = []

    public init(exported: Set<String> = []) {
        self.exported = exported
    }

    public func wasExported(forServer id: String) -> Bool {
        lock.withLock { exported.contains(id) }
    }

    public func markExported(forServer id: String) {
        lock.withLock { exported.insert(id) }
    }
}
