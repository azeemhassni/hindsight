import HindsightCore
import HindsightProtocol
import SwiftUI

/// What a server's view is showing.
public enum ServerTab: String, CaseIterable, Hashable, Sendable {
    case overview
    case snapshots
    case logs
    case settings

    public var title: String {
        switch self {
        case .overview: "Overview"
        case .snapshots: "Snapshots"
        case .logs: "Logs"
        case .settings: "Settings"
        }
    }
}

/// The window: servers on the left, the chosen one on the right.
public struct RootView: View {
    @Bindable var model: AppModel
    let snapshots: (String) -> [Snapshot]
    let repositorySize: (String) -> Int64?
    let browse: (String, SnapshotID, String) async -> [SnapshotTreeNode]
    let searchSnapshot: (String, SnapshotID, String) async -> SnapshotSearchOutcome
    let preview: (String, SnapshotID, String) -> Void
    /// Writes a copy of one file onto the Mac. Returns nothing: it reports
    /// through the activity log, like every other long action.
    let saveCopy: (String, SnapshotID, String) -> Void
    /// Returns whether a kit was actually written, so onboarding can tell the
    /// difference between saving it and cancelling the dialog.
    let exportRecoveryKit: @MainActor @Sendable (String?) async -> Bool
    let chooseRepositoryDirectory: @MainActor @Sendable () -> String?
    let recoveryKits: any RecoveryKitRegistry
    let sudoersResticPath: String
    /// Opens Login Items, where the background agent is allowed or refused.
    let onOpenLoginItems: @MainActor @Sendable () -> Void

    @State private var restoreFlow: RestoreFlow?
    @State private var onboarding: OnboardingController?
    @State private var selectedJobID: String?
    @State private var browsingSnapshotID: String?
    @State private var settings: SettingsFlow?
    @State private var logSource: LogSource = .runs
    @State private var removing: ServerStatus?
    @State private var confirmingBackupDeletion: ServerStatus?

    enum LogSource: String, CaseIterable, Hashable {
        case runs
        case session

        var title: String {
            switch self {
            case .runs: "Runs"
            case .session: "This session"
            }
        }
    }

    public init(
        model: AppModel,
        snapshots: @escaping (String) -> [Snapshot],
        repositorySize: @escaping (String) -> Int64?,
        browse: @escaping (String, SnapshotID, String) async -> [SnapshotTreeNode] = { _, _, _ in [] },
        searchSnapshot: @escaping (String, SnapshotID, String) async -> SnapshotSearchOutcome
            = { _, _, _ in SnapshotSearchOutcome(nodes: []) },
        preview: @escaping (String, SnapshotID, String) -> Void = { _, _, _ in },
        saveCopy: @escaping (String, SnapshotID, String) -> Void = { _, _, _ in },
        exportRecoveryKit: @escaping @MainActor @Sendable (String?) async -> Bool = { _ in false },
        chooseRepositoryDirectory: @escaping @MainActor @Sendable () -> String? = { nil },
        recoveryKits: any RecoveryKitRegistry = InMemoryRecoveryKitRegistry(),
        sudoersResticPath: String = "/usr/local/bin/restic",
        onOpenLoginItems: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.model = model
        self.snapshots = snapshots
        self.repositorySize = repositorySize
        self.browse = browse
        self.searchSnapshot = searchSnapshot
        self.preview = preview
        self.saveCopy = saveCopy
        self.exportRecoveryKit = exportRecoveryKit
        self.chooseRepositoryDirectory = chooseRepositoryDirectory
        self.recoveryKits = recoveryKits
        self.sudoersResticPath = sudoersResticPath
        self.onOpenLoginItems = onOpenLoginItems
    }

