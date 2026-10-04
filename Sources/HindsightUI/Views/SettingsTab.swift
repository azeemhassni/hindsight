import SwiftUI

/// The settings form, once the agent has said what the settings are.
///
/// Loaded rather than defaulted: a form that opens on defaults and saves what
/// it shows would quietly undo whatever was set before.
public struct SettingsTab: View {
    let flow: SettingsFlow?
    let serverID: String
    let onLoad: () async -> Void

    public init(
        flow: SettingsFlow?,
        serverID: String,
        onLoad: @escaping () async -> Void
    ) {
        self.flow = flow
        self.serverID = serverID
        self.onLoad = onLoad
    }

    public var body: some View {
        Group {
            if let flow {
                SettingsForm(flow: flow)
            } else {
                ProgressView("Reading this server's settings…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: serverID) {
            if flow == nil { await onLoad() }
        }
    }
}

struct SettingsForm: View {
    @Bindable var flow: SettingsFlow

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                ServerSettingsView(
                    cadence: $flow.cadence,
                    onlyOnACPower: $flow.onlyOnACPower,
                    retention: $flow.retention,
                    bandwidthLimitKiB: $flow.bandwidthLimitKiB,
                    repositoryPath: $flow.repositoryPath,
                    coolifyToken: $flow.coolifyToken,
                    checkRotationWeeks: $flow.checkRotationDivisor,
                    excludePatterns: $flow.excludePatterns
                )
                .padding(20)
            }
            Divider()
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let reason = flow.blockingReason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let failure = flow.lastSaveFailed {
                Label(failure, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if flow.isSaving { ProgressView().controlSize(.small) }
            Button("Save") { Task { await flow.save() } }
                .buttonStyle(.borderedProminent)
                .disabled(!flow.hasChanges || flow.blockingReason != nil || flow.isSaving)
                // The tooltip carries the reason when the button is disabled,
                // because a disabled button with no explanation is a dead end.
                .help(flow.blockingReason ?? "Send these changes to the agent; untouched settings are left alone")
        }
        .padding(12)
    }
}
