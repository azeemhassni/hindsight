import HindsightCore
import HindsightProtocol
import SwiftUI

/// The restore sheet, driven by `RestoreFlow`.
///
/// Every step is gated by the flow rather than by the view, so the rule that
/// nothing is written before a preview has been seen and the hostname typed
/// holds whatever the interface does.
public struct RestoreSheetView: View {
    @Bindable var flow: RestoreFlow
    let snapshots: [Snapshot]
    let availabilityExplanations: [(mode: String, title: String, available: Bool, explanation: String)]
    /// Other machines this snapshot could be written to. Empty for the
    /// ordinary case, which keeps the sheet as it was.
    let otherServers: [RestoreDestination]
    /// Builds the flow for adding a machine from its connection details.
    /// Absent in previews and tests, where the option is simply not offered.
    let makeTargetFlow: (() -> RestoreTargetFlow)?
    let onClose: () -> Void

    @State private var addingTarget: RestoreTargetFlow?

    public init(
        flow: RestoreFlow,
        snapshots: [Snapshot],
        availabilityExplanations: [(mode: String, title: String, available: Bool, explanation: String)],
        otherServers: [RestoreDestination] = [],
        makeTargetFlow: (() -> RestoreTargetFlow)? = nil,
        onClose: @escaping () -> Void
    ) {
        self.flow = flow
        self.snapshots = snapshots
        self.availabilityExplanations = availabilityExplanations
        self.otherServers = otherServers
        self.makeTargetFlow = makeTargetFlow
        self.onClose = onClose
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
        .sheet(item: $addingTarget) { target in
            RestoreTargetSheet(
                flow: target,
                onAdded: { serverID, hostname in
                    flow.targetServerID = serverID
                    flow.targetHostname = hostname
                    // The hostname typed before confirmed a different machine.
                    flow.typedHostname = ""
                    flow.preview = nil
                    addingTarget = nil
                },
                onClose: { addingTarget = nil }
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(flow.title).font(.title3.bold())
            Text(flow.statusText)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(6)
        }
        .padding(20)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        switch flow.stage {
        case .choosing:
            VStack(alignment: .leading, spacing: 20) {
                snapshotPicker
                if !otherServers.isEmpty || makeTargetFlow != nil { targetPicker }
                // A dump is loaded, not written: the modes are about replacing
                // files and mean nothing here.
                if flow.isDatabaseDump { databasePicker } else { modeList }
            }
        case .preparing, .running:
            ProgressView().controlSize(.large)
        case .authorizing:
            VStack(spacing: 12) {
                Image(systemName: "touchid")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Confirm with Touch ID")
                    .font(.headline)
                Text("""
                A restore writes to \(flow.hostnameToConfirm). Hindsight asks for \
                Touch ID, or your login password, before it starts.
                """)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity)
        case .reviewing:
            reviewList
        case .confirming:
            confirmation
        case let .finished(_, safetySnapshotID):
            VStack(alignment: .leading, spacing: 10) {
                Label("Restore finished.", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                if let safetySnapshotID {
                    Text("""
                    Everything it replaced was snapshotted first. To undo it, \
                    restore snapshot \(safetySnapshotID.prefix(8)).
                    """)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(6)
                }
            }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(6)
        }
    }

    /// Where the snapshot lands. Only shown when there is somewhere else it
    /// could go, so an ordinary restore is not made to look like a choice.
    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Where").font(.headline)
            Picker("Where", selection: Binding(
                get: { flow.targetServerID ?? flow.serverID },
                set: { chosen in
                    if chosen == flow.serverID {
                        flow.targetServerID = nil
                        flow.targetHostname = nil
                    } else {
                        flow.targetServerID = chosen
                        flow.targetHostname = otherServers.first { $0.id == chosen }?.hostname
                    }
                    // The hostname that was typed confirmed a different
                    // machine, so it cannot carry over.
                    flow.typedHostname = ""
                    flow.preview = nil
                }
            )) {
                Text("Back onto \(flow.serverHostname)").tag(flow.serverID)
                ForEach(otherServers, id: \.id) { server in
                    Text("Onto \(server.name) (\(server.hostname))").tag(server.id)
                }
            }
            .labelsHidden()
            .help("Choose the machine these files are written to")
            if let makeTargetFlow {
                Button("Another machine…", systemImage: "plus.circle") {
                    addingTarget = makeTargetFlow()
                }
                .buttonStyle(.link)
                .help("Restore onto a machine by giving its connection details")
            }
            if flow.targetServerID != nil {
                Label(
                    """
                    This writes one server's files onto another. Anything the \
                    snapshot holds for a machine's own identity — its network \
                    configuration, host keys and filesystem table — stays \
                    excluded unless you opt in.
                    """,
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(6)
            }
        }
    }

    private var snapshotPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Snapshot").font(.headline)
            ForEach(snapshots.sorted { $0.time > $1.time }.prefix(30), id: \.id.value) { snapshot in
                Button {
                    choose(snapshot)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: flow.snapshotID == snapshot.id.value
                            ? "largecircle.fill.circle" : "circle")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(formatted(snapshot.time))
                            Text("\(Format.bytes(snapshot.sizeBytes)) · \(snapshot.kind.rawValue)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    // On the label rather than the button: a custom button
                    // label is otherwise read out as a bare "button", and a
                    // list of thirty of those is no way to choose which
                    // snapshot to restore.
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(formatted(snapshot.time)), \(Format.bytes(snapshot.sizeBytes)), "
                            + snapshot.kind.rawValue
                            + (flow.snapshotID == snapshot.id.value ? ", chosen" : "")
                    )
                }
                .buttonStyle(.plain)
                .help(snapshot.kind == .databaseDump
                    ? "Load this dump back into a database"
                    : "Restore the server as it was at \(formatted(snapshot.time))")
            }
        }
    }

    /// Choosing a snapshot decides what kind of restore this is: a dump is
    /// loaded into a database, and files are written onto the disk. They are
    /// different enough that the sheet should not look the same for both.
    private func choose(_ snapshot: Snapshot) {
        flow.snapshotID = snapshot.id.value
        flow.preview = nil
        flow.isDatabaseDump = snapshot.kind == .databaseDump
        flow.paths = snapshot.kind == .databaseDump ? snapshot.paths : []
        flow.databaseName = snapshot.tags
            .first { $0.hasPrefix("dbname:") }
            .map { String($0.dropFirst("dbname:".count)) }
        flow.loadIntoDatabase = nil
        if flow.isDatabaseDump {
            Task { await flow.loadDatabaseChoices() }
        }
    }

    /// Which database a dump is loaded into. Nothing is assumed: the container
    /// on a replacement machine rarely has the same name as the original.
    private var databasePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Load into").font(.headline)
            if flow.availableDatabases.isEmpty {
                Text("Looking for databases on \(flow.hostnameToConfirm)…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Load into", selection: Binding(
                    get: { flow.loadIntoDatabase ?? "" },
                    set: { flow.loadIntoDatabase = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Choose a database").tag("")
                    ForEach(flow.availableDatabases) { database in
                        Text(database.canLoadWhileRunning
                            ? database.displayName
                            : "\(database.displayName) — cannot be loaded while running")
                            .tag(database.id)
                    }
                }
                .labelsHidden()
                .help("The database this dump is loaded into")
            }
            Label(
                """
                This replaces the contents of that database with the dump. \
                There is no safety snapshot to undo it with — what it replaces \
                is inside a database, not on the filesystem — so the previous \
                dump in this repository is the way back.
                """,
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .lineLimit(8)
        }
    }

    private var modeList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How").font(.headline)
            ForEach(availabilityExplanations, id: \.mode) { entry in
                Button {
                    if entry.available { flow.mode = entry.mode }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: flow.mode == entry.mode
                            ? "largecircle.fill.circle"
                            : (entry.available ? "circle" : "slash.circle"))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(entry.title)
                                if !entry.available {
                                    Text("unavailable")
                                        .font(.caption)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(.quaternary, in: Capsule())
                                }
                            }
                            // Unavailable modes keep their reason rather than
                            // disappearing: a choice you cannot explain is one
                            // you should not make about your data.
                            Text(entry.explanation)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .lineLimit(6)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!entry.available)
                .accessibilityLabel(
                    "\(entry.title). \(entry.available ? "Available" : "Unavailable"). \(entry.explanation)"
                )
                // The same words the row shows, so hovering an unavailable
                // mode explains why it cannot be chosen.
                .help(entry.explanation)
            }
        }
    }

    @ViewBuilder
    private var reviewList: some View {
        if let preview = flow.preview {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    Label("\(preview.addedCount) added", systemImage: "plus.circle")
                    Label("\(preview.modifiedCount) changed", systemImage: "pencil.circle")
                    Label("\(preview.removedCount) in the way", systemImage: "minus.circle")
                }
                .monospacedDigit()

                Text("""
                A snapshot of everything about to be replaced has already been \
                taken, so this restore can itself be undone. Files the snapshot \
                does not contain are left alone rather than deleted.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(6)

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
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 12) {
            if flow.isDatabaseDump, let into = flow.availableDatabases
                .first(where: { $0.id == flow.loadIntoDatabase }) {
                Text("""
                This replaces the contents of **\(into.displayName)** on \
                \(flow.hostnameToConfirm) with this dump.
                """)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(4)
            }
            Text("Type **\(flow.hostnameToConfirm)** to confirm.")
            TextField("Hostname", text: $flow.typedHostname)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 340)
                .accessibilityLabel("Type the server's hostname to confirm the restore")
        }
    }

    /// Tooltips that say what is missing while a button is disabled, which is
    /// when someone is most likely to hover over it.
    private var reviewHelp: String {
        guard flow.canReview else { return "Choose a snapshot first" }
        if flow.isDatabaseDump {
            return flow.loadIntoDatabase == nil
                ? "Choose which database this dump should be loaded into"
                : "Go on to the confirmation step; nothing is loaded yet"
        }
        return "Take a snapshot of what is there now, then show exactly what would change"
    }

    private var restoreHelp: String {
        flow.canConfirm
            ? (flow.isDatabaseDump
                ? "Load this dump into the chosen database on \(flow.hostnameToConfirm)"
                : "Write these files back to \(flow.hostnameToConfirm); the safety snapshot can undo it")
            : "Type the server's hostname to confirm"
    }

    private var footer: some View {
        HStack {
            Button("Cancel", action: onClose)
                .help("Close without changing anything on the server")
            Spacer()
            switch flow.stage {
            case .choosing:
                Button(flow.isDatabaseDump ? "Continue" : "Review changes") {
                    Task { await flow.prepare() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!flow.canReview || (flow.isDatabaseDump && flow.loadIntoDatabase == nil))
                .help(reviewHelp)
            case .reviewing:
                Button("Continue") { flow.proceedToConfirmation() }
                    .buttonStyle(.borderedProminent)
                    .help("Go on to the confirmation step; nothing is written yet")
            case .confirming:
                Button("Restore") { Task { await flow.run() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!flow.canConfirm)
                    .help(restoreHelp)
            case .preparing, .running, .authorizing:
                ProgressView().controlSize(.small)
            case .finished, .failed:
                Button("Done", action: onClose)
                    .buttonStyle(.borderedProminent)
                    .help("Close this window")
            }
        }
        .padding(20)
    }

    private func symbol(for kind: String) -> String {
        switch kind {
        case "added": "+"
        case "removed": "-"
        case "modified": "M"
        default: "~"
        }
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
