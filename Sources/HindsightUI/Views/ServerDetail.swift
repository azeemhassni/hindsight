import HindsightCore
import HindsightProtocol
import SwiftUI

/// The server view: history, schedule, and what is happening now.
public struct ServerDetailView: View {
    let server: ServerStatus
    let job: RunningJob?
    let snapshots: [Snapshot]
    let repositorySizeBytes: Int64?
    /// Picking a point in the history opens it, which is the thing a person
    /// wants next after noticing it.
    let onOpenSnapshot: (Snapshot) -> Void

    @State private var selectedSnapshot: Snapshot?

    public init(
        server: ServerStatus,
        job: RunningJob?,
        snapshots: [Snapshot],
        repositorySizeBytes: Int64?,
        onOpenSnapshot: @escaping (Snapshot) -> Void = { _ in }
    ) {
        self.server = server
        self.job = job
        self.snapshots = snapshots
        self.repositorySizeBytes = repositorySizeBytes
        self.onOpenSnapshot = onOpenSnapshot
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let job { RunningJobCard(job: job) }
                SnapshotTimeline(snapshots: snapshots, selection: $selectedSnapshot)
                statistics
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: selectedSnapshot) { _, snapshot in
            guard let snapshot else { return }
            onOpenSnapshot(snapshot)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: server.health.symbolName)
                    .accessibilityHidden(true)
                Text(server.health.label)
                    .font(.headline)
            }
            Text(server.scheduleExplanation)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Label("Last backup \(Format.age(of: server.lastBackupAt))", systemImage: "clock")
                Label("Next \(Format.timeUntil(server.nextBackupAt))", systemImage: "calendar")
                if let passed = server.lastCheckPassed {
                    Label(
                        passed ? "Integrity check passed" : "Integrity check failed",
                        systemImage: passed ? "checkmark.seal" : "exclamationmark.triangle"
                    )
                    .foregroundStyle(passed ? Color.secondary : Color.red)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var statistics: some View {
        // Rows rather than a `Grid`: a Grid inside a GroupBox inside a
        // ScrollView crashes SwiftUI's layout on macOS 14, and the alignment a
        // Grid buys here is not worth a window that will not open.
        GroupBox("Repository") {
            VStack(alignment: .leading, spacing: 8) {
                StatisticRow(label: "Snapshots", value: "\(snapshots.count)")
                StatisticRow(label: "Stored", value: Format.bytes(repositorySizeBytes))
                StatisticRow(label: "Savings", value: savings)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Compares what the snapshots covered against what the repository holds,
    /// which is where deduplication and compression show up.
    private var savings: String {
        let processed = snapshots.compactMap(\.sizeBytes).reduce(0, +)
        guard let stored = repositorySizeBytes else { return "—" }
        return Format.savings(stored: stored, processed: processed)
    }
}

struct StatisticRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 16) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value).monospacedDigit()
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

struct RunningJobCard: View {
    let job: RunningJob

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(job.phaseLabel).font(.headline)
                    Spacer()
                    if job.showsPercentage {
                        Text(Format.percent(job.percentDone)).monospacedDigit()
                    }
                }
                if job.showsPercentage {
                    ProgressView(value: job.percentDone ?? 0)
                } else {
                    // Nothing to measure in this phase, and a bar left at 100%
                    // reads as "finished" when it is not.
                    ProgressView().progressViewStyle(.linear)
                }
                if let detail = job.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 16) {
                    if job.showsPercentage {
                        Text("\(Format.bytes(job.bytesDone)) of \(Format.bytes(job.totalBytes))")
                    } else {
                        Text("\(Format.bytes(job.bytesDone)) of files read")
                    }
                    Text("started \(Format.age(of: job.startedAt))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            .padding(6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            job.showsPercentage
                ? "\(job.phaseLabel), \(Format.percent(job.percentDone)) done, "
                    + "\(Format.bytes(job.bytesDone)) of \(Format.bytes(job.totalBytes))."
                : "\(job.phaseLabel). \(job.detail ?? "")"
        )
    }
}

/// A scrubbable history, oldest on the left.
struct SnapshotTimeline: View {
    let snapshots: [Snapshot]
    @Binding var selection: Snapshot?

    var body: some View {
        GroupBox("History") {
            if snapshots.isEmpty {
                Text("No snapshots yet.")
                    .foregroundStyle(.secondary)
                    .padding(6)
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(ordered, id: \.id.value) { snapshot in
                            TimelineTick(
                                snapshot: snapshot,
                                isSelected: selection?.id == snapshot.id,
                                height: height(for: snapshot)
                            )
                            .onTapGesture { selection = snapshot }
                            .accessibilityLabel(label(for: snapshot))
                            .accessibilityAddTraits(selection?.id == snapshot.id ? [.isSelected] : [])
                        }
                    }
                    .padding(.vertical, 6)
                }
                .accessibilityLabel("Snapshot history, \(snapshots.count) snapshots")
            }
        }
    }

    private var ordered: [Snapshot] {
        snapshots.sorted { $0.time < $1.time }
    }

    /// Bar height tracks how much each snapshot added, so a day with real
    /// change is visible at a glance.
    private func height(for snapshot: Snapshot) -> CGFloat {
        let largest = snapshots.compactMap(\.dataAddedBytes).max() ?? 1
        let value = snapshot.dataAddedBytes ?? 0
        let fraction = largest > 0 ? Double(value) / Double(largest) : 0
        return 8 + CGFloat(fraction) * 44
    }

    private func label(for snapshot: Snapshot) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "\(formatter.string(from: snapshot.time)), "
            + "\(Format.bytes(snapshot.dataAddedBytes)) added, \(snapshot.kind.rawValue)"
    }
}

struct TimelineTick: View {
    let snapshot: Snapshot
    let isSelected: Bool
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(tint)
            .frame(width: 7, height: height)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.accentColor, lineWidth: 2)
                }
            }
    }

    private var tint: Color {
        switch snapshot.kind {
        case .filesystem: Color.accentColor.opacity(0.75)
        case .databaseDump: Color.purple.opacity(0.75)
        case .metadata: Color.secondary.opacity(0.5)
        case .safety: Color.orange.opacity(0.8)
        }
    }
}
