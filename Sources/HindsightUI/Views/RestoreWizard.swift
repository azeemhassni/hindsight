import HindsightCore
import HindsightRestore
import SwiftUI

/// The restore wizard.
///
/// The order is deliberate: nothing is written until a person has seen the
/// exact list of changes and typed the server's name. The mode step shows every
/// mode, including the ones that are unavailable, with the reason — a choice
/// you cannot explain is a choice you should not make about your data.
public struct RestoreWizardView: View {
    public enum Step: Int, CaseIterable, Comparable {
        case snapshot
        case scope
        case target
        case mode
        case review
        case confirm

        public static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }

        var title: String {
            switch self {
            case .snapshot: "Choose a snapshot"
            case .scope: "Choose what to restore"
            case .target: "Choose where"
            case .mode: "Choose how"
            case .review: "Review the changes"
            case .confirm: "Confirm"
            }
        }
    }

    let serverName: String
    let serverHostname: String
    let snapshots: [Snapshot]
    let availability: [RestoreModeAvailability]
    let preview: RestorePreview?
    let onPrepare: () async -> Void
    let onRestore: (RestoreMode) -> Void

    @State private var step: Step = .snapshot
    @State private var selectedSnapshot: Snapshot?
    @State private var selectedMode: RestoreMode = .standard
    @State private var typedHostname = ""

    public init(
        serverName: String,
        serverHostname: String,
        snapshots: [Snapshot],
        availability: [RestoreModeAvailability],
        preview: RestorePreview?,
        onPrepare: @escaping () async -> Void,
        onRestore: @escaping (RestoreMode) -> Void
    ) {
        self.serverName = serverName
        self.serverHostname = serverHostname
        self.snapshots = snapshots
        self.availability = availability
        self.preview = preview
        self.onPrepare = onPrepare
        self.onRestore = onRestore
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 480)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Restore \(serverName)").font(.title3.bold())
            Text(step.title).foregroundStyle(.secondary)
        }
        .padding(20)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .snapshot:
            snapshotPicker
        case .scope, .target:
            Text("Scope and target are chosen from the snapshot browser.")
                .foregroundStyle(.secondary)
        case .mode:
            modePicker
        case .review:
            reviewStep
        case .confirm:
            confirmStep
        }
    }

    private var snapshotPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(snapshots.sorted { $0.time > $1.time }, id: \.id.value) { snapshot in
                Button {
                    selectedSnapshot = snapshot
                } label: {
                    HStack {
                        Image(systemName: selectedSnapshot?.id == snapshot.id
                            ? "largecircle.fill.circle" : "circle")
                        VStack(alignment: .leading) {
                            Text(formatted(snapshot.time))
                            Text("\(Format.bytes(snapshot.sizeBytes)) · \(snapshot.kind.rawValue)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(availability, id: \.mode) { entry in
                ModeCard(
                    entry: entry,
                    isSelected: selectedMode == entry.mode,
                    select: { if entry.isAvailable { selectedMode = entry.mode } }
                )
            }
        }
    }

    @ViewBuilder
    private var reviewStep: some View {
        if let preview {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    Label("\(preview.added.count) added", systemImage: "plus.circle")
                    Label("\(preview.modified.count) changed", systemImage: "pencil.circle")
                    Label("\(preview.removed.count) in the way", systemImage: "minus.circle")
                }
                .monospacedDigit()

                Text("""
                A snapshot of everything about to be overwritten has already \
                been taken, so this restore can itself be undone.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)

                if !preview.removed.isEmpty {
                    Text("""
                    Files listed as "in the way" exist now but are not in the \
                    snapshot. They are left alone rather than deleted.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(preview.changes.prefix(200), id: \.path) { change in
                            HStack(spacing: 6) {
                                Text(symbol(for: change.kind)).monospaced()
                                Text(change.path).lineLimit(1).truncationMode(.middle)
                            }
                            .font(.caption)
                        }
                        if preview.changes.count > 200 {
                            Text("…and \(preview.changes.count - 200) more")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ProgressView("Working out exactly what would change…")
                Text("""
                This takes a snapshot of what is there now, then compares it \
                with the one being restored.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .task { await onPrepare() }
        }
    }

    private var confirmStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let warning = availability.first(where: { $0.mode == selectedMode })?.dataLossWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityAddTraits(.isHeader)
            }
            Text("Type **\(serverHostname)** to confirm.")
            TextField("Hostname", text: $typedHostname)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .accessibilityLabel("Type the server's hostname to confirm the restore")
        }
    }

    private var footer: some View {
        HStack {
            Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .snapshot }
                .help("Go back a step")
                .disabled(step == .snapshot)
            Spacer()
            if step == .confirm {
                Button("Restore") { onRestore(selectedMode) }
                    .help("Write these files back to the server")
                    .buttonStyle(.borderedProminent)
                    .disabled(!RestoreSafety.confirmationMatches(typedHostname, hostname: serverHostname))
            } else {
                Button("Continue") { step = Step(rawValue: step.rawValue + 1) ?? .confirm }
                    .help("Go on to the next step; nothing is written yet")
                    .buttonStyle(.borderedProminent)
                    .disabled(!canContinue)
            }
        }
        .padding(20)
    }

    private var canContinue: Bool {
        switch step {
        case .snapshot: selectedSnapshot != nil
        case .review: preview != nil
        default: true
        }
    }

    private func symbol(for kind: RestorePreview.Change.Kind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "-"
        case .modified: "M"
        case .metadata: "~"
        }
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct ModeCard: View {
    let entry: RestoreModeAvailability
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(entry.isAvailable ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(entry.mode.title).font(.headline)
                        if !entry.isAvailable {
                            Text("unavailable")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    Text(entry.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(6)
                    if let warning = entry.dataLossWarning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(6)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.quaternary.opacity(0.25)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!entry.isAvailable)
        .help(summary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(entry.mode.title). \(entry.isAvailable ? "Available" : "Unavailable"). "
                + entry.explanation + (entry.dataLossWarning.map { " Warning: " + $0 } ?? "")
        )
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Split out because type-checking it inline in the body timed out.
    private var summary: String {
        guard let warning = entry.dataLossWarning else { return entry.explanation }
        return entry.explanation + " Warning: " + warning
    }

    private var icon: String {
        guard entry.isAvailable else { return "slash.circle" }
        return switch entry.mode {
        case .zeroDowntime: "bolt.horizontal.circle"
        case .minimalDowntime: "timer"
        case .standard: "arrow.counterclockwise.circle"
        }
    }
}
