import Foundation
import HindsightCore
import HindsightProcess
import HindsightRestic
import HindsightSSH

public enum RestorePhase: String, Sendable, Hashable {
    case planning
    case takingSafetySnapshot
    case preparingPreview
    case awaitingConfirmation
    case stopping
    case restoring
    case swapping
    case starting
    case verifying
    case finished
}

public struct RestorePreview: Sendable, Hashable {
    public struct Change: Sendable, Hashable {
        public enum Kind: String, Sendable, Hashable {
            case added
            case removed
            case modified
            case metadata
        }

        public var path: String
        public var kind: Kind
    }

    public var changes: [Change]
    public var safetySnapshotID: SnapshotID
    public var bytesAdded: Int64
    public var bytesRemoved: Int64

    public var added: [Change] { changes.filter { $0.kind == .added } }
    public var removed: [Change] { changes.filter { $0.kind == .removed } }
    public var modified: [Change] { changes.filter { $0.kind == .modified } }

    public var isEmpty: Bool { changes.isEmpty }

    /// Built from restic's own diff between the safety snapshot and the source,
    /// which is why it is exact rather than an estimate.
    public init(
        changes: [Change],
        safetySnapshotID: SnapshotID,
        bytesAdded: Int64,
        bytesRemoved: Int64
    ) {
        self.changes = changes
        self.safetySnapshotID = safetySnapshotID
        self.bytesAdded = bytesAdded
        self.bytesRemoved = bytesRemoved
    }

    static func kind(forModifier modifier: String) -> Change.Kind {
        // restic's modifiers: + added, - removed, M content changed,
        // U/T/P metadata changed.
        if modifier.contains("+") { return .added }
        if modifier.contains("-") { return .removed }
        if modifier.contains("M") { return .modified }
        return .metadata
    }
}

public enum RestoreEvent: Sendable {
    case phase(RestorePhase)
    case message(String)
    case warning(String)
    case preview(RestorePreview)
    case downtimeStarted
    case downtimeEnded(Duration)
    case finished(RestoreOutcome)
}

public struct RestoreOutcome: Sendable, Hashable {
    public var mode: RestoreMode
    public var safetySnapshotID: SnapshotID?
    public var filesRestored: Int
    public var downtime: Duration?
    public var warnings: [String]
}

public enum RestoreExecutionError: Error, Hashable, Sendable, CustomStringConvertible {
    case notAuthorized(String)
    case modeUnavailable(RestoreMode, reason: String)
    case nothingToRestore
    case stagingFailed(details: String)
    case verificationFailed(details: String)

    public var description: String {
        switch self {
        case let .notAuthorized(reason):
            reason
        case let .modeUnavailable(mode, reason):
            "\(mode.title) is not available for this restore: \(reason)"
        case .nothingToRestore:
            "The snapshot contains nothing for the selected paths."
        case let .stagingFailed(details):
            "Could not stage the restored data: \(details)"
        case let .verificationFailed(details):
            "The restore finished but did not verify: \(details)"
        }
    }
}

/// Performs a restore.
///
/// Every restore starts by snapshotting exactly what it is about to overwrite.
/// That snapshot is both the preview's baseline — restic can diff two snapshots
/// but not a snapshot against a live filesystem — and the way back if the
/// restore turns out to be the wrong one.
public struct RestoreExecutor: Sendable {
    public let client: SSHClient
    public let binaryStore: BinaryStore
    public let locks: RepositoryLockManager
    public let policy: DestructiveOperationPolicy

    public init(
        client: SSHClient,
        binaryStore: BinaryStore,
        locks: RepositoryLockManager = .shared,
        policy: DestructiveOperationPolicy
    ) {
        self.client = client
        self.binaryStore = binaryStore
        self.locks = locks
        self.policy = policy
    }

    /// Snapshots what the restore is about to overwrite, then diffs it against
    /// the source to produce an exact preview.
    public func prepare(
        plan: RestorePlan,
        paths: [String],
        session: RestoreSession,
        local: ResticClient
    ) async throws -> RestorePreview {
        guard !paths.isEmpty else { throw RestoreExecutionError.nothingToRestore }
        try RestoreSafety.check(plan: plan, pathsToWrite: paths)

        let safetyTags: [SnapshotTag] = [.hindsight, .safety, .restore(session.jobID)]
        var arguments = ["backup", "--json", "--retry-lock", "5m"]
        for tag in safetyTags { arguments += ["--tag", tag.rawValue] }
        arguments += paths

        let result = try await client.run(
            RemoteCommand(
                executable: session.remoteResticPath,
                arguments: arguments,
                secretEnvironment: [
                    "RESTIC_REPOSITORY": session.repositorySecret,
                    "RESTIC_PASSWORD": session.repositoryPassword,
                ],
                requiresRoot: true
            ),
            on: session.destination,
            timeout: .seconds(3600)
        )

        var safetyID: SnapshotID?
        for line in result.standardOutputLines.reversed() {
            if case let .summary(summary) = ResticMessage.decode(line: line) {
                safetyID = summary.snapshotID.map { SnapshotID(unchecked: $0) }
                break
            }
        }
        guard let safetyID else {
            throw RestoreExecutionError.stagingFailed(
                details: "the pre-restore snapshot did not complete, so there would be no way back"
            )
        }

        let diff = try await local.diff(from: safetyID, to: plan.snapshotID)
        let changes = diff.changes.map { change in
            RestorePreview.Change(
                path: change.path,
                kind: RestorePreview.kind(forModifier: change.modifier)
            )
        }

        return RestorePreview(
            changes: changes,
            safetySnapshotID: safetyID,
            bytesAdded: diff.statistics?.added.bytes ?? 0,
            bytesRemoved: diff.statistics?.removed.bytes ?? 0
        )
    }

