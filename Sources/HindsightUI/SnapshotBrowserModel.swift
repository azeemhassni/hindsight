import Foundation
import HindsightCore
import Observation

/// The state of one snapshot being explored.
///
/// The tree is built as folders are opened, which is the only way this can
/// work: a server snapshot holds hundreds of thousands of files, and the
/// agent charges a repository index load per listing. What has been read is
/// kept, so collapsing a folder and opening it again costs nothing, and going
/// back up the tree is instant.
@MainActor
@Observable
public final class SnapshotBrowserModel {
    /// One line of the tree as it is drawn.
    public struct Row: Identifiable, Hashable, Sendable {
        public var node: SnapshotTreeNode
        public var depth: Int
        public var isExpanded: Bool
        public var isLoading: Bool
        /// False for a directory nobody has opened: its contents are unknown,
        /// so whether it has any is unknown too.
        public var isEmptyDirectory: Bool

        public var id: String { node.path }
    }

    public enum Mode: Sendable, Equatable {
        case tree
        case searching
        case results(term: String, truncated: Bool)
    }

    private let load: (String) async -> [SnapshotTreeNode]
    private let find: ((String) async -> SnapshotSearchOutcome)?

    private var children: [String: [SnapshotTreeNode]] = [:]
    private var expanded: Set<String> = ["/"]
    private var loading: Set<String> = []

    public private(set) var rows: [Row] = []
    public private(set) var mode: Mode = .tree
    public private(set) var isLoadingRoot = true
    public private(set) var failure: String?
    public private(set) var matches: [SnapshotTreeNode] = []
    public var selection: String?

    public init(
        load: @escaping (String) async -> [SnapshotTreeNode],
        find: ((String) async -> SnapshotSearchOutcome)? = nil
    ) {
        self.load = load
        self.find = find
    }

    public var selectedNode: SnapshotTreeNode? {
        guard let selection else { return nil }
        if case .results = mode { return matches.first { $0.path == selection } }
        return rows.first { $0.node.path == selection }?.node
    }

    public func start() async {
        await read("/")
        isLoadingRoot = false
        rebuild()
    }

    /// Opens or closes a folder, reading it the first time it is opened.
    public func toggle(_ path: String) async {
        if expanded.contains(path) {
            expanded.remove(path)
            rebuild()
            return
        }
        expanded.insert(path)
        rebuild()
        if children[path] == nil {
            await read(path)
            rebuild()
        }
    }

    public func isExpanded(_ path: String) -> Bool { expanded.contains(path) }

    /// Opens every folder on the way to a path, so a search result can be
    /// shown in place in the tree.
    public func reveal(_ path: String) async {
        mode = .tree
        var ancestors: [String] = []
        var current = (path as NSString).deletingLastPathComponent
        while current != "/", !current.isEmpty {
            ancestors.append(current)
            current = (current as NSString).deletingLastPathComponent
        }
        for ancestor in ancestors.reversed() {
            expanded.insert(ancestor)
            if children[ancestor] == nil { await read(ancestor) }
        }
        selection = path
        rebuild()
    }

    public func search(_ term: String) async {
        let needle = term.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else {
            mode = .tree
            matches = []
            rebuild()
            return
        }
        guard let find else {
            // Without a way to read the whole snapshot, say so rather than
            // searching what happens to be loaded and calling it the answer.
            mode = .results(term: needle, truncated: false)
            matches = []
            return
        }
        mode = .searching
        let outcome = await find(needle)
        matches = outcome.nodes
        failure = outcome.failure
        mode = .results(term: needle, truncated: outcome.truncated)
    }

    public func clearSearch() {
        mode = .tree
        matches = []
        rebuild()
    }

    private func read(_ path: String) async {
        loading.insert(path)
        rebuild()
        let nodes = await load(path)
        loading.remove(path)
        children[path] = nodes
    }

    private func rebuild() {
        var built: [Row] = []
        append(directory: "/", depth: 0, into: &built)
        rows = built
    }

    private func append(directory: String, depth: Int, into rows: inout [Row]) {
        for node in children[directory] ?? [] {
            let isOpen = expanded.contains(node.path)
            let loaded = children[node.path]
            rows.append(
                Row(
                    node: node,
                    depth: depth,
                    isExpanded: isOpen,
                    isLoading: loading.contains(node.path),
                    isEmptyDirectory: node.isDirectory && loaded?.isEmpty == true
                )
            )
            if node.isDirectory, isOpen {
                append(directory: node.path, depth: depth + 1, into: &rows)
            }
        }
    }
}

/// What a snapshot-wide search came back with.
public struct SnapshotSearchOutcome: Sendable, Equatable {
    public var nodes: [SnapshotTreeNode]
    /// True when the limit was reached, so the list is the first N matches
    /// rather than all of them — the interface has to say which.
    public var truncated: Bool
    public var failure: String?

    public init(nodes: [SnapshotTreeNode], truncated: Bool = false, failure: String? = nil) {
        self.nodes = nodes
        self.truncated = truncated
        self.failure = failure
    }
}
