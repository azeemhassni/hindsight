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
    }

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
