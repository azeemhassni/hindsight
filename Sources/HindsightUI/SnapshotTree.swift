import Foundation
import HindsightCore
import HindsightProtocol

/// One entry in a snapshot: a file or a folder, as the agent read it.
public struct SnapshotTreeNode: Sendable, Hashable, Identifiable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var sizeBytes: Int64?
    public var modifiedAt: Date?
    public var permissions: String?

    public var id: String { path }

    public init(
        path: String,
        name: String,
        isDirectory: Bool,
        sizeBytes: Int64? = nil,
        modifiedAt: Date? = nil,
        permissions: String? = nil
    ) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.permissions = permissions
    }

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

extension SnapshotTreeNode {
    /// Built from what the agent reported. A node carries no children: the
    /// browser's model owns the shape of the tree, and a second copy of it
    /// here would be one that could disagree.
    public init(report: SnapshotNodeReport) {
        self.init(
            path: report.path,
            name: report.name,
            isDirectory: report.isDirectory,
            sizeBytes: report.sizeBytes,
            modifiedAt: report.modifiedAt,
            permissions: report.permissions
        )
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
