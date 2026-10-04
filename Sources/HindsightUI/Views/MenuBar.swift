import SwiftUI

/// The menu bar extra.
///
/// It belongs to the app rather than the agent, so quitting the app removes it
/// while backups carry on. The wording is chosen so that its absence can never
/// be read as "backups have stopped".
public struct MenuBarContent: View {
    let model: AppModel
    let onOpenWindow: () -> Void
    let onBackUpAll: () -> Void

    public init(model: AppModel, onOpenWindow: @escaping () -> Void, onBackUpAll: @escaping () -> Void) {
        self.model = model
        self.onOpenWindow = onOpenWindow
        self.onBackUpAll = onBackUpAll
    }

    public var body: some View {
        Group {
            Text(model.menuBarSummary)

            if let status = model.status, !status.servers.isEmpty {
                Divider()
                ForEach(model.servers, id: \.id) { server in
                    Button("\(server.name) — \(Format.age(of: server.lastBackupAt))") {
                        onOpenWindow()
                    }
                }
                Divider()
                Text("Next \(Format.timeUntil(status.nextBackupAt))")
            }

            Divider()
            Button("Back up now", action: onBackUpAll)
                .disabled(!model.runningJobs.isEmpty)
            Button("Open Hindsight", action: onOpenWindow)
            Divider()
            Button("Quit Hindsight") {
                #if canImport(AppKit)
                NSApplication.shared.terminate(nil)
                #endif
            }
            .keyboardShortcut("q")
        }
    }
}

/// What the menu bar shows at a glance.
public struct MenuBarLabel: View {
    let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Image(systemName: symbol)
            .accessibilityLabel("Hindsight. \(model.menuBarSummary)")
    }

    private var symbol: String {
        switch model.connection {
        case .connecting:
            return "clock.arrow.circlepath"
        case .unavailable:
            return "exclamationmark.triangle"
        case .connected:
            if !model.runningJobs.isEmpty { return "arrow.triangle.2.circlepath" }
            return model.status?.hasFailures == true
                ? "exclamationmark.triangle.fill"
                : "clock.arrow.2.circlepath"
        }
    }
}
