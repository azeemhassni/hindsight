import HindsightCore
import SwiftUI

/// Adding a server, step by step.
public struct OnboardingView: View {
    @Binding var state: OnboardingState
    let sudoersResticPath: String
    let onScanHostKey: () async -> Void
    let onCheckPrivileges: () async -> Void
    let onDetect: () async -> Void
    let onChooseRepository: () -> Void
    let onStartFirstBackup: () async -> Void
    let onExportRecoveryKit: () -> Void
    let onFinish: () -> Void

    public init(
        state: Binding<OnboardingState>,
        sudoersResticPath: String,
        onScanHostKey: @escaping () async -> Void,
        onCheckPrivileges: @escaping () async -> Void,
        onDetect: @escaping () async -> Void,
        onChooseRepository: @escaping () -> Void,
        onStartFirstBackup: @escaping () async -> Void,
        onExportRecoveryKit: @escaping () -> Void,
        onFinish: @escaping () -> Void
    ) {
        _state = state
        self.sudoersResticPath = sudoersResticPath
        self.onScanHostKey = onScanHostKey
        self.onCheckPrivileges = onCheckPrivileges
        self.onDetect = onDetect
        self.onChooseRepository = onChooseRepository
        self.onStartFirstBackup = onStartFirstBackup
        self.onExportRecoveryKit = onExportRecoveryKit
        self.onFinish = onFinish
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                step
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(minWidth: 580, minHeight: 440)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.step.title).font(.title3.bold())
            Text(state.step.explanation)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var step: some View {
        switch state.step {
        case .connectionDetails:
            Form {
                TextField("Host", text: $state.host)
                TextField("Port", value: $state.port, format: .number)
                TextField("User", text: $state.user)
                TextField("Name (optional)", text: $state.name)
                    .help("Defaults to the host")
            }
            .formStyle(.columns)
            .frame(maxWidth: 420)

        case .confirmHostKey:
            VStack(alignment: .leading, spacing: 12) {
                if let fingerprint = state.hostKeyFingerprint {
                    GroupBox {
                        Text(fingerprint)
                            .monospaced()
                            .textSelection(.enabled)
                            .padding(6)
                    }
                    Toggle("This matches what the server shows", isOn: $state.hostKeyConfirmed)
                    Text("""
                    Hindsight will refuse to connect if this key ever changes. \
                    That is the point of confirming it now.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } else {
                    ProgressView("Asking the server for its key…")
                        .task { await onScanHostKey() }
                }
            }

        case .checkPrivileges:
            VStack(alignment: .leading, spacing: 12) {
                if state.privilegeMode == nil, state.sudoAvailable == nil {
                    ProgressView("Checking…").task { await onCheckPrivileges() }
                }
                if state.sudoAvailable == false, state.user != "root" {
                    Text("Passwordless sudo is not available. Add this line with `visudo`:")
                    GroupBox {
                        Text(state.sudoersLine(user: state.user, resticPath: sudoersResticPath))
                            .monospaced()
                            .font(.caption)
                            .textSelection(.enabled)
                            .padding(6)
                    }
                    Text("""
                    It allows only the commands Hindsight runs, rather than \
                    everything — which would be a worse trade than connecting \
                    as root.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    Button("Check again") { Task { await onCheckPrivileges() } }
                } else if let mode = state.privilegeMode {
                    Label(
                        mode == .root ? "Connecting as root." : "Passwordless sudo works.",
                        systemImage: "checkmark.circle"
                    )
                    .foregroundStyle(.green)
                }
            }

        case .detectServer:
            VStack(alignment: .leading, spacing: 10) {
                if let platform = state.detectedPlatform {
                    Label(platform.prettyName, systemImage: "cpu")
                    Label(platform.architecture.rawValue, systemImage: "memorychip")
                    if let coolify = state.detectedCoolifyVersion {
                        Label("Coolify \(coolify)", systemImage: "shippingbox")
                    }
                } else {
                    ProgressView("Looking around…").task { await onDetect() }
                }
            }

        case .chooseRepository:
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(state.repositoryPath ?? "Not chosen")
                        .foregroundStyle(state.repositoryPath == nil ? .secondary : .primary)
                    Spacer()
                    Button("Choose…", action: onChooseRepository)
                }
                Text("""
                External disks are listed first. Whatever you choose needs room \
                to grow: the first backup is the largest, and history adds to it.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
            }

        case .firstBackup:
            VStack(alignment: .leading, spacing: 12) {
                if state.firstBackupCompleted {
                    Label("First backup finished.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else {
                    ProgressView("Backing up for the first time…")
                        .task { await onStartFirstBackup() }
                    Text("You can close this window; the backup carries on.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

        case .exportRecoveryKit:
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    """
                    Without the recovery kit, these backups cannot be read if \
                    this Mac is lost. There is no way around that, and no way \
                    for anyone to recover it for you.
                    """,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

                Button("Save the recovery kit…", systemImage: "square.and.arrow.down") {
                    onExportRecoveryKit()
                }
                .buttonStyle(.borderedProminent)

                if state.recoveryKitExported {
                    Label("Saved.", systemImage: "checkmark.circle").foregroundStyle(.green)
                }
            }

        case .done:
            Label("This server is set up.", systemImage: "checkmark.seal")
                .foregroundStyle(.green)
        }
    }

    private var footer: some View {
        HStack {
            Button("Back") { state.goBack() }
                .disabled(state.step == .connectionDetails)
            if let reason = state.blockingReason {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if state.step == .done {
                Button("Finish", action: onFinish).buttonStyle(.borderedProminent)
            } else {
                Button("Continue") { state.advance() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!state.canAdvance)
            }
        }
        .padding(20)
    }
}
