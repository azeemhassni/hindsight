import Foundation
import HindsightProtocol
import HindsightRestic

/// Directory listings already read out of a snapshot.
///
/// Reading one costs a fixed price that has nothing to do with its size:
/// restic loads the repository index before it can list anything, measured at
/// 0.75s against a repository where `cat config` takes 0.09s. So the browser is
/// only as quick as the number of restic invocations it causes, and this exists
/// to make that number much smaller than the number of folders somebody opens.
///
/// Snapshots are immutable, so a listing never goes stale: the only reason to
/// drop one is to put a bound on memory.
actor SnapshotListingCache {
    /// Reads the given directories, keyed by directory. One call for many
    /// paths, because that is what restic charges the same price for.
    typealias Fetch = @Sendable ([String]) async throws -> [String: [SnapshotNodeReport]]

    struct Key: Hashable {
        var serverID: String
        var snapshotID: String
        var path: String
    }

    private var entries: [Key: [SnapshotNodeReport]] = [:]
    /// Least-recently-used first.
    private var order: [Key] = []
    private var inFlight: [Key: Task<[SnapshotNodeReport], Error>] = [:]
    private var prefetching: Task<Void, Never>?
    /// What the running prefetch is reading. A folder opened while its
    /// prefetch is still in flight waits for that rather than starting a
    /// second restic for the same listing.
    private var prefetchingPaths: Set<Key> = []

    private let directoryLimit: Int
    private let nodeLimit: Int
    /// How many directories one prefetch asks for. A command line and a burst
    /// of output both have limits, and a directory with a thousand
    /// subdirectories should not produce a thousand-path invocation.
    private let prefetchBatchSize: Int
    private var nodeCount = 0

    init(directoryLimit: Int = 4_000, nodeLimit: Int = 400_000, prefetchBatchSize: Int = 64) {
        self.directoryLimit = directoryLimit
        self.nodeLimit = nodeLimit
        self.prefetchBatchSize = prefetchBatchSize
    }

    /// The listing for one directory, read only if it is not already held.
    ///
    /// Two callers asking for the same directory at once — a folder being
    /// opened while a prefetch is already reading it — wait on one read rather
    /// than starting two.
    func listing(
        serverID: String,
        snapshotID: String,
        path: String,
        fetch: @escaping Fetch
    ) async throws -> [SnapshotNodeReport] {
        let key = Key(serverID: serverID, snapshotID: snapshotID, path: path)
        if let held = entries[key] {
            touch(key)
            return held
        }
        if let running = inFlight[key] {
            return try await running.value
        }
        if prefetchingPaths.contains(key), let prefetch = prefetching {
            await prefetch.value
            if let held = entries[key] {
                touch(key)
                return held
            }
        }

        let task = Task<[SnapshotNodeReport], Error> {
            let groups = try await fetch([path])
            return groups[path] ?? []
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        let nodes = try await task.value
        store(key: key, nodes: nodes)
        return nodes
    }

    /// Reads the subdirectories of a directory already listed, in the
    /// background, so opening any of them costs nothing.
    ///
    /// One prefetch at a time: the point is to spend the index load once, and
    /// several at once would spend it several times over while competing for
    /// the same repository.
    func prefetchChildren(
        serverID: String,
        snapshotID: String,
        of listing: [SnapshotNodeReport],
        fetch: @escaping Fetch
    ) {
        let wanted = listing
            .filter(\.isDirectory)
            .map(\.path)
            .filter { entries[Key(serverID: serverID, snapshotID: snapshotID, path: $0)] == nil }
            .prefix(prefetchBatchSize)
        guard !wanted.isEmpty else { return }

        let paths = Array(wanted)
        prefetching?.cancel()
        prefetchingPaths = Set(paths.map { Key(serverID: serverID, snapshotID: snapshotID, path: $0) })
        prefetching = Task { [weak self] in
            let groups = (try? await fetch(paths)) ?? [:]
            await self?.finishPrefetch(
                serverID: serverID,
                snapshotID: snapshotID,
                paths: paths,
                groups: Task.isCancelled ? [:] : groups
            )
        }
    }

    func absorb(serverID: String, snapshotID: String, groups: [String: [SnapshotNodeReport]]) {
        for (path, nodes) in groups {
            store(key: Key(serverID: serverID, snapshotID: snapshotID, path: path), nodes: nodes)
        }
    }

    /// Clears only the paths this prefetch owned: a later prefetch may have
    /// replaced it, and wiping the whole set would leave that one's waiters
    /// reading for themselves.
    private func finishPrefetch(
        serverID: String,
        snapshotID: String,
        paths: [String],
        groups: [String: [SnapshotNodeReport]]
    ) {
        absorb(serverID: serverID, snapshotID: snapshotID, groups: groups)
        for path in paths {
            prefetchingPaths.remove(Key(serverID: serverID, snapshotID: snapshotID, path: path))
        }
    }

    func cached(serverID: String, snapshotID: String, path: String) -> [SnapshotNodeReport]? {
        entries[Key(serverID: serverID, snapshotID: snapshotID, path: path)]
    }

    var directoryCount: Int { entries.count }

    func removeAll() {
        prefetching?.cancel()
        prefetching = nil
        entries.removeAll()
        order.removeAll()
        nodeCount = 0
    }

    private func store(key: Key, nodes: [SnapshotNodeReport]) {
        if let existing = entries[key] {
            nodeCount -= existing.count
            order.removeAll { $0 == key }
        }
        entries[key] = nodes
        nodeCount += nodes.count
        order.append(key)
        evictIfNeeded()
    }

    private func touch(_ key: Key) {
        guard let index = order.firstIndex(of: key) else { return }
        order.remove(at: index)
        order.append(key)
    }

    private func evictIfNeeded() {
        while (order.count > directoryLimit || nodeCount > nodeLimit), let oldest = order.first {
            order.removeFirst()
            nodeCount -= entries.removeValue(forKey: oldest)?.count ?? 0
        }
    }
}

/// The protocol layer carries plain types and depends on no engine, so the
/// translation from restic's node lives here rather than beside the report.
extension SnapshotNodeReport {
    init(node: ResticNode) {
        self.init(
            path: node.path,
            name: node.name,
            isDirectory: node.isDirectory,
            sizeBytes: node.size,
            modifiedAt: node.mtime,
            permissions: node.permissions
        )
    }
}
