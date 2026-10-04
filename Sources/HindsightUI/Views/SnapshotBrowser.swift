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
            header
            Divider()
            if isLoading {
                ProgressView("Reading the snapshot…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleRoots.isEmpty {
                VStack(spacing: 6) {
                    Text(search.isEmpty ? "Nothing to show" : "Nothing matches")
                        .font(.headline)
                    Text(
                        search.isEmpty
                            ? "This snapshot's files could not be listed. The repository may not be on this Mac."
                            : "No file or folder here matches \"\(search)\"."
                    )
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    OutlineGroup(visibleRoots, children: \.children) { node in
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
        .task {
            roots = await loadChildren("/")
            isLoading = false
        }
    }

    /// Its own controls rather than `searchable` and a `toolbar`: this view is
    /// embedded in a pane, not pushed onto a navigation stack, and both of
    /// those modifiers belong to whatever owns the window's chrome.
    private var header: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline)
            Spacer(minLength: 8)
            TextField("Search this snapshot", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            Button("Restore…", systemImage: "arrow.counterclockwise") {
                if let selection { onRestore(selection) }
            }
            .disabled(selection == nil)
            Button("Quick Look", systemImage: "eye") {
                if let selection { onPreview(selection) }
            }
            .labelStyle(.iconOnly)
            .disabled(selection?.isPreviewable != true)
            .help("Look at this file without restoring it")
        }
        .padding(8)
    }

    /// Filtering is by name within what has been loaded: the tree is read a
    /// directory at a time, so a search cannot promise to reach files nobody
    /// has opened yet, and pretending otherwise would be worse than this.
    private var visibleRoots: [SnapshotTreeNode] {
        let term = search.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return roots }
        return SnapshotTreeBuilder.search(roots, for: term)
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
