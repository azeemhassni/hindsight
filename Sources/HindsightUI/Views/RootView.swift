import HindsightCore
import HindsightProtocol
import SwiftUI

/// What a server's view is showing.
public enum ServerTab: String, CaseIterable, Hashable, Sendable {
    case overview
    case snapshots
    case coolify
    case logs
    case settings

    public var title: String {
        switch self {
        case .overview: "Overview"
        case .snapshots: "Snapshots"
        case .coolify: "Coolify"
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
    let preview: (String, SnapshotID, String) -> Void
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
        preview: @escaping (String, SnapshotID, String) -> Void = { _, _, _ in },
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
        self.preview = preview
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
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
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
            // Each server has its own history, settings and resources; keeping
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
            }
            ToolbarItem {
                Button("Restore…", systemImage: "arrow.counterclockwise") {
                    restoreFlow = flow(for: server)
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(snapshots(server.id).isEmpty)
            }
            ToolbarItem {
                Menu {
                    Button("Check integrity now", systemImage: "checkmark.seal") {
                        Task { await model.checkIntegrity(serverID: server.id) }
                    }
                    Button("Forget and prune now", systemImage: "scissors") {
                        Task { await model.runMaintenance(serverID: server.id) }
                    }
                    Button("Save recovery kit…", systemImage: "square.and.arrow.down") {
                        saveRecoveryKit(forServer: server.id)
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    /// What the restore sheet offers, and why the rest is not offered.
    ///
    /// Zero downtime is listed and refused on purpose: see `docs/COOLIFY.md`
    /// §9 for why it cannot be honest for a data restore.
    static let modeExplanations: [(mode: String, title: String, available: Bool, explanation: String)] = [
        (
            "zeroDowntime", "Zero downtime", false,
            """
            Not available for restoring data. Coolify's rolling update replaces \
            a container, not its data: the new container mounts the same volume \
            as the old one.
            """
        ),
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
                }
            )

        case .snapshots:
            SnapshotsTab(
                snapshots: snapshots(server.id),
                selection: $browsingSnapshotID,
                loadChildren: { snapshotID, path in
                    await browse(server.id, snapshotID, path)
                },
                onRestore: { snapshot, node in
                    let flow = flow(for: server)
                    flow.snapshotID = snapshot.id.value
                    if let node { flow.paths = [node.path] }
                    restoreFlow = flow
                },
                onPreview: { snapshot, node in
                    preview(server.id, snapshot.id, node.path)
                }
            )

        case .coolify:
            CoolifyTreeView(
                report: model.coolify[server.id],
                isLoading: model.discoveringCoolify.contains(server.id),
                failure: model.coolifyFailures[server.id],
                onRefresh: { await model.discoverCoolify(serverID: server.id) },
                onBackUp: { resource in
                    Task {
                        await model.backUpResource(
                            serverID: server.id,
                            resourceUUID: resource.uuid
                        )
                    }
                },
                onRestore: { resource in restoreResource(resource, server: server) }
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
                .frame(maxWidth: 280)
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

    private func flow(for server: ServerStatus) -> RestoreFlow {
        RestoreFlow(model: model, serverID: server.id, serverHostname: server.name)
    }

    /// Restoring a Coolify resource means restoring the snapshot taken of that
    /// resource: it holds its configuration directory and its volumes and
    /// nothing else, so the whole snapshot is the right scope.
    private func restoreResource(_ resource: CoolifyResourceReport, server: ServerStatus) {
        let tag = SnapshotTag.coolifyResource(resource.uuid).rawValue
        let candidates = snapshots(server.id)
            .filter { $0.tags.contains(tag) }
            .sorted { $0.time > $1.time }

        let flow = flow(for: server)
        flow.snapshotID = candidates.first?.id.value
        restoreFlow = flow
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
            Spacer(minLength: 8)
            Button("Save recovery kit…", action: onExport)
                .accessibilityLabel("Save the recovery kit for \(serverName)")
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
            Spacer(minLength: 8)
            Button("Open Login Items", action: onOpenSettings)
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
