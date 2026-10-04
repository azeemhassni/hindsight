import HindsightCore
import SwiftUI

/// Browse one snapshot's files.
///
/// The tree is loaded a directory at a time: a server snapshot can hold
/// millions of files, and loading it all to show twenty of them would make the
/// window unusable.
public struct SnapshotBrowserView: View {
    let snapshot: Snapshot
    let loadChildren: (String) async -> [SnapshotTreeNode]
    let onRestore: (SnapshotTreeNode) -> Void
    let onPreview: (SnapshotTreeNode) -> Void

    @State private var roots: [SnapshotTreeNode] = []
    @State private var expanded: Set<String> = []
    @State private var selection: SnapshotTreeNode?
    @State private var search = ""
    @State private var isLoading = true

    public init(
        snapshot: Snapshot,
        loadChildren: @escaping (String) async -> [SnapshotTreeNode],
        onRestore: @escaping (SnapshotTreeNode) -> Void,
        onPreview: @escaping (SnapshotTreeNode) -> Void
    ) {
        self.snapshot = snapshot
        self.loadChildren = loadChildren
        self.onRestore = onRestore
        self.onPreview = onPreview
    }

    public var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView("Reading the snapshot…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    OutlineGroup(roots, children: \.children) { node in
                        SnapshotNodeRow(node: node)
                            .tag(node)
                            .contextMenu {
                                Button("Restore this…", systemImage: "arrow.counterclockwise") {
                                    onRestore(node)
                                }
                                if node.isPreviewable {
                                    Button("Quick Look", systemImage: "eye") { onPreview(node) }
                                }
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
        .searchable(text: $search, prompt: "Search this snapshot")
        .navigationTitle(title)
        .toolbar {
            ToolbarItem {
                Button("Restore…", systemImage: "arrow.counterclockwise") {
                    if let selection { onRestore(selection) }
                }
                .disabled(selection == nil)
                .keyboardShortcut("r", modifiers: [.command])
            }
            ToolbarItem {
                Button("Quick Look", systemImage: "eye") {
                    if let selection { onPreview(selection) }
                }
                .disabled(selection?.isPreviewable != true)
                .keyboardShortcut(" ", modifiers: [])
            }
        }
        .task {
            roots = await loadChildren("/")
            isLoading = false
        }
    }

    private var title: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: snapshot.time)
    }
}

struct SnapshotNodeRow: View {
    let node: SnapshotTreeNode

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: node.isDirectory ? "folder" : "doc")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(node.name)
            Spacer(minLength: 12)
            if !node.isDirectory {
                Text(Format.bytes(node.sizeBytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            node.isDirectory
                ? "Folder \(node.name)"
                : "File \(node.name), \(Format.bytes(node.sizeBytes))"
        )
    }
}

/// Two snapshots compared.
public struct SnapshotDiffView: View {
    let left: Snapshot
    let right: Snapshot
    let entries: [SnapshotDiffEntry]

    public init(left: Snapshot, right: Snapshot, entries: [SnapshotDiffEntry]) {
        self.left = left
        self.right = right
        self.entries = entries
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            Divider()
            if entries.isEmpty {
                ContentUnavailableView(
                    "No differences",
                    systemImage: "equal.circle",
                    description: Text("These two snapshots hold the same files.")
                )
            } else {
                List(entries) { entry in
                    HStack(spacing: 8) {
                        Image(systemName: entry.change.symbolName)
                            .foregroundStyle(tint(entry.change))
                            .accessibilityHidden(true)
                        Text(entry.path)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .accessibilityLabel("\(entry.change.label): \(entry.path)")
                }
                .listStyle(.inset)
            }
        }
    }

    private var summary: some View {
        let counts = Dictionary(grouping: entries, by: \.change).mapValues(\.count)
        return HStack(spacing: 16) {
            Label("\(counts[.added] ?? 0) added", systemImage: "plus.circle")
            Label("\(counts[.removed] ?? 0) removed", systemImage: "minus.circle")
            Label("\(counts[.modified] ?? 0) changed", systemImage: "pencil.circle")
            Spacer()
        }
        .font(.callout)
        .monospacedDigit()
        .padding(10)
    }

    private func tint(_ change: SnapshotDiffEntry.Change) -> Color {
        switch change {
        case .added: .green
        case .removed: .red
        case .modified: .orange
        case .metadata: .secondary
        }
    }
}
