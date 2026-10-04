import HindsightCore
import SwiftUI

/// The window: servers on the left, the chosen one on the right.
public struct RootView: View {
    @Bindable var model: AppModel
    let snapshots: (String) -> [Snapshot]
    let repositorySize: (String) -> Int64?
    let exportRecoveryKit: () -> Void

    @State private var restoreFlow: RestoreFlow?

    public init(
        model: AppModel,
        snapshots: @escaping (String) -> [Snapshot],
        repositorySize: @escaping (String) -> Int64?,
        exportRecoveryKit: @escaping () -> Void = {}
    ) {
        self.model = model
        self.snapshots = snapshots
        self.repositorySize = repositorySize
        self.exportRecoveryKit = exportRecoveryKit
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
                if case let .unavailable(reason) = model.connection {
                    // Phrased so it cannot be read as "backups have stopped",
                    // because they have not: the agent runs them, not the
                    // window.
                    ConnectionBanner(reason: reason)
                }
                detailContent
            }
        }
        .task { await model.refresh() }
        .sheet(item: $restoreFlow) { flow in
            RestoreSheetView(
                flow: flow,
                snapshots: snapshots(flow.serverID),
                availabilityExplanations: Self.modeExplanations,
                onClose: { restoreFlow = nil }
            )
        }
        .onChange(of: model.activity.count) { _, _ in
            guard let flow = restoreFlow, let last = model.lastRestoreEvent else { return }
            flow.apply(last)
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
            Not available for restoring data. Coolify's rolling update replaces             a container, not its data: the new container mounts the same volume             as the old one.
            """
        ),
        (
            "minimalDowntime", "Minimal downtime", true,
            """
            Stages the restore while the service keeps running, then stops,             swaps it in, and starts again. The outage is the stop and start.
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
            ServerDetailView(
                server: server,
                job: model.runningJob(forServer: server.id),
                snapshots: snapshots(server.id),
                repositorySizeBytes: repositorySize(server.id),
                onBackUpNow: {
                    Task { await model.backUpNow(serverID: server.id) }
                },
                onRestore: {
                    restoreFlow = RestoreFlow(
                        model: model,
                        serverID: server.id,
                        serverHostname: server.name
                    )
                },
                onCheckIntegrity: {
                    Task { await model.checkIntegrity(serverID: server.id) }
                },
                onExportRecoveryKit: exportRecoveryKit
            )
        } else {
            ContentUnavailableView(
                "Nothing selected",
                systemImage: "server.rack",
                description: Text("Choose a server, or add one.")
            )
        }
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
