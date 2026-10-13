import HindsightProtocol
import SwiftUI

/// Connection details for a machine to restore onto.
public struct RestoreTargetSheet: View {
    @Bindable var flow: RestoreTargetFlow
    let onAdded: (String, String) -> Void
    let onClose: () -> Void

    public init(
        flow: RestoreTargetFlow,
        onAdded: @escaping (String, String) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.flow = flow
        self.onAdded = onAdded
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Restore onto another machine").font(.title3.bold())
                Text(flow.statusText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
            }
            .padding(20)
            Divider()
            ScrollView { content.padding(20).frame(maxWidth: .infinity, alignment: .leading) }
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 360)
    }

    @ViewBuilder
    private var content: some View {
        switch flow.stage {
        case .details, .failed:
            details
        case let .confirmingHostKey(report):
            hostKey(report)
        case .probing, .adding:
            ProgressView().frame(maxWidth: .infinity)
        case let .added(_, hostname, name):
            VStack(alignment: .leading, spacing: 8) {
                Label("\(name) is ready", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Text("""
                The next step confirms what gets written. You will be asked to \
                type \(hostname), and to approve it with Touch ID.
                """)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(4)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Host")
                    TextField("198.51.100.20 or host.example.com", text: $flow.host)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Port")
                    TextField("22", text: $flow.port)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 110)
                }
                GridRow {
                    Text("User")
                    TextField("root", text: $flow.user)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                }
                GridRow {
                    Text("Name")
                    TextField("Optional, for the list", text: $flow.name)
                        .textFieldStyle(.roundedBorder)
                }
            }
            Text("""
            This machine is recorded as somewhere to restore onto. Nothing on \
            it is backed up, and it gets no schedule of its own.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .lineLimit(4)

            if case let .failed(reason) = flow.stage {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(6)
            }
        }
    }

    private func hostKey(_ report: HostKeyReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fingerprint").font(.headline)
            Text(report.fingerprint)
                .monospaced()
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            Text("""
            Compare this with the machine itself before accepting it — run \
            `ssh-keygen -lf /etc/ssh/ssh_host_\(report.keyType.replacingOccurrences(of: "ssh-", with: ""))_key.pub` \
            there. Accepting a key nobody has checked is accepting whatever \
            answered on that address.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .lineLimit(6)
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel", action: onClose)
                .help("Close without adding a machine")
            Spacer()
            switch flow.stage {
            case .details, .failed:
                Button("Continue") { Task { await flow.scan() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!flow.canScan)
                    .help(flow.canScan
                        ? "Read this machine's host key so it can be compared"
                        : "A host, a port and a user are needed first")
            case .confirmingHostKey:
                Button("This fingerprint is right") { Task { await flow.confirmHostKey() } }
                    .buttonStyle(.borderedProminent)
                    .help("Trust this key and check the connection works")
            case .probing, .adding:
                Button("Working…") {}.disabled(true)
            case let .added(serverID, hostname, _):
                Button("Use this machine") { onAdded(serverID, hostname) }
                    .buttonStyle(.borderedProminent)
                    .help("Restore onto this machine")
            }
        }
        .padding(20)
    }
}