    public var body: some View {
        // `NavigationSplitView` has to be the root of the scene. Wrapping it in
        // a stack collapses it to the sidebar's width, and attaching
        // `safeAreaInset` to it crashes SwiftUI's layout at launch — so the
        // connection banner lives at the top of the detail column instead.
        NavigationSplitView {
            ServerListView(
                selection: $model.selectedServerID,
                servers: model.servers,
                runningJob: { model.runningJob(forServer: $0) }
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 260)
        } detail: {
            VStack(spacing: 0) {
                if model.agentNeedsApproval {
                    // Different from a connection problem, and worth saying so:
                    // nothing is backing up until this is allowed.
                    ApprovalBanner(onOpenSettings: onOpenLoginItems)
                } else if case let .unavailable(reason) = model.connection {
                    // Phrased so it cannot be read as "backups have stopped",
                    // because they have not: the agent runs them, not the
                    // window.
                    ConnectionBanner(reason: reason)
                }
                detailContent
            }
        }
        .toolbar { toolbarContent }
        .task { await model.refresh() }
        .onChange(of: model.selectedServer?.id) { _, _ in
            // Each server has its own history and settings; keeping
            // the previous server's would be showing one server's data under
            // another's name.
            selectedJobID = nil
            browsingSnapshotID = nil
            settings = nil
        }
        .sheet(item: $restoreFlow) { flow in
            RestoreSheetView(
                flow: flow,
                snapshots: snapshots(flow.serverID),
                availabilityExplanations: Self.modeExplanations,
                otherServers: restoreDestinations(excluding: flow.serverID),
                makeTargetFlow: { RestoreTargetFlow(model: model) },
                onClose: { restoreFlow = nil }
            )
        }
        .sheet(item: $onboarding) { controller in
            AddServerSheet(
                controller: controller,
                sudoersResticPath: sudoersResticPath,
                onClose: { onboarding = nil }
            )
        }
        // Two steps on purpose: the first asks what should happen to the
        // backups, and deleting them has to be chosen again by name.
        .alert("Remove \(removing?.name ?? "this server")?", isPresented: removingBinding) {
            Button("Keep the backups") {
                guard let server = removing else { return }
                Task { await model.removeServer(serverID: server.id, deleteBackups: false) }
            }
            Button("Delete the backups too", role: .destructive) {
                confirmingBackupDeletion = removing
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Hindsight stops backing it up either way. Keeping the backups leaves the "
                    + "repository and the password that reads it on this Mac, so they can "
                    + "still be restored or moved somewhere else."
            )
        }
        .alert(
            "Delete every backup of \(confirmingBackupDeletion?.name ?? "this server")?",
            isPresented: deletingBackupsBinding
        ) {
            Button("Delete them", role: .destructive) {
                guard let server = confirmingBackupDeletion else { return }
                Task { await model.removeServer(serverID: server.id, deleteBackups: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Every snapshot of this server is deleted from this Mac, along with the "
                    + "password that reads them. There is no undo, and a recovery kit will "
                    + "not bring them back."
            )
        }
        .onChange(of: model.activity.count) { _, _ in
            if let flow = restoreFlow, let last = model.lastRestoreEvent {
                flow.apply(last)
            }
            onboarding?.noteActivity()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Button("Add server", systemImage: "plus") { startOnboarding() }
                .keyboardShortcut("n", modifiers: [.command])
                .help("Add a server to back up")
        }
        if let server = model.selectedServer {
            ToolbarItem {
                Button("Back up now", systemImage: "arrow.clockwise") {
                    Task { await model.backUpNow(serverID: server.id) }
                }
                .keyboardShortcut("b", modifiers: [.command])
                .disabled(model.runningJob(forServer: server.id) != nil)
                .help("Back this server up now, as well as on its schedule")
            }
            ToolbarItem {
                Button("Restore…", systemImage: "arrow.counterclockwise") {
                    restoreFlow = flow(for: server)
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(snapshots(server.id).isEmpty)
                .help("Choose a snapshot and put its files back on the server")
            }
            ToolbarItem {
                Menu {
                    Button(
                        server.isPaused ? "Resume backups" : "Pause backups",
                        systemImage: server.isPaused ? "play.circle" : "pause.circle"
                    ) {
                        Task { await model.setPaused(!server.isPaused, serverID: server.id) }
                    }
                    .help(
                        server.isPaused
                            ? "Let this server's schedule run again"
                            : "Stop scheduled backups for this server until you resume them"
                    )
                    Divider()
                    Button("Check integrity now", systemImage: "checkmark.seal") {
                        Task { await model.checkIntegrity(serverID: server.id) }
                    }
                    .help("Read the repository and check it against its own checksums")
                    Button("Forget and prune now", systemImage: "scissors") {
                        Task { await model.runMaintenance(serverID: server.id) }
                    }
                    .help("Apply the retention policy and delete the snapshots it no longer keeps")
                    Button("Save recovery kit…", systemImage: "square.and.arrow.down") {
                        saveRecoveryKit(forServer: server.id)
                    }
                    .help("Save this server's repository password somewhere other than this Mac")
                    Divider()
                    Button("Remove server…", systemImage: "trash", role: .destructive) {
                        removing = server
                    }
                    .help("Stop backing this server up and forget it")
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("Integrity checks, pruning, and the recovery kit")
            }
        }
    }

    /// What the restore sheet offers, and what each one costs.
    static let modeExplanations: [(mode: String, title: String, available: Bool, explanation: String)] = [
        (
            "minimalDowntime", "Minimal downtime", true,
            """
            Stages the restore while the service keeps running, then stops, \
            swaps it in, and starts again. The outage is the stop and start.
            """
        ),
        (
            "standard", "Standard", true,
            "Stops what is using the data, restores over it, and starts again."
        ),
    ]

    @ViewBuilder
    private var detailContent: some View {
        if let server = model.selectedServer {
            VStack(spacing: 0) {
                if server.isPaused {
                    PausedBanner(serverName: server.name) {
                        Task { await model.setPaused(false, serverID: server.id) }
                    }
                }
                if !recoveryKits.wasExported(forServer: server.id) {
                    RecoveryKitBanner(serverName: server.name) {
                        saveRecoveryKit(forServer: server.id)
                    }
                }
                Picker("View", selection: $model.tab) {
                    ForEach(ServerTab.allCases, id: \.self) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                tabContent(for: server)
            }
            .navigationTitle(server.name)
        } else {
            ContentUnavailableView {
                Label("Nothing selected", systemImage: "server.rack")
            } description: {
                Text("Choose a server, or add one.")
            } actions: {
                Button("Add a server…") { startOnboarding() }
                    .help("Connect to a server over ssh and start backing it up")
            }
        }
    }

    @ViewBuilder
    private func tabContent(for server: ServerStatus) -> some View {
        switch model.tab {
        case .overview:
            ServerDetailView(
                server: server,
                job: model.runningJob(forServer: server.id),
                snapshots: snapshots(server.id),
                repositorySizeBytes: repositorySize(server.id),
                onOpenSnapshot: { snapshot in
                    browsingSnapshotID = snapshot.id.value
                    model.tab = .snapshots
                },
                onStopWork: {
                    Task { await model.stopWork(serverID: server.id) }
                }
            )

        case .snapshots:
            SnapshotsTab(
                snapshots: snapshots(server.id),
                selection: $browsingSnapshotID,
                loadChildren: { snapshotID, path in
                    await browse(server.id, snapshotID, path)
                },
                search: { snapshotID, term in
                    await searchSnapshot(server.id, snapshotID, term)
                },
                onRestore: { snapshot, node in
                    let flow = flow(for: server)
                    flow.snapshotID = snapshot.id.value
                    if let node { flow.paths = [node.path] }
                    restoreFlow = flow
                },
                onPreview: { snapshot, node in
                    preview(server.id, snapshot.id, node.path)
                },
                onSaveCopy: { snapshot, node in
                    saveCopy(server.id, snapshot.id, node.path)
                }
            )

        case .logs:
            VStack(spacing: 0) {
                Picker("Show", selection: $logSource) {
                    ForEach(LogSource.allCases, id: \.self) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(minWidth: 160, idealWidth: 280, maxWidth: 280)
                .padding(8)
                Divider()
                switch logSource {
                case .runs:
                    JobHistoryView(
                        jobs: model.jobs[server.id] ?? [],
                        log: selectedJobID.flatMap { model.jobLogs[$0] } ?? [],
                        selection: $selectedJobID,
                        onReload: { await model.loadJobs(serverID: server.id) }
                    )
                    .onChange(of: selectedJobID) { _, id in
                        guard let id else { return }
                        Task { await model.loadLog(jobID: id) }
                    }
                case .session:
                    ActivityLogView(entries: model.activity)
                }
            }

        case .settings:
            SettingsTab(
                flow: settings,
                serverID: server.id,
                onLoad: {
                    guard let report = await model.serverSettings(serverID: server.id) else { return }
                    settings = SettingsFlow.from(report, model: model)
                }
            )
        }
    }

    private var removingBinding: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }

    private var deletingBackupsBinding: Binding<Bool> {
        Binding(
            get: { confirmingBackupDeletion != nil },
            set: { if !$0 { confirmingBackupDeletion = nil } }
        )
    }

    /// Machines a snapshot could be written to, other than the one it came
    /// from. Only servers Hindsight already knows: their host keys have been
    /// confirmed and their connections are managed, and a restore is the last
    /// thing that should reach a machine nobody has checked.
    private func restoreDestinations(excluding serverID: String) -> [RestoreDestination] {
        model.servers
            .filter { $0.id != serverID }
            .map { RestoreDestination(id: $0.id, name: $0.name, hostname: $0.hostname) }
    }

    private func flow(for server: ServerStatus) -> RestoreFlow {
        // The ssh host, not the display name: the agent checks what was typed
        // against the host it is connected to, so asking for anything else
        // would have the restore refused after the person typed exactly what
        // the sheet asked for.
        RestoreFlow(model: model, serverID: server.id, serverHostname: server.hostname)
    }

    private func startOnboarding() {
        onboarding = OnboardingController(
            model: model,
            chooseRepository: chooseRepositoryDirectory,
            exportRecoveryKit: { serverID in
                let saved = await exportRecoveryKit(serverID)
                if saved { recoveryKits.markExported(forServer: serverID) }
                return saved
            }
        )
    }

    private func saveRecoveryKit(forServer id: String) {
        Task {
            if await exportRecoveryKit(id) {
                recoveryKits.markExported(forServer: id)
            }
        }
    }
}

/// Shown while a server's schedule is stopped.
///
/// Prominent on purpose: a server that is not being backed up should never be
/// quietly indistinguishable from one that is.
struct PausedBanner: View {
    let serverName: String
    let onResume: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle.fill")
                .accessibilityHidden(true)
            Text("Backups of \(serverName) are paused. Nothing is being backed up.")
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Resume", action: onResume)
                .help("Let this server's schedule run again")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.22))
        .accessibilityElement(children: .combine)
    }
}

/// Shown until a server's password exists somewhere other than this Mac.
///
/// It stays rather than appearing once, because the cost of ignoring it only
/// becomes visible at the worst possible moment.
struct RecoveryKitBanner: View {
    let serverName: String
    let onExport: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.horizontal")
                .accessibilityHidden(true)
            Text("""
            The password for \(serverName)'s backups exists only on this Mac. \
            Without it they cannot be read, by anyone, ever.
            """)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .lineLimit(6)
            Spacer(minLength: 8)
            Button("Save recovery kit…", action: onExport)
                .accessibilityLabel("Save the recovery kit for \(serverName)")
                .help("Without it, these backups cannot be read if this Mac is lost")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.18))
        .accessibilityElement(children: .combine)
    }
}

/// Shown while macOS is waiting for the person to allow the agent.
struct ApprovalBanner: View {
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("""
            Hindsight's background agent is waiting to be allowed in Login \
            Items. Nothing is backed up until it is.
            """)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .lineLimit(6)
            Spacer(minLength: 8)
            Button("Open Login Items", action: onOpenSettings)
                .help("Open Login Items in System Settings, where the agent is allowed to run")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.18))
        .accessibilityElement(children: .combine)
    }
}

struct ConnectionBanner: View {
    let reason: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .accessibilityHidden(true)
            Text(reason)
                .font(.callout)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.18))
        .accessibilityElement(children: .combine)
    }
}
