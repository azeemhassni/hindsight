import Foundation
import HindsightCore
import HindsightRestic
import HindsightSchedule

public struct ForgetOutcome: Sendable, Hashable {
    public var removed: [Snapshot]
    public var kept: [Snapshot]
    public var pruned: Bool
    public var checkAfterPrune: ResticCheckSummary?
}

public struct IntegrityOutcome: Sendable, Hashable {
    public var kind: IntegrityKind
    public var summary: ResticCheckSummary
    public var rotation: IntegrityRotation
    public var completedFullPass: Bool
    public var duration: Duration

    public var isHealthy: Bool { summary.isHealthy }
}

public enum IntegrityKind: String, Sendable, Hashable {
    case structure
    case readDataSubset
    case readAll
}

public enum MaintenanceError: Error, Hashable, Sendable, CustomStringConvertible {
    case notEnoughSpaceToPrune(available: Int64, required: Int64, path: String)
    case integrityCheckFailed(summary: ResticCheckSummary)

    public var description: String {
        switch self {
        case let .notEnoughSpaceToPrune(available, required, path):
            """
            Refusing to prune \(path): \(available) bytes are free and a safe \
            prune needs about \(required). A prune that runs out of space part \
            way through is the one failure that can damage a repository.
            """
        case let .integrityCheckFailed(summary):
            """
            The repository failed its integrity check: \(summary.numErrors) \
            errors\(summary.brokenPacks.map { ", damaged packs: \($0.joined(separator: ", "))" } ?? "").
            """
        }
    }
}

/// Retention and integrity work, all of it local to the Mac.
///
/// Nothing here ever runs on a server: pruning is impossible through an
/// append-only endpoint by design, and a compromised machine must not be able
/// to ask for its own history to be rewritten.
public struct MaintenanceEngine: Sendable {
    public let locks: RepositoryLockManager
    /// A prune rewrites the repository, so it asks for more headroom than a
    /// backup does.
    public let pruneFreeSpaceMargin: Int64

    public init(locks: RepositoryLockManager = .shared, pruneFreeSpaceMargin: Int64 = 5 << 30) {
        self.locks = locks
        self.pruneFreeSpaceMargin = pruneFreeSpaceMargin
    }

    /// Previews a policy without changing anything. This is what the UI shows
    /// before a person commits to a retention change.
    public func preview(
        policy: RetentionPolicy,
        on client: ResticClient,
        tag: SnapshotTag? = nil
    ) async throws -> RetentionDecision {
        let groups = try await client.forget(policy: policy, tag: tag, dryRun: true)
        let keep = (groups.flatMap { $0.keep ?? [] }).map { $0.toSnapshot() }
        let remove = (groups.flatMap { $0.remove ?? [] }).map { $0.toSnapshot() }
        var reasons: [String: [String]] = [:]
        for group in groups {
            for reason in group.reasons ?? [] {
                reasons[reason.snapshot.id] = reason.matches
            }
        }
        return RetentionDecision(keep: keep, remove: remove, reasons: reasons)
    }

    public func forgetAndPrune(
        policy: RetentionPolicy,
        on client: ResticClient,
        repositoryPath: String,
        tag: SnapshotTag? = nil,
        prune: Bool = true,
        checkAfterPrune: Bool = true,
        timeout: Duration? = .seconds(3600)
    ) async throws -> ForgetOutcome {
        try await locks.withLock(repositoryPath: repositoryPath) {
            if prune {
                try ensureEnoughSpaceToPrune(at: repositoryPath)
            }

            // Our own file lock is held, so no other Hindsight operation is
            // using this repository: a restic lock still in it belongs to a run
            // that died. Clearing it is what keeps one interrupted backup from
            // failing every prune afterwards with "unable to create lock".
            try? await client.unlock(removeAll: true)

            let groups = try await client.forget(
                policy: policy,
                tag: tag,
                dryRun: false,
                prune: prune,
                timeout: timeout
            )

            // A prune rewrites pack files, so the repository is verified
            // immediately afterwards rather than at some later scheduled time.
            var summary: ResticCheckSummary?
            if prune, checkAfterPrune {
                summary = try await client.check(timeout: timeout)
                if let summary, !summary.isHealthy {
                    throw MaintenanceError.integrityCheckFailed(summary: summary)
                }
            }

            return ForgetOutcome(
                removed: (groups.flatMap { $0.remove ?? [] }).map { $0.toSnapshot() },
                kept: (groups.flatMap { $0.keep ?? [] }).map { $0.toSnapshot() },
                pruned: prune,
                checkAfterPrune: summary
            )
        }
    }

    /// Runs the next slice of the read-data rotation.
    public func runIntegrityCheck(
        on client: ResticClient,
        repositoryPath: String,
        rotation: IntegrityRotation,
        readData: Bool = true,
        timeout: Duration? = .seconds(7200)
    ) async throws -> IntegrityOutcome {
        try await locks.withLock(repositoryPath: repositoryPath) {
            let started = ContinuousClock.now
            let subset = readData ? rotation.subsetArgument : nil
            let summary = try await client.check(readDataSubset: subset, timeout: timeout)
            return IntegrityOutcome(
                kind: readData ? .readDataSubset : .structure,
                summary: summary,
                rotation: rotation.advanced(),
                completedFullPass: readData && rotation.completesFullPassAfterThisRun,
                duration: ContinuousClock.now - started
            )
        }
    }

    func ensureEnoughSpaceToPrune(at path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard let available = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage else { return }

        guard available > pruneFreeSpaceMargin else {
            throw MaintenanceError.notEnoughSpaceToPrune(
                available: available,
                required: pruneFreeSpaceMargin,
                path: path
            )
        }
    }
}
