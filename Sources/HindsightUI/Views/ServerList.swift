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
        List(selection: $selection) {
            if servers.isEmpty {
                ContentUnavailableView(
                    "No servers yet",
                    systemImage: "server.rack",
                    description: Text("Add a server to start backing it up.")
                )
            } else {
                Section("Servers") {
                    ForEach(servers, id: \.id) { server in
                        ServerRow(server: server, job: runningJob(server.id))
                            .tag(server.id)
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
                        ProgressView(value: job.percentDone ?? 0)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 70)
                        Text(Format.percent(job.percentDone))
                            .font(.caption)
                            .monospacedDigit()
                    }
                } else {
                    Text(Format.age(of: server.lastBackupAt))
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
        if let job {
            parts.append("Backing up, \(Format.percent(job.percentDone)) done.")
        } else {
            parts.append("Last backup \(Format.age(of: server.lastBackupAt)).")
        }
        return parts.joined(separator: " ")
    }
}
