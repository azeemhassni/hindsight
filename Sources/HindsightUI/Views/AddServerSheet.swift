import SwiftUI

/// Hosts the onboarding wizard and guards the way out of it.
///
/// Closing the window after the server has been created but before the
/// recovery kit has been saved is the one exit worth interrupting: the backups
/// would start running and be unreadable if this Mac were lost.
public struct AddServerSheet: View {
    @Bindable var controller: OnboardingController
    let sudoersResticPath: String
    let onClose: () -> Void

    @State private var confirmingClose = false

    public init(
        controller: OnboardingController,
        sudoersResticPath: String,
        onClose: @escaping () -> Void
    ) {
        self.controller = controller
        self.sudoersResticPath = sudoersResticPath
        self.onClose = onClose
    }

    public var body: some View {
        OnboardingView(
            state: $controller.state,
            sudoersResticPath: sudoersResticPath,
            onScanHostKey: { await controller.scanHostKey() },
            onCheckPrivileges: { await controller.probeServer() },
            onDetect: { await controller.probeServer() },
            onChooseRepository: { controller.chooseRepositoryPath() },
            onStartFirstBackup: { await controller.startFirstBackup() },
            onExportRecoveryKit: { await controller.exportKit() },
            onContinue: { await controller.continueFromCurrentStep() },
            onFinish: onClose,
            errorText: controller.error,
            isBusy: controller.busy
        )
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    if controller.closingLosesRecoveryKit {
                        confirmingClose = true
                    } else {
                        onClose()
                    }
                }
                .help(
                    controller.closingLosesRecoveryKit
                        ? "Asks first: this server's password is not saved anywhere else yet"
                        : "Close without adding a server"
                )
            }
        }
        .alert("Save the recovery kit first", isPresented: $confirmingClose) {
            Button("Save it now") { Task { await controller.exportKit() } }
            Button("Close anyway", role: .destructive, action: onClose)
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("""
            \(controller.state.suggestedName) has been added and will be backed up, \
            but the repository password has not been saved anywhere outside this Mac. \
            Without it the backups cannot be read by anyone, ever. The server's view \
            keeps offering it until you do.
            """)
        }
    }
}
