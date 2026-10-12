import HindsightCore
import SwiftUI

/// Browse one snapshot's files.
///
/// The tree is loaded a directory at a time: a server snapshot can hold
/// millions of files, and loading it all to show twenty of them would make the
/// window unusable.
public struct SnapshotBrowserView: View {
    let snapshot: Snapshot
    let browser: SnapshotBrowserModel
    let onRestore: (SnapshotTreeNode) -> Void
    let onPreview: (SnapshotTreeNode) -> Void
    let onSaveCopy: ((SnapshotTreeNode) -> Void)?

    @State private var term = ""

    public init(
        snapshot: Snapshot,
        browser: SnapshotBrowserModel,
        onRestore: @escaping (SnapshotTreeNode) -> Void,
        onPreview: @escaping (SnapshotTreeNode) -> Void,
        onSaveCopy: ((SnapshotTreeNode) -> Void)? = nil
    ) {
        self.snapshot = snapshot
        self.browser = browser
        self.onRestore = onRestore
        self.onPreview = onPreview
        self.onSaveCopy = onSaveCopy
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if let node = browser.selectedNode {
                Divider()
                NodeDetail(node: node)
            }
        }
        .task { await browser.start() }
    }

    @ViewBuilder
    private var content: some View {
        if browser.isLoadingRoot {
            ProgressView("Reading the snapshot…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch browser.mode {
            case .tree:
                if browser.rows.isEmpty { empty } else { tree }
            case .searching:
                ProgressView("Searching every file in this snapshot…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .results(searched, truncated):
                results(for: searched, truncated: truncated)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text("Nothing to show").font(.headline)
            Text("""
            This snapshot's files could not be listed. The repository may not \
            be on this Mac.
            """)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A flat list of rows with their own indentation and chevrons rather than
    /// an `OutlineGroup`: an outline wants the whole tree up front, and this
    /// one is read a folder at a time as folders are opened.
    private var tree: some View {
        List(browser.rows, selection: Binding(
            get: { browser.selection },
            set: { browser.selection = $0 }
        )) { row in
            SnapshotRowView(row: row, toggle: { Task { await browser.toggle(row.node.path) } })
                .tag(row.node.path)
                .contextMenu { menu(for: row.node) }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
    }

    private func results(for searched: String, truncated: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(summary(count: browser.matches.count, truncated: truncated, term: searched))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Back to the tree") {
                    term = ""
                    browser.clearSearch()
                }
                .buttonStyle(.link)
                .help("Stop showing search results and go back to browsing folders")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            if browser.matches.isEmpty {
                Text("Nothing in this snapshot is named like that.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(browser.matches, selection: Binding(
                    get: { browser.selection },
                    set: { browser.selection = $0 }
                )) { node in
                    MatchRow(node: node)
                        .tag(node.path)
                        .contextMenu {
                            Button("Show in the tree", systemImage: "list.bullet.indent") {
                                Task { await browser.reveal(node.path) }
                                term = ""
                            }
                            .help("Open the folders leading to this and select it")
                            Divider()
                            menu(for: node)
                        }
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private func menu(for node: SnapshotTreeNode) -> some View {
        Button("Restore this…", systemImage: "arrow.counterclockwise") { onRestore(node) }
            .help("Put this back on the server, from this snapshot")
        if node.isPreviewable {
            Button("Quick Look", systemImage: "eye") { onPreview(node) }
                .help("Look at this file without restoring it")
        }
        if let onSaveCopy, !node.isDirectory {
            Button("Save a Copy…", systemImage: "square.and.arrow.down") { onSaveCopy(node) }
                .help("Write a copy of this file to this Mac, leaving the server alone")
        }
    }

    private func summary(count: Int, truncated: Bool, term: String) -> String {
        if truncated { return "First \(count) matches for \"\(term)\" — narrow it to see the rest" }
        return count == 1 ? "1 match for \"\(term)\"" : "\(count) matches for \"\(term)\""
    }

    /// Its own controls rather than `searchable` and a `toolbar`: this view is
    /// embedded in a pane, not pushed onto a navigation stack, and both of
    /// those modifiers belong to whatever owns the window's chrome.
    private var header: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            TextField("Search this snapshot", text: $term)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 90, idealWidth: 220, maxWidth: 220)
                .onSubmit { Task { await browser.search(term) } }
                .help("Type a name and press Return to read the whole snapshot for it")
            Button("Restore…", systemImage: "arrow.counterclockwise") {
                if let node = browser.selectedNode { onRestore(node) }
            }
            .disabled(browser.selectedNode == nil)
            .help("Put the selected file or folder back on the server")
            Button("Quick Look", systemImage: "eye") {
                if let node = browser.selectedNode { onPreview(node) }
            }
            .labelStyle(.iconOnly)
            .disabled(browser.selectedNode?.isPreviewable != true)
            .help("Look at this file without restoring it")
        }
        .padding(8)
    }

    private var title: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: snapshot.time)
    }
}

/// One row of the tree: indentation, a chevron for folders, name and size.
struct SnapshotRowView: View {
    let row: SnapshotBrowserModel.Row
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Spacer()
                .frame(width: CGFloat(row.depth) * 14)
            chevron
            Image(systemName: row.node.isDirectory ? "folder" : "doc")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(row.node.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            if !row.node.isDirectory {
                Text(Format.bytes(row.node.sizeBytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if row.node.isDirectory { toggle() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(row.node.isDirectory ? [.isButton] : [])
        .accessibilityAction(named: row.isExpanded ? "Collapse" : "Expand") {
            if row.node.isDirectory { toggle() }
        }
    }

    @ViewBuilder
    private var chevron: some View {
        if row.isLoading {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 14)
        } else if row.node.isDirectory, !row.isEmptyDirectory {
            Button(action: toggle) {
                Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .help(row.isExpanded ? "Close this folder" : "Open this folder")
        } else {
            Spacer().frame(width: 14)
        }
    }

    private var label: String {
        if row.node.isDirectory {
            let state = row.isEmptyDirectory ? "empty" : (row.isExpanded ? "open" : "closed")
            return "Folder \(row.node.name), \(state)"
        }
        return "File \(row.node.name), \(Format.bytes(row.node.sizeBytes))"
    }
}

/// A search result, which needs its whole path to mean anything.
struct MatchRow: View {
    let node: SnapshotTreeNode

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: node.isDirectory ? "folder" : "doc")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name).lineLimit(1)
                Text((node.path as NSString).deletingLastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
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
                ? "Folder \(node.name) in \((node.path as NSString).deletingLastPathComponent)"
                : "File \(node.name) in \((node.path as NSString).deletingLastPathComponent), "
                    + Format.bytes(node.sizeBytes)
        )
    }
}

/// What is known about the selected entry.
struct NodeDetail: View {
    let node: SnapshotTreeNode

    var body: some View {
        HStack(spacing: 14) {
            Text(node.path)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if !node.isDirectory {
                Text(Format.bytes(node.sizeBytes)).font(.caption.monospacedDigit())
            }
            if let modified = node.modifiedAt {
                Text(modified, format: .dateTime.day().month().year().hour().minute())
                    .font(.caption)
            }
            if let permissions = node.permissions {
                Text(permissions).font(.caption.monospaced())
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
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
