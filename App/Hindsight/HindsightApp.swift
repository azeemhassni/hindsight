import HindsightCatalog
import HindsightCore
import HindsightProtocol
import HindsightUI
import SwiftUI

func note(_ text: String) {
    let url = URL(fileURLWithPath: "/tmp/hindsight-debug.log")
    let line = Data("\(Date()) \(text)\n".utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        try? handle.write(contentsOf: line)
        try? handle.close()
    } else {
        try? line.write(to: url)
    }
}

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
    /// A reference type on purpose. The closures handed to `RootView` are
    /// built while `body` runs and capture this struct; a `@State` value set
    /// afterwards is invisible to them, which is how the snapshot list came up
    /// empty with the catalog open. An object is shared rather than copied.
    @State private var catalogStore = CatalogStore()
    @State private var sizes = RepositorySizeStore()
    private let recoveryKits = DefaultsRecoveryKitRegistry()

    init() {
        // Before the scene exists, because the window is built from what macOS
        // remembered.
        WindowGeometry.discardIfLargerThanScreen()
    }

    var body: some Scene {
        Window("Hindsight", id: "main") {
            RootView(
                model: model,
                snapshots: { serverID in snapshots(forServer: serverID) },
                repositorySize: { serverID in
                    _ = model.catalogRevision
                    return sizes.bytes(forServer: serverID)
                },
                browse: { serverID, snapshot, path in
                    await browse(serverID: serverID, snapshot: snapshot, path: path)
                },
                searchSnapshot: { serverID, snapshot, term in
                    await search(serverID: serverID, snapshot: snapshot, term: term)
                },
                preview: { serverID, snapshot, path in
                    Task { await preview(serverID: serverID, snapshot: snapshot, path: path) }
                },
                saveCopy: { serverID, snapshot, path in
                    Task { await saveCopy(serverID: serverID, snapshot: snapshot, path: path) }
                },
                exportRecoveryKit: { serverID in
                    await RecoveryKitExport.save(await model.recoveryKit(serverID: serverID))
                },
                chooseRepositoryDirectory: { RepositoryChooser.run() },
                recoveryKits: recoveryKits,
                sudoersResticPath: "/usr/local/bin/restic",
                onOpenLoginItems: { AgentInstallation.openLoginItemsSettings() }
            )
            .task { await start() }
            // Sizes are a directory walk, so they are recomputed when a job
            // has actually changed the repository rather than on every
            // refresh. The heartbeat keeps relative times ("20h ago") honest
            // and catches anything that arrives without an event — one status
            // request a minute, which is nothing next to a backup.
            .task(id: model.repositoryContentsChanged) {
                guard model.repositoryContentsChanged > 0 else { return }
                await refreshSizes()
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    await model.refresh()
                }
            }
        }
        .defaultSize(width: 1040, height: 700)
        .defaultPosition(.center)
        // Without this the window takes its height from the content and then
        // refuses to be resized at all vertically, which is not how a Mac
        // window behaves. `contentMinSize` keeps a floor and no ceiling.
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Back Up Now") {
                    guard let id = model.selectedServerID else { return }
                    Task { await model.backUpNow(serverID: id) }
                }
                .keyboardShortcut("b", modifiers: [.command])
            }
            // One shortcut per part of a server's view, in the order they
            // appear, which is what every other Mac app with tabs does.
            CommandGroup(before: .toolbar) {
                ForEach(Array(ServerTab.allCases.enumerated()), id: \.element) { index, tab in
                    Button(tab.title) { model.tab = tab }
                        .keyboardShortcut(
                            KeyEquivalent(Character("\(index + 1)")),
                            modifiers: [.command]
                        )
                }
                Divider()
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
        // Registered before the first request: the agent is launched on demand
        // by launchd, and it cannot be if launchd has never been told about it.
        let installation = AgentInstallation.registerIfNeeded()
        if let explanation = installation.explanation {
            model.note(explanation, level: .warning)
            model.agentNeedsApproval = installation == .needsApproval
            // Said in the banner too: "the agent is not responding" is true but
            // useless when the reason is that it was never registered.
            if case .failed = installation {
                model.connection = .unavailable(reason: explanation)
            }
        }

        // After the first layout, so the window exists to be constrained.
        WindowFloor.applyWhenSettled(
            minWidth: 720,
            minHeight: 420,
            openingSize: NSSize(width: 1040, height: 700)
        )

        model.send = { [connection] request in await connection.send(request) }
        connection.onEvent = { [model] event in model.apply(event) }
        catalogStore.open(at: catalogURL)
        await model.refresh()

        // A registration that launchd does not actually have looks exactly like
        // an agent that is not answering. Re-submitting it costs a moment and
        // fixes the common causes: the bundle moved, or the job was removed by
        // hand.
        if case .unavailable = model.connection, installation.isUsable {
            let repaired = await AgentInstallation.reregister()
            if repaired.isUsable {
                try? await Task.sleep(for: .seconds(1))
                await model.refresh()
            } else if let explanation = repaired.explanation {
                model.connection = .unavailable(reason: explanation)
            }
        }

        // An update replaces the agent inside the bundle, but launchd keeps
        // running the old executable until it exits. Noticed here rather than
        // left to confuse: the window would be talking to the previous build.
        if let status = model.status,
           !AgentInstallation.isRunningAgentCurrent(reportedIdentity: status.binaryIdentity) {
            await model.restartAgent()
            try? await Task.sleep(for: .seconds(2))
            await model.refresh()
        }

        // The agent owns live state, but history lives in the catalog. If the
        // agent cannot be reached, show what is known rather than an empty
        // window — the banner already explains the connection.
        if case .unavailable = model.connection {
            model.populateFromCatalog(catalogSummaries())
        }
        await refreshSizes()
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
        guard let catalog = catalogStore.reader,
              let servers = try? catalog.servers()
        else { return [] }
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
    ///
    /// Reading `catalogRevision` is what makes this reactive. SQLite tells
    /// SwiftUI nothing, so without an observed value touched here the list a
    /// view drew first is the list it keeps until something unrelated
    /// redraws it. This runs inside a view's body, which is where the
    /// dependency has to be registered.
    private func snapshots(forServer serverID: String) -> [Snapshot] {
        _ = model.catalogRevision
        guard let catalog = catalogStore.reader,
              let id = try? ServerID(validating: serverID)
        else { return [] }
        return (try? catalog.snapshots(forServer: id)) ?? []
    }

    /// Lists one directory of a snapshot, through the agent.
    ///
    /// The agent reads the repository because it holds the password; the app
    /// holds none at all, which is why it needs no shared keychain group and
    /// no provisioning profile.
    private func browse(
        serverID: String,
        snapshot: SnapshotID,
        path: String
    ) async -> [SnapshotTreeNode] {
        let nodes = await model.snapshotDirectory(
            serverID: serverID,
            snapshotID: snapshot.value,
            path: path
        )
        return nodes.map(SnapshotTreeNode.init(report:))
    }

    private func search(
        serverID: String,
        snapshot: SnapshotID,
        term: String
    ) async -> SnapshotSearchOutcome {
        let found = await model.searchSnapshot(
            serverID: serverID,
            snapshotID: snapshot.value,
            term: term
        )
        return SnapshotSearchOutcome(
            nodes: found.nodes.map(SnapshotTreeNode.init(report:)),
            truncated: found.truncated,
            failure: found.failure
        )
    }

    /// Writes one file out of a snapshot onto this Mac.
    ///
    /// Not a restore: nothing is sent to the server, which is the point of
    /// being able to look inside a backup and take one file out of it.
    private func saveCopy(serverID: String, snapshot: SnapshotID, path: String) async {
        guard let extracted = await model.extractFile(
            serverID: serverID,
            snapshotID: snapshot.value,
            path: path
        ) else { return }

        let source = URL(fileURLWithPath: extracted)
        guard let destination = FileExport.chooseDestination(named: source.lastPathComponent) else {
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
            model.note("Saved \(source.lastPathComponent) to \(destination.path).", level: .info)
        } catch {
            model.note("Could not save \(source.lastPathComponent): \(error)", level: .error)
        }
    }

    /// Shows one file out of a snapshot, without restoring it.
    private func preview(serverID: String, snapshot: SnapshotID, path: String) async {
        guard let file = await model.extractFile(
            serverID: serverID,
            snapshotID: snapshot.value,
            path: path
        ) else { return }
        QuickLookPreview.show(URL(fileURLWithPath: file))
    }

    /// Repository sizes are walked in the background and cached: the number is
    /// worth showing, and walking a large repository on the main actor is not.
    private func refreshSizes() async {
        guard let catalog = catalogStore.reader, let servers = try? catalog.servers() else { return }
        for server in servers {
            guard let repository = try? catalog.repository(forServer: server.id) else { continue }
            if let bytes = await DirectorySize.bytesOffMainActor(at: repository.path) {
                sizes.record(bytes, forServer: server.id.value)
            }
        }
    }
}
