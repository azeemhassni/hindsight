public struct BackupProfile: Hashable, Sendable, Codable {
    public var includePaths: [String]
    public var excludePatterns: [String]
    /// Keeps a stray network mount or bind from silently enlarging a backup.
    public var oneFileSystem: Bool
    /// Mounts to traverse anyway, named explicitly, when `oneFileSystem` is on.
    public var extraMountPaths: [String]
    public var excludeCaches: Bool
    public var bandwidthLimitKiBPerSecond: Int?

    public init(
        includePaths: [String],
        excludePatterns: [String],
        oneFileSystem: Bool = true,
        extraMountPaths: [String] = [],
        excludeCaches: Bool = true,
        bandwidthLimitKiBPerSecond: Int? = nil
    ) throws {
        guard !includePaths.isEmpty else { throw ValidationError.emptyIncludePaths }
        for path in includePaths + extraMountPaths where !path.hasPrefix("/") {
            throw ValidationError.relativePath(path)
        }
        if let limit = bandwidthLimitKiBPerSecond, limit <= 0 {
            throw ValidationError.invalidBandwidthLimit(limit)
        }
        self.includePaths = includePaths
        self.excludePatterns = excludePatterns
        self.oneFileSystem = oneFileSystem
        self.extraMountPaths = extraMountPaths
        self.excludeCaches = excludeCaches
        self.bandwidthLimitKiBPerSecond = bandwidthLimitKiBPerSecond
    }

    public static let fullServerIncludePaths = [
        "/etc",
        "/root",
        "/home",
        "/opt",
        "/srv",
        "/usr/local",
        "/var/lib/docker/volumes",
        "/var/spool/cron",
        "/data",
    ]

    /// Docker image layers are excluded because images are re-pullable and
    /// their digests are recorded in the metadata snapshot.
    public static let fullServerExcludePatterns = [
        "/proc",
        "/sys",
        "/dev",
        "/run",
        "/tmp",
        "/var/tmp",
        "/var/cache",
        "/var/lib/docker/overlay2",
        "/var/lib/docker/image",
        "/var/lib/docker/buildkit",
        "/var/lib/docker/tmp",
        "/swapfile",
        "/swap.img",
        "**/lost+found",
    ]

    public static let fullServer = try! BackupProfile(
        includePaths: fullServerIncludePaths,
        excludePatterns: fullServerExcludePatterns
    )
}