    /// Restores files onto the server.
    ///
    /// `--delete` is deliberately **not** passed: restic would then remove
    /// anything in the target that is not in the snapshot, which for an
    /// in-place restore of a subset of paths is a far wider blast radius than
    /// the person asked for. Files the snapshot does not contain are reported
    /// in the preview as removals and left alone.
    ///
    /// Includes and excludes are never both passed, because restic refuses
    /// them together ("exclude and include patterns are mutually exclusive",
    /// verified against 0.19.1). A selection is restored with `--include`,
    /// having already been checked by `RestoreSafety` for anything dangerous
    /// underneath it; a whole-server restore uses `--exclude` instead.
    public func restoreFiles(
        plan: RestorePlan,
        paths: [String],
        into targetPath: String,
        session: RestoreSession
    ) async throws -> Int {
        var arguments = ["restore", plan.snapshotID.value, "--target", targetPath, "--json"]
        if paths.isEmpty {
            guard plan.target.isInPlace else {
                throw RestoreExecutionError.nothingToRestore
            }
            for pattern in RestoreExclusions.patterns(optedInto: plan.optedInExclusions) {
                arguments += ["--exclude", pattern]
            }
        } else {
            for path in paths {
                arguments += ["--include", path]
            }
        }

        let result = try await client.run(
            RemoteCommand(
                executable: session.remoteResticPath,
                arguments: arguments,
                secretEnvironment: [
                    "RESTIC_REPOSITORY": session.repositorySecret,
                    "RESTIC_PASSWORD": session.repositoryPassword,
                ],
                requiresRoot: true
            ),
            on: session.destination,
            timeout: .seconds(7200)
        )

        for line in result.standardOutputLines.reversed() {
            guard let data = line.data(using: .utf8), line.hasPrefix("{") else { continue }
            if let summary = try? JSONDecoder.restic().decode(ResticRestoreSummary.self, from: data),
               let files = summary.filesRestored ?? summary.totalFiles {
                return files
            }
        }
        return 0
    }

    /// Stages into a sibling directory, then swaps it in while the service is
    /// stopped.
    ///
    /// The swap is two renames on the same filesystem, which take microseconds.
    /// They are not a single atomic operation, which is why the service is
    /// stopped around them rather than during the whole restore: the window
    /// where a reader could see a half-swapped directory is closed by nothing
    /// being able to read it.
    public func swapStaged(
        livePath: String,
        stagingPath: String,
        retiredPath: String,
        session: RestoreSession
    ) async throws {
        let script = """
        set -e
        test -d \(ShellQuoting.quote(stagingPath))
        rm -rf \(ShellQuoting.quote(retiredPath))
        if [ -e \(ShellQuoting.quote(livePath)) ]; then
          mv \(ShellQuoting.quote(livePath)) \(ShellQuoting.quote(retiredPath))
        fi
        mv \(ShellQuoting.quote(stagingPath)) \(ShellQuoting.quote(livePath))
        """
        try await client.run(
            RemoteCommand(executable: "/bin/sh", arguments: ["-c", script], requiresRoot: true),
            on: session.destination,
            timeout: .seconds(300)
        )
    }

    /// Confirms a staging directory and the live data share a filesystem, since
    /// a rename across filesystems is a copy.
    public func stagingIsOnSameFilesystem(
        livePath: String,
        stagingPath: String,
        session: RestoreSession
    ) async throws -> Bool {
        let script = """
        live=$(df -P \(ShellQuoting.quote(livePath)) 2>/dev/null | awk 'NR==2 {print $1}')
        mkdir -p \(ShellQuoting.quote(stagingPath))
        staging=$(df -P \(ShellQuoting.quote(stagingPath)) 2>/dev/null | awk 'NR==2 {print $1}')
        [ -n "$live" ] && [ "$live" = "$staging" ] && echo same || echo different
        """
        let result = try await client.run(
            RemoteCommand(executable: "/bin/sh", arguments: ["-c", script], requiresRoot: true),
            on: session.destination
        )
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "same"
    }

    public func authorize(facts: RemoteFacts, destination: SSHDestination) throws {
        do {
            try policy.authorize(destination, facts: facts)
        } catch {
            throw RestoreExecutionError.notAuthorized("\(error)")
        }
    }
}

/// The connection and repository a restore runs against.
public struct RestoreSession: Sendable {
    public var jobID: JobID
    public var destination: SSHDestination
    public var remoteResticPath: String
    public var repositorySecret: Secret
    public var repositoryPassword: Secret

    public init(
        jobID: JobID,
        destination: SSHDestination,
        remoteResticPath: String,
        repositorySecret: Secret,
        repositoryPassword: Secret
    ) {
        self.jobID = jobID
        self.destination = destination
        self.remoteResticPath = remoteResticPath
        self.repositorySecret = repositorySecret
        self.repositoryPassword = repositoryPassword
    }
}

struct ResticRestoreSummary: Decodable, Sendable {
    let messageType: String?
    let filesRestored: Int?
    let totalFiles: Int?

    enum CodingKeys: String, CodingKey {
        case messageType = "message_type"
        case filesRestored = "files_restored"
        case totalFiles = "total_files"
    }
}
