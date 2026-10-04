import HindsightCore
import SwiftUI

/// The window: servers on the left, the chosen one on the right.
public struct RootView: View {
    @Bindable var model: AppModel
    let snapshots: (String) -> [Snapshot]
    let repositorySize: (String) -> Int64?

    public init(
        model: AppModel,
        snapshots: @escaping (String) -> [Snapshot],
        repositorySize: @escaping (String) -> Int64?
    ) {
        self.model = model
        self.snapshots = snapshots
        self.repositorySize = repositorySize
    }

    public var body: some View {
        NavigationSplitView {
            ServerListView(
                selection: $model.selectedServerID,
                servers: model.servers,
                runningJob: { model.runningJob(forServer: $0) }
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let server = model.selectedServer {
                ServerDetailView(
                    server: server,
                    job: model.runningJob(forServer: server.id),
                    snapshots: snapshots(server.id),
                    repositorySizeBytes: repositorySize(server.id),
                    onBackUpNow: {
                        Task { await model.backUpNow(serverID: server.id) }
                    }
                )
            } else {
                ContentUnavailableView(
                    "Nothing selected",
                    systemImage: "server.rack",
                    description: Text("Choose a server, or add one.")
                )
            }
        }
        .task { await model.refresh() }
        .safeAreaInset(edge: .bottom) {
            if case let .unavailable(reason) = model.connection {
                // Phrased so it cannot be read as "backups have stopped",
                // because they have not: the agent runs them, not the window.
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.yellow.opacity(0.2))
            }
        }
    }
}
