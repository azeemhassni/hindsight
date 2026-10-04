import Foundation
import HindsightCore
import HindsightRestic
import HindsightSSH

/// Everything a backup run needs, resolved before anything is started.
public struct BackupPlan: Sendable {
    public var server: Server
    public var destination: SSHDestination
    public var profile: BackupProfile
    /// The directory holding one repository subdirectory per server. This is
    /// what the local rest-server serves, and the server reaches its own
    /// repository under it by name.
    public var repositoryRoot: URL
    public var repositoryPassword: Secret
    public var extraTags: [SnapshotTag]
    public var includeMetadata: Bool
    /// Copying a live database file is not a backup, so every database found on
    /// the server also gets a logical dump as its own snapshot.
    public var includeDatabaseDumps: Bool
    /// Credentials for databases that cannot be reached through `docker exec`,
    /// keyed by `DatabaseTarget.identifier`. A container supplies its own
    /// through its environment and needs no entry here.
    public var databaseCredentials: [String: Secret]
    /// The repository's directory name inside the root. Defaults to the
    /// server's id, which is how onboarding names it.
    public var repositoryName: String

    public init(
        server: Server,
        destination: SSHDestination,
        profile: BackupProfile = .fullServer,
        repositoryRoot: URL,
        repositoryPassword: Secret,
        extraTags: [SnapshotTag] = [],
        includeMetadata: Bool = true,
        includeDatabaseDumps: Bool = true,
        databaseCredentials: [String: Secret] = [:],
        repositoryName: String? = nil
    ) {
        self.server = server
        self.destination = destination
        self.profile = profile
        self.repositoryRoot = repositoryRoot
        self.repositoryPassword = repositoryPassword
        self.extraTags = extraTags
        self.includeMetadata = includeMetadata
        self.includeDatabaseDumps = includeDatabaseDumps
        self.databaseCredentials = databaseCredentials
        self.repositoryName = repositoryName ?? server.id.value
    }

    /// Where this server's repository is.
    ///
    /// Taken from the catalog rather than assumed, because the location is
    /// chosen during onboarding: assuming it meant backups were written under
    /// Application Support while prune, check and restore worked on the empty
    /// directory the person had picked.
    public var repositoryURL: URL {
        repositoryRoot.appendingPathComponent(repositoryName)
    }

    public var tags: [SnapshotTag] {
        [.hindsight, .profile("full")] + extraTags
    }

    /// restic reads include paths from a file rather than argv: a server with
    /// many include rules would otherwise overrun the command length limit, and
    /// a path containing a newline is handled by `--files-from-verbatim`.
    public var includeFileContents: String {
        profile.includePaths.joined(separator: "\n") + "\n"
    }

    public var excludeFileContents: String {
        profile.excludePatterns.joined(separator: "\n") + "\n"
    }

    public func resticArguments(
        binaryPath: String,
        includeFile: String,
        excludeFile: String
    ) -> [String] {
        var arguments = [
            "backup",
            "--json",
            "--files-from-verbatim", includeFile,
            "--exclude-file", excludeFile,
            // An interrupted run can leave a lock behind; waiting beats failing
            // a scheduled backup outright.
            "--retry-lock", "5m",
        ]
        if profile.oneFileSystem {
            arguments.append("--one-file-system")
        }
        if profile.excludeCaches {
            arguments.append("--exclude-caches")
        }
        if let limit = profile.bandwidthLimitKiBPerSecond {
            arguments += ["--limit-upload", String(limit)]
        }
        for tag in tags {
            arguments += ["--tag", tag.rawValue]
        }
        _ = binaryPath
        return arguments
    }
}

public enum BackupPhase: String, Sendable, Hashable {
    case preparing
    case connecting
    case verifyingBinary
    case startingServer
    case openingTunnel
    case collectingMetadata
    case backingUp
    case dumpingDatabases
    case recording
    case finishing
}

public struct BackupProgress: Sendable, Hashable {
    public var percentDone: Double
    public var bytesDone: Int64?
    public var totalBytes: Int64?
    public var filesDone: Int?
    public var totalFiles: Int?
    public var secondsRemaining: Int?
    public var currentFiles: [String]

    init(_ status: ResticStatus) {
        percentDone = status.percentDone
        bytesDone = status.bytesDone
        totalBytes = status.totalBytes
        filesDone = status.filesDone
        totalFiles = status.totalFiles
        secondsRemaining = status.secondsRemaining
        currentFiles = status.currentFiles ?? []
    }
}

public enum BackupEvent: Sendable {
    case phase(BackupPhase)
    case databaseDumped(DatabaseDumpResult)
    case message(String)
    case warning(String)
    case progress(BackupProgress)
    case snapshotCreated(Snapshot)
    case finished(BackupOutcome)
}

public struct BackupOutcome: Sendable, Hashable {
    public var filesystemSnapshot: Snapshot?
    public var metadataSnapshot: Snapshot?
    public var databaseDumps: [DatabaseDumpResult] = []
    public var filesNew: Int
    public var filesChanged: Int
    public var filesUnmodified: Int
    public var bytesProcessed: Int64
    public var bytesAdded: Int64
    public var duration: Duration
    public var warnings: [String]
}
