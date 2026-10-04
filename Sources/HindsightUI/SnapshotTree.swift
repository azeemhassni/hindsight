import Foundation
import HindsightCore

/// A lazily-built file tree for the snapshot browser.
///
/// Built from `restic ls` output a directory at a time. A snapshot of a server
/// can hold millions of files, so the tree never loads more than the
/// directories that have been opened.
public struct SnapshotTreeNode: Sendable, Hashable, Identifiable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var sizeBytes: Int64?
    public var modifiedAt: Date?
    public var permissions: String?
    /// nil means "not loaded yet", which is different from "empty".
    public var children: [SnapshotTreeNode]?

    public var id: String { path }

    public init(
        path: String,
        name: String,
        isDirectory: Bool,
        sizeBytes: Int64? = nil,
        modifiedAt: Date? = nil,
        permissions: String? = nil,
        children: [SnapshotTreeNode]? = nil
    ) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.permissions = permissions
        self.children = children
    }

    public var isLoaded: Bool { children != nil }

    /// Files a Quick Look preview can usefully show.
    public var isPreviewable: Bool {
        guard !isDirectory else { return false }
        let previewable = [
            "txt", "md", "log", "conf", "cfg", "ini", "json", "yaml", "yml",
            "toml", "xml", "html", "css", "js", "ts", "swift", "py", "rb", "go",
            "rs", "sh", "sql", "env", "service", "png", "jpg", "jpeg", "gif",
            "pdf", "svg",
        ]
        let suffix = (name as NSString).pathExtension.lowercased()
        // Files with no extension are usually configuration on a server.
        return suffix.isEmpty || previewable.contains(suffix)
    }
}

public enum SnapshotTreeBuilder {
    /// Groups a flat listing into the children of one directory.
    ///
    /// restic lists recursively; the browser wants one level, so deeper entries
    /// are collapsed into the directory that contains them.
    public static func children(
        of directory: String,
        from paths: [(path: String, isDirectory: Bool, size: Int64?, modified: Date?, permissions: String?)]
    ) -> [SnapshotTreeNode] {
        let prefix = directory == "/" ? "/" : directory + "/"
        var seen: Set<String> = []
        var nodes: [SnapshotTreeNode] = []

        for entry in paths {
            guard entry.path.hasPrefix(prefix), entry.path != directory else { continue }
            let remainder = String(entry.path.dropFirst(prefix.count))
            guard !remainder.isEmpty else { continue }

            let components = remainder.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            let name = String(components[0])
            let childPath = prefix + name
            guard seen.insert(childPath).inserted else { continue }

            let isDirectory = components.count > 1 || entry.isDirectory
            nodes.append(
                SnapshotTreeNode(
                    path: childPath,
                    name: name,
                    isDirectory: isDirectory,
                    sizeBytes: components.count > 1 ? nil : entry.size,
                    modifiedAt: components.count > 1 ? nil : entry.modified,
                    permissions: components.count > 1 ? nil : entry.permissions
                )
            )
        }

        // Directories first, then alphabetical: the order people expect.
        return nodes.sorted { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    /// Filters a listing by a search term, keeping the directories needed to
    /// reach each match so results stay navigable.
    public static func search(
        _ term: String,
        in paths: [String],
        limit: Int = 500
    ) -> [String] {
        let needle = term.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        return paths
            .filter { ($0 as NSString).lastPathComponent.lowercased().contains(needle) }
            .prefix(limit)
            .map { $0 }
    }
}

/// Two snapshots, side by side.
public struct SnapshotDiffEntry: Sendable, Hashable, Identifiable {
    public enum Change: String, Sendable, Hashable {
        case added
        case removed
        case modified
        case metadata

        public var symbolName: String {
            switch self {
            case .added: "plus.circle.fill"
            case .removed: "minus.circle.fill"
            case .modified: "pencil.circle.fill"
            case .metadata: "info.circle.fill"
            }
        }

        public var label: String {
            switch self {
            case .added: "Added"
            case .removed: "Removed"
            case .modified: "Changed"
            case .metadata: "Permissions or ownership changed"
            }
        }
    }

    public var path: String
    public var change: Change

    public var id: String { path }

    public init(path: String, change: Change) {
        self.path = path
        self.change = change
    }
}

extension SnapshotTreeBuilder {
    /// Keeps the nodes whose name matches, and any folder on the way to one.
    ///
    /// Only within what has been loaded: the tree is read a directory at a
    /// time, so a search cannot reach files nobody has opened yet.
    public static func search(
        _ nodes: [SnapshotTreeNode],
        for term: String
    ) -> [SnapshotTreeNode] {
        let needle = term.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return nodes }

        return nodes.compactMap { node -> SnapshotTreeNode? in
            let matchedChildren = search(node.children ?? [], for: needle)
            let matchesItself = node.name.lowercased().contains(needle)
            guard matchesItself || !matchedChildren.isEmpty else { return nil }

            var copy = node
            // A folder that matched by name keeps whatever it held, so opening
            // it still shows its contents.
            if !matchedChildren.isEmpty || !matchesItself {
                copy.children = matchedChildren
            }
            return copy
        }
    }
}
