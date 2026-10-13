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

    /// Everything on the root filesystem, for making a bootable copy of a
    /// machine rather than keeping its data.
    ///
    /// The default profile deliberately leaves out the operating system: it
    /// keeps what cannot be reinstalled, and a package can always be
    /// reinstalled. That makes the backups far smaller and the restores far
    /// safer, but it also means a snapshot holds no kernel and no bootloader,
    /// so no disk image can be built from one. This profile exists for people
    /// who want that image and will pay several gigabytes a server for it.
    ///
    /// What stays excluded here is only what must be: kernel interfaces that
    /// are not files at all, and the mounted filesystems of running
    /// containers, whose contents belong to their images.
    public static let rootFilesystemExcludePatterns = [
        "/proc",
        "/sys",
        "/dev",
        "/run",
        "/tmp",
        "/var/tmp",
        "/var/cache/apt/archives",
        "/var/lib/docker/overlay2",
        "/var/lib/docker/image",
        "/var/lib/docker/buildkit",
        "/var/lib/docker/tmp",
        "/swapfile",
        "/swap.img",
        "/lost+found",
        "**/lost+found",
        // A machine's own backup of itself is not part of the machine.
        "/var/lib/hindsight",
    ]

    public static let rootFilesystem = try! BackupProfile(
        includePaths: ["/"],
        excludePatterns: rootFilesystemExcludePatterns
    )
}

/// Which of the two shapes of backup a server takes.
public enum BackupScope: String, Sendable, Hashable, Codable, CaseIterable {
    /// Configuration, data and container volumes. The default.
    case dataAndConfiguration
    /// The whole root filesystem, so a disk image can be built from it.
    case wholeRootFilesystem

    public var profile: BackupProfile {
        switch self {
        case .dataAndConfiguration: .fullServer
        case .wholeRootFilesystem: .rootFilesystem
        }
    }

    public var title: String {
        switch self {
        case .dataAndConfiguration: "Configuration and data"
        case .wholeRootFilesystem: "The whole root filesystem"
        }
    }

    public var explanation: String {
        switch self {
        case .dataAndConfiguration:
            """
            Keeps what cannot be reinstalled: /etc, home directories, /srv, \
            /opt, /data, container volumes and database dumps. Packages and \
            the operating system are left out, because they can be installed \
            again and the list of them is recorded separately.
            """
        case .wholeRootFilesystem:
            """
            Everything on the root filesystem, including the operating system \
            and installed packages. Several gigabytes more per server and a \
            much longer first backup, in exchange for a snapshot a bootable \
            disk image can be built from.
            """
        }
    }
}
