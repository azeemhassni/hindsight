import HindsightCatalog
import HindsightCore
import HindsightProtocol
import HindsightUI
import SwiftUI

/// The app.
///
/// Deliberately thin: everything it shows lives in `HindsightUI`, so the
/// interface compiles and is tested by `swift test` rather than only inside
/// Xcode. The app's own job is the window, the menu bar item, and the
/// connection to the agent.
@main
struct HindsightApp: App {
    @State private var model = AppModel()
    @State private var connection = AgentConnection()
    @State private var catalog: CatalogReader?

    var body: some Scene {
        Window("Hindsight", id: "main") {
            RootView(
                model: model,
                snapshots: { serverID in snapshots(forServer: serverID) },
                repositorySize: { _ in nil }
            )
            .task { await start() }
        }
        .defaultSize(width: 1040, height: 700)
        .defaultPosition(.center)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Back Up Now") {
                    guard let id = model.selectedServerID else { return }
                    Task { await model.backUpNow(serverID: id) }
                }
                .keyboardShortcut("b", modifiers: [.command])
            }
        }

        // The item disappears when the app is quit; the agent carries on
        // backing up. The wording in the menu says so, so its absence cannot be
        // mistaken for backups having stopped.
        MenuBarExtra {
            MenuBarContent(
                model: model,
                onOpenWindow: {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                },
                onBackUpAll: {
                    Task {
                        for server in model.servers {
                            await model.backUpNow(serverID: server.id)
                        }
                    }
                }
            )
        } label: {
            MenuBarLabel(model: model)
        }

        Settings {
            Text("Settings live per server, in the server's own view.")
                .padding(40)
        }
    }

    @MainActor
    private func start() async {
        model.send = { [connection] request in await connection.send(request) }
        connection.onEvent = { [model] event in model.apply(event) }
        catalog = try? CatalogReader.open(at: catalogURL)
        await model.refresh()

        // The agent owns live state, but history lives in the catalog. If the
        // agent cannot be reached, show what is known rather than an empty
        // window — the banner already explains the connection.
        if case .unavailable = model.connection {
            model.populateFromCatalog(catalogSummaries())
        }
    }

    /// Overridable so the interface can be run against a catalog other than
    /// the installed one, without touching it.
    private var catalogURL: URL {
        if let override = ProcessInfo.processInfo.environment["HINDSIGHT_CATALOG_PATH"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hindsight/catalog.sqlite")
    }

    private func catalogSummaries() -> [CatalogServerSummary] {
        guard let catalog, let servers = try? catalog.servers() else { return [] }
        return servers.map { server in
            let lastBackup = (try? catalog.jobs(forServer: server.id, limit: 50))?
                .first { $0.state == .succeeded && $0.kind == .backup }?
                .finishedAt
            let check = (try? catalog.repository(forServer: server.id))
                .flatMap { repository in try? catalog.latestCheck(forRepository: repository.id) }
            return CatalogServerSummary(
                id: server.id.value,
                name: server.name,
                lastBackupAt: lastBackup,
                lastCheckPassed: check.map { $0.outcome == .passed },
                scheduleExplanation: "Schedule is known to the agent."
            )
        }
    }

    /// Read straight from the catalog rather than proxied over XPC: the agent
    /// is the only writer, and WAL means these reads never block it.
    private func snapshots(forServer serverID: String) -> [Snapshot] {
        guard let catalog, let id = try? ServerID(validating: serverID) else { return [] }
        return (try? catalog.snapshots(forServer: id)) ?? []
    }
}
