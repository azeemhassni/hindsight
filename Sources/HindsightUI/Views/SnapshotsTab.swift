import HindsightCore
import SwiftUI

/// Snapshots on the left, the chosen one's files on the right.
///
/// Restoring a single file starts here rather than in the restore sheet: the
/// question "which file, from when" is a browsing question, and answering it
/// before the safety steps keeps those steps about safety.
public struct SnapshotsTab: View {
    let snapshots: [Snapshot]
    @Binding var selection: String?
    let loadChildren: (SnapshotID, String) async -> [SnapshotTreeNode]
    let onRestore: (Snapshot, SnapshotTreeNode?) -> Void
    let onPreview: (Snapshot, SnapshotTreeNode) -> Void

    @State private var kindFilter: SnapshotKind?

    public init(
        snapshots: [Snapshot],
        selection: Binding<String?>,
        loadChildren: @escaping (SnapshotID, String) async -> [SnapshotTreeNode],
        onRestore: @escaping (Snapshot, SnapshotTreeNode?) -> Void,
        onPreview: @escaping (Snapshot, SnapshotTreeNode) -> Void
    ) {
        self.snapshots = snapshots
        _selection = selection
        self.loadChildren = loadChildren
        self.onRestore = onRestore
        self.onPreview = onPreview
    }

    public var body: some View {
        HSplitView {
            list
                .frame(minWidth: 200, idealWidth: 280, maxWidth: 400)
            browser
                .frame(minWidth: 280)
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            Picker("Kind", selection: $kindFilter) {
                Text("All").tag(SnapshotKind?.none)
                Text("Files").tag(SnapshotKind?.some(.filesystem))
                Text("Databases").tag(SnapshotKind?.some(.databaseDump))
                Text("Safety").tag(SnapshotKind?.some(.safety))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            if visible.isEmpty {
                Text(snapshots.isEmpty ? "No snapshots yet." : "Nothing of this kind.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(visible, selection: $selection) { snapshot in
                    SnapshotRow(snapshot: snapshot)
                        .tag(snapshot.id.value)
                        .contextMenu {
                            Button("Restore all of this…", systemImage: "arrow.counterclockwise") {
                                onRestore(snapshot, nil)
                            }
                            .help("Restore everything this snapshot holds, not one path out of it")
                        }
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private var browser: some View {
        if let selected {
            SnapshotBrowserView(
                snapshot: selected,
                loadChildren: { path in await loadChildren(selected.id, path) },
                onRestore: { node in onRestore(selected, node) },
                onPreview: { node in onPreview(selected, node) }
            )
            // Keyed on the snapshot so switching snapshots reloads the tree
            // rather than showing the previous one's files under a new date.
            .id(selected.id.value)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Choose a snapshot to look inside it.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var visible: [Snapshot] {
        let ordered = snapshots.sorted { $0.time > $1.time }
        guard let kindFilter else { return ordered }
        return ordered.filter { $0.kind == kindFilter }
    }

    private var selected: Snapshot? {
        visible.first { $0.id.value == selection } ?? visible.first
    }
}

struct SnapshotRow: View {
    let snapshot: Snapshot

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(timestamp)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(Format.bytes(snapshot.dataAddedBytes))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(timestamp), \(subtitle), \(Format.bytes(snapshot.dataAddedBytes)) added")
    }

    private var timestamp: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: snapshot.time)
    }

    private var subtitle: String {
        var parts = [String(snapshot.id.value.prefix(8))]
        switch snapshot.kind {
        case .filesystem: parts.append("files")
        case .databaseDump: parts.append("database dump")
        case .metadata: parts.append("server metadata")
        case .safety: parts.append("taken before a restore")
        }
        return parts.joined(separator: " · ")
    }

    private var symbol: String {
        switch snapshot.kind {
        case .filesystem: "folder"
        case .databaseDump: "cylinder.split.1x2"
        case .metadata: "doc.text"
        case .safety: "shield"
        }
    }
}
