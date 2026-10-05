import HindsightProtocol
import SwiftUI

/// The sidebar.
///
/// Health is carried by a symbol and a label as well as a colour, because a
/// coloured dot alone says nothing to a screen reader and little to anyone who
/// does not already know the convention.
public struct ServerListView: View {
    @Binding var selection: String?
    let servers: [ServerStatus]
    let runningJob: (String) -> RunningJob?

    public init(
        selection: Binding<String?>,
        servers: [ServerStatus],
        runningJob: @escaping (String) -> RunningJob?
    ) {
        _selection = selection
        self.servers = servers
        self.runningJob = runningJob
    }

    public var body: some View {
        // The empty state replaces the list rather than sitting inside it:
        // `ContentUnavailableView` as a row crashes SwiftUI's layout, which is
        // the first thing the window does before any data has arrived.
        Group {
            if servers.isEmpty {
                ContentUnavailableView(
                    "No servers yet",
                    systemImage: "server.rack",
                    description: Text("Add a server to start backing it up.")
                )
            } else {
                List(selection: $selection) {
                    Section("Servers") {
                        ForEach(servers, id: \.id) { server in
                            ServerRow(server: server, job: runningJob(server.id))
                                .tag(server.id)
                        }
                    }
                }
            }
        }
        .navigationTitle("Hindsight")
    }
}

struct ServerRow: View {
    let server: ServerStatus
    let job: RunningJob?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: server.health.symbolName)
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .lineLimit(1)
                if let job {
                    HStack(spacing: 6) {
                        if job.showsPercentage {
                            ProgressView(value: job.percentDone ?? 0)
                                .progressViewStyle(.linear)
                                .frame(maxWidth: 70)
                            Text(Format.percent(job.percentDone))
                                .font(.caption)
                                .monospacedDigit()
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                                .frame(maxWidth: 70)
                            Text(job.phaseLabel)
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                } else {
                    HStack(spacing: 5) {
                        if server.isPaused {
                            Image(systemName: "pause.circle.fill")
                                .accessibilityHidden(true)
                        }
                        Text(
                            server.isPaused
                                ? "Paused"
                                : Format.age(of: server.lastBackupAt)
                        )
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var tint: Color {
        switch server.health {
        case .healthy: .green
        case .stale: .orange
        case .failing: .red
        case .unknown: .secondary
        }
    }

    private var accessibilityLabel: String {
        var parts = [server.name, server.health.accessibilityDescription]
        if server.isPaused {
            parts.append("Backups are paused.")
        }
        if let reason = server.healthReason {
            parts.append(reason)
        }
        if let job {
            // A running job with no progress yet reads as "Backing up." rather
            // than "Backing up, — done.", which is what the dash renders as.
            if let percent = job.percentDone {
                parts.append("Backing up, \(Format.percent(percent)) done.")
            } else {
                parts.append("Backing up.")
            }
        } else {
            parts.append("Last backup \(Format.age(of: server.lastBackupAt)).")
        }
        return parts.joined(separator: " ")
    }
}
