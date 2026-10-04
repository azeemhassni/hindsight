import Foundation

/// Locations of the ssh configuration Hindsight owns.
///
/// Hindsight never reads or writes the user's `~/.ssh`: a backup tool that
/// edits a person's own ssh setup is a tool that can break their access to
/// everything else.
public struct SSHPaths: Sendable, Hashable {
    /// The longest a Unix domain socket path may be on Darwin, including the
    /// terminating NUL.
    public static let socketPathLimit = 104

    public let configurationDirectory: URL
    public let preferredControlDirectory: URL

    public init(configurationDirectory: URL, preferredControlDirectory: URL) {
        self.configurationDirectory = configurationDirectory
        self.preferredControlDirectory = preferredControlDirectory
    }

    public static func standard(
        applicationSupport: URL? = nil,
        caches: URL? = nil
    ) -> SSHPaths {
        let support = applicationSupport
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let cache = caches
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return SSHPaths(
            configurationDirectory: support.appendingPathComponent("Hindsight/ssh"),
            preferredControlDirectory: cache.appendingPathComponent("Hindsight/cm")
        )
    }

    public var configFile: URL { configurationDirectory.appendingPathComponent("config") }
    public var knownHostsFile: URL { configurationDirectory.appendingPathComponent("known_hosts") }

    public func prepare() throws {
        for directory in [configurationDirectory, preferredControlDirectory] {
            try Self.createPrivateDirectory(at: directory)
        }
        if !FileManager.default.fileExists(atPath: knownHostsFile.path) {
            FileManager.default.createFile(atPath: knownHostsFile.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
    }

    /// Chooses where the connection-sharing socket lives.
    ///
    /// The preferred directory is inside the user's Caches. If a long home
    /// directory would push the socket past the kernel's path limit, fall back
    /// to a private directory under the system temporary directory, which is
    /// checked for ownership and mode before use.
    public func controlPath(forToken token: String) throws -> String {
        let preferred = preferredControlDirectory.appendingPathComponent(token).path
        if preferred.utf8.count < Self.socketPathLimit {
            return preferred
        }

        let fallbackDirectory = URL(fileURLWithPath: "/tmp/hindsight-\(getuid())")
        try Self.createPrivateDirectory(at: fallbackDirectory)
        try Self.verifyPrivateOwnership(of: fallbackDirectory)
        let fallback = fallbackDirectory.appendingPathComponent(token).path
        guard fallback.utf8.count < Self.socketPathLimit else {
            throw SSHError.controlPathTooLong(path: fallback, limit: Self.socketPathLimit)
        }
        return fallback
    }

    /// Creates a directory that is private from the moment it exists.
    ///
    /// `FileManager.createDirectory` creates first and applies permissions
    /// after, so there is a window where the directory is world-readable.
    /// `mkdir(2)` takes the mode atomically, which matters for a directory that
    /// holds connection-sharing sockets.
    static func createPrivateDirectory(at url: URL) throws {
        let parent = url.deletingLastPathComponent()
        if parent.path != "/", parent.path != url.path,
           !FileManager.default.fileExists(atPath: parent.path) {
            try createPrivateDirectory(at: parent)
        }

        if mkdir(url.path, 0o700) != 0 {
            let code = errno
            guard code == EEXIST else {
                throw SSHError.controlDirectoryUnsafe(
                    path: url.path,
                    reason: String(cString: strerror(code))
                )
            }
        }
    }

    /// A shared location such as `/tmp` can be pre-created by another user. A
    /// socket directory that someone else owns or can write to is a way into
    /// our connections, so refuse it rather than repair it.
    static func verifyPrivateOwnership(of url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let owner = attributes[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid() else {
            throw SSHError.controlDirectoryUnsafe(path: url.path, reason: "it is owned by another user")
        }
        guard let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.int16Value & 0o077 == 0
        else {
            throw SSHError.controlDirectoryUnsafe(path: url.path, reason: "it is accessible to other users")
        }
    }
}
