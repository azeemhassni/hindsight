import Foundation
import HindsightProtocol
import Testing
@testable import HindsightAgentKit

/// Counts restic invocations, because that is the thing the cache exists to
/// reduce: a listing costs one repository index load whatever its size.
private actor FetchRecorder {
    private(set) var calls: [[String]] = []
    private var tree: [String: [SnapshotNodeReport]]

    init(tree: [String: [SnapshotNodeReport]]) {
        self.tree = tree
    }

    var callCount: Int { calls.count }

    func fetch(_ paths: [String]) async throws -> [String: [SnapshotNodeReport]] {
        calls.append(paths.sorted())
        var answer: [String: [SnapshotNodeReport]] = [:]
        for path in paths { answer[path] = tree[path] ?? [] }
        return answer
    }
}

private func directory(_ path: String) -> SnapshotNodeReport {
    SnapshotNodeReport(
        path: path,
        name: (path as NSString).lastPathComponent,
        isDirectory: true,
        sizeBytes: nil,
        modifiedAt: nil,
        permissions: "drwxr-xr-x"
    )
}

private func file(_ path: String) -> SnapshotNodeReport {
    SnapshotNodeReport(
        path: path,
        name: (path as NSString).lastPathComponent,
        isDirectory: false,
        sizeBytes: 12,
        modifiedAt: nil,
        permissions: "-rw-r--r--"
    )
}

@Suite("Snapshot listing cache")
struct SnapshotListingCacheTests {
    private func recorder() -> FetchRecorder {
        FetchRecorder(tree: [
            "/": [directory("/etc"), directory("/srv"), file("/hosts")],
            "/etc": [file("/etc/fstab")],
            "/srv": [directory("/srv/app")],
            "/srv/app": [file("/srv/app/main.js")],
        ])
    }

    @Test("reads a directory once and serves it from then on")
    func readsOnce() async throws {
        let cache = SnapshotListingCache(prefetchBatchSize: 0)
        let recorder = recorder()

        let first = try await cache.listing(serverID: "web-01", snapshotID: "s1", path: "/etc") { try await recorder.fetch($0) }
        let second = try await cache.listing(serverID: "web-01", snapshotID: "s1", path: "/etc") { try await recorder.fetch($0) }

        #expect(first.map(\.name) == ["fstab"])
        #expect(second == first)
        #expect(await recorder.callCount == 1)
    }

    @Test("two snapshots do not share a listing for the same path")
    func keepsSnapshotsApart() async throws {
        let cache = SnapshotListingCache(prefetchBatchSize: 0)
        let recorder = recorder()

        _ = try await cache.listing(serverID: "web-01", snapshotID: "s1", path: "/etc") { try await recorder.fetch($0) }
        _ = try await cache.listing(serverID: "web-01", snapshotID: "s2", path: "/etc") { try await recorder.fetch($0) }
        #expect(await recorder.callCount == 2)
    }

    @Test("prefetches a directory's subfolders in one call, so opening one is free")
    func prefetchesSubfolders() async throws {
        let cache = SnapshotListingCache()
        let recorder = recorder()
        let fetch: SnapshotListingCache.Fetch = { try await recorder.fetch($0) }

        let root = try await cache.listing(serverID: "web-01", snapshotID: "s1", path: "/", fetch: fetch)
        await cache.prefetchChildren(serverID: "web-01", snapshotID: "s1", of: root, fetch: fetch)

        // Give the background read a moment to land.
        for _ in 0..<50 where await cache.cached(serverID: "web-01", snapshotID: "s1", path: "/etc") == nil {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(await cache.cached(serverID: "web-01", snapshotID: "s1", path: "/etc")?.map(\.name) == ["fstab"])
        #expect(await cache.cached(serverID: "web-01", snapshotID: "s1", path: "/srv")?.map(\.name) == ["app"])
        // One call for the root, one for both of its subfolders together — not
        // one per folder.
        #expect(await recorder.callCount == 2)
        #expect(await recorder.calls.last == ["/etc", "/srv"])

        // And the file is not asked for: only directories have contents.
        #expect(await recorder.calls.last?.contains("/hosts") == false)

        // Opening a prefetched folder costs nothing.
        _ = try await cache.listing(serverID: "web-01", snapshotID: "s1", path: "/etc", fetch: fetch)
        #expect(await recorder.callCount == 2)
    }

    @Test("two callers asking for one directory at once cause one read")
    func coalescesConcurrentReads() async throws {
        let cache = SnapshotListingCache(prefetchBatchSize: 0)
        let recorder = recorder()
        let fetch: SnapshotListingCache.Fetch = { paths in
            try await Task.sleep(for: .milliseconds(50))
            return try await recorder.fetch(paths)
        }

        async let first = cache.listing(serverID: "web-01", snapshotID: "s1", path: "/etc", fetch: fetch)
        async let second = cache.listing(serverID: "web-01", snapshotID: "s1", path: "/etc", fetch: fetch)
        let both = try await [first, second]

        #expect(both[0] == both[1])
        #expect(await recorder.callCount == 1)
    }

    @Test("drops the oldest listings rather than growing without bound")
    func evictsOldest() async throws {
        let cache = SnapshotListingCache(directoryLimit: 2, prefetchBatchSize: 0)
        let recorder = recorder()
        let fetch: SnapshotListingCache.Fetch = { try await recorder.fetch($0) }

        _ = try await cache.listing(serverID: "web-01", snapshotID: "s1", path: "/etc", fetch: fetch)
        _ = try await cache.listing(serverID: "web-01", snapshotID: "s1", path: "/srv", fetch: fetch)
        _ = try await cache.listing(serverID: "web-01", snapshotID: "s1", path: "/srv/app", fetch: fetch)

        #expect(await cache.directoryCount == 2)
        #expect(await cache.cached(serverID: "web-01", snapshotID: "s1", path: "/etc") == nil)
        #expect(await cache.cached(serverID: "web-01", snapshotID: "s1", path: "/srv/app") != nil)
    }
}
