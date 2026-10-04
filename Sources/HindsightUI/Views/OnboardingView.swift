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
    let onExportRecoveryKit: () async -> Void
    /// Advancing is the controller's to do, not the view's: leaving a step can
    /// mean trusting a host key or creating the server.
    let onContinue: () async -> Void
    let onFinish: () -> Void
    let errorText: String?
    let isBusy: Bool

    public init(
        state: Binding<OnboardingState>,
        sudoersResticPath: String,
        onScanHostKey: @escaping () async -> Void,
        onCheckPrivileges: @escaping () async -> Void,
        onDetect: @escaping () async -> Void,
        onChooseRepository: @escaping () -> Void,
        onStartFirstBackup: @escaping () async -> Void,
        onExportRecoveryKit: @escaping () async -> Void,
        onContinue: @escaping () async -> Void,
        onFinish: @escaping () -> Void,
        errorText: String? = nil,
        isBusy: Bool = false
    ) {
        _state = state
        self.sudoersResticPath = sudoersResticPath
        self.onScanHostKey = onScanHostKey
        self.onCheckPrivileges = onCheckPrivileges
        self.onDetect = onDetect
        self.onChooseRepository = onChooseRepository
        self.onStartFirstBackup = onStartFirstBackup
        self.onExportRecoveryKit = onExportRecoveryKit
        self.onContinue = onContinue
        self.onFinish = onFinish
        self.errorText = errorText
        self.isBusy = isBusy
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
                .lineLimit(6)
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
                // A string binding rather than a number formatter: a
                // formatted field commits only when it loses focus, so a port
                // typed and then confirmed could be read as the old one.
                TextField("Port", text: portText)
                TextField("User", text: $state.user)
                TextField("Name (optional)", text: $state.name)
                    .help("Defaults to the host")
                Toggle("Use a key I already have", isOn: usesExistingKey)
                if state.identityFile != nil {
                    TextField("Key file", text: identityFileText)
                        .help("A private key file on this Mac, such as ~/.ssh/id_ed25519")
                }
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
                if state.privilegeMode == nil, state.sudoAvailable == nil, errorText == nil {
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
                } else if let mode = state.privilegeMode {
                    Label(
                        mode == .root ? "Connecting as root." : "Passwordless sudo works.",
                        systemImage: "checkmark.circle"
                    )
                    .foregroundStyle(.green)
                }
                // Always offered while the step is unsatisfied, whoever is
                // connecting: a probe that failed for any reason — the server
                // was asleep, the key was wrong — otherwise leaves the wizard
                // with no way forward and no way to try again.
                if state.privilegeMode == nil {
                    Button("Check again") { Task { await onCheckPrivileges() } }
                        .help("Try connecting to the server again")
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
                        .help("Choose the folder that will hold this server's backups")
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
                .lineLimit(6)

                Button("Save the recovery kit…", systemImage: "square.and.arrow.down") {
                    Task { await onExportRecoveryKit() }
                }
                .buttonStyle(.borderedProminent)
                .help("Write the repository password to a file you keep somewhere else")

                if state.recoveryKitExported {
                    Label("Saved.", systemImage: "checkmark.circle").foregroundStyle(.green)
                }
            }

        case .done:
            Label("This server is set up.", systemImage: "checkmark.seal")
                .foregroundStyle(.green)
        }
    }

    private var portText: Binding<String> {
        Binding(
            get: { String(state.port) },
            set: { text in
                let digits = text.filter(\.isNumber)
                state.port = Int(digits.prefix(5)) ?? 0
            }
        )
    }

    private var usesExistingKey: Binding<Bool> {
        Binding(
            get: { state.identityFile != nil },
            set: { state.identityFile = $0 ? (state.identityFile ?? "") : nil }
        )
    }

    private var identityFileText: Binding<String> {
        Binding(
            get: { state.identityFile ?? "" },
            set: { state.identityFile = $0 }
        )
    }

    private var footer: some View {
        HStack {
            Button("Back") { state.goBack() }
                .disabled(state.step == .connectionDetails || isBusy)
                .help("Go back a step")
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(6)
            } else if let reason = state.blockingReason {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(6)
            }
            Spacer()
            if state.step == .done {
                Button("Finish", action: onFinish)
                    .buttonStyle(.borderedProminent)
                    .help("Close this; the server is set up and will be backed up on its schedule")
            } else {
                if isBusy { ProgressView().controlSize(.small) }
                Button("Continue") { Task { await onContinue() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!state.canAdvance || isBusy)
                    // What is missing, when something is: a disabled Continue
                    // with no explanation is the worst moment in a wizard.
                    .help(state.blockingReason ?? "Go on to the next step")
            }
        }
        .padding(20)
    }
}
