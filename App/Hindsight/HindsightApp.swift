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
    }

    private var catalogURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hindsight/catalog.sqlite")
    }

    /// Read straight from the catalog rather than proxied over XPC: the agent
    /// is the only writer, and WAL means these reads never block it.
    private func snapshots(forServer serverID: String) -> [Snapshot] {
        guard let catalog, let id = try? ServerID(validating: serverID) else { return [] }
        return (try? catalog.snapshots(forServer: id)) ?? []
    }
}
