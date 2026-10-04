import SwiftUI

/// The activity log.
///
/// Errors are selectable and copyable in full: the most useful thing someone
/// can do with a failure they do not understand is paste it somewhere, and a
/// truncated message makes that impossible.
public struct ActivityLogView: View {
    let entries: [ActivityEntry]
    @State private var filter: ActivityEntry.Level?
    @State private var selection: Set<UUID> = []

    public init(entries: [ActivityEntry]) {
        self.entries = entries
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if visible.isEmpty {
                ContentUnavailableView(
                    "Nothing yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Activity from backups and restores appears here.")
                )
            } else {
                List(visible, selection: $selection) { entry in
                    ActivityRow(entry: entry)
                        .tag(entry.id)
                }
                .listStyle(.inset)
            }
        }
    }

    private var toolbar: some View {
        HStack {
            Picker("Show", selection: $filter) {
                Text("Everything").tag(ActivityEntry.Level?.none)
                Text("Warnings").tag(ActivityEntry.Level?.some(.warning))
                Text("Errors").tag(ActivityEntry.Level?.some(.error))
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            Spacer()

            Button("Copy", systemImage: "doc.on.doc") {
                let text = selected.map(\.copyableText).joined(separator: "\n")
                #if canImport(AppKit)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                #endif
            }
            .keyboardShortcut("c", modifiers: [.command])
            .disabled(selected.isEmpty)
            .help("Copy the selected lines, in full")
        }
        .padding(10)
    }

    private var visible: [ActivityEntry] {
        guard let filter else { return entries.reversed() }
        return entries.reversed().filter { $0.level == filter }
    }

    private var selected: [ActivityEntry] {
        let chosen = entries.filter { selection.contains($0.id) }
        // Copying with nothing selected should still be useful.
        return chosen.isEmpty ? visible : chosen
    }
}

struct ActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: entry.level.symbolName)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(timestamp)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(entry.message)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.level.rawValue) at \(timestamp). \(entry.message)")
    }

    private var tint: Color {
        switch entry.level {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }

    private var timestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: entry.at)
    }
}
