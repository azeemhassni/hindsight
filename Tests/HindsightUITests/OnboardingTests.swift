import Foundation
import HindsightCore
import Testing
@testable import HindsightUI

@Suite("Onboarding")
struct OnboardingTests {
    private func readyToFinish() -> OnboardingState {
        var state = OnboardingState()
        state.host = "127.0.0.1"
        state.user = "root"
        state.hostKeyFingerprint = "SHA256:abc"
        state.hostKeyConfirmed = true
        state.privilegeMode = .root
        state.detectedPlatform = Platform(
            distributionID: "ubuntu", versionID: "24.04", prettyName: "Ubuntu 24.04",
            kernelRelease: "6.8", architecture: .aarch64
        )
        state.repositoryPath = "/Volumes/Backups/repos"
        state.firstBackupCompleted = true
        state.step = .exportRecoveryKit
        return state
    }

    @Test("will not finish until the recovery kit has been saved")
    func cannotSkipTheRecoveryKit() {
        var state = readyToFinish()
        #expect(state.step == .exportRecoveryKit)
        #expect(!state.canAdvance)
        #expect(state.blockingReason?.contains("Save the recovery kit") == true)

        // Advancing does nothing while it is unsaved.
        state.advance()
        #expect(state.step == .exportRecoveryKit)

        state.recoveryKitExported = true
        #expect(state.canAdvance)
        state.advance()
        #expect(state.step == .done)
    }

    @Test("needs a host, a user and a valid port before anything else")
    func requiresConnectionDetails() {
        var state = OnboardingState()
        #expect(!state.canAdvance)

        state.host = "198.51.100.10"
        #expect(state.canAdvance)

        state.port = 0
        #expect(!state.canAdvance)
        state.port = 70000
        #expect(!state.canAdvance)
        state.port = 22
        #expect(state.canAdvance)

        state.user = "   "
        #expect(!state.canAdvance)
    }

    @Test("needs the host key read and confirmed, not merely fetched")
    func requiresHostKeyConfirmation() {
        var state = OnboardingState()
        state.host = "198.51.100.10"
        state.advance()
        #expect(state.step == .confirmHostKey)
        #expect(!state.canAdvance)

        state.hostKeyFingerprint = "SHA256:abc"
        // Having the fingerprint is not the same as a person having checked it.
        #expect(!state.canAdvance)

        state.hostKeyConfirmed = true
        #expect(state.canAdvance)
    }

    @Test("going back to the host key makes it be confirmed again")
    func goingBackClearsConfirmation() {
        var state = OnboardingState()
        state.host = "198.51.100.10"
        state.hostKeyFingerprint = "SHA256:abc"
        state.hostKeyConfirmed = true
        state.step = .checkPrivileges

        state.goBack()
        #expect(state.step == .confirmHostKey)
        // Confirming a server's identity should never be a thing that happened
        // by accident on the way past.
        #expect(!state.hostKeyConfirmed)
    }

    @Test("explains what is blocking, at every step")
    func explainsEveryBlock() {
        for step in OnboardingStep.allCases where step != .done {
            var state = OnboardingState()
            state.step = step
            if !state.canAdvance {
                #expect(state.blockingReason?.isEmpty == false, "\(step) blocks without saying why")
            }
            #expect(!step.title.isEmpty)
            #expect(!step.explanation.isEmpty)
        }
    }

    @Test("says what to do when passwordless sudo is missing")
    func explainsMissingSudo() {
        var state = OnboardingState()
        state.step = .checkPrivileges
        state.sudoAvailable = false
        #expect(state.blockingReason?.contains("sudoers") == true)
    }

    @Test("the sudoers line is scoped to what Hindsight actually runs")
    func sudoersLineIsNarrow() {
        let line = OnboardingState().sudoersLine(
            user: "hindsight",
            resticPath: "/root/.cache/hindsight/restic-0.19.1"
        )
        #expect(line.contains("NOPASSWD:"))
        #expect(line.contains("/root/.cache/hindsight/restic-0.19.1"))
        // Not a blanket ALL, which would be a worse trade than connecting as
        // root in the first place.
        #expect(!line.contains("NOPASSWD: ALL"))
    }

    @Test("falls back to the host for a name")
    func namesTheServerSensibly() {
        var state = OnboardingState()
        state.host = "198.51.100.10"
        #expect(state.suggestedName == "198.51.100.10")
        state.name = "Web 01"
        #expect(state.suggestedName == "Web 01")
    }

    @Test("the steps run in the documented order")
    func stepsAreOrdered() {
        #expect(OnboardingStep.allCases == [
            .connectionDetails, .confirmHostKey, .checkPrivileges, .detectServer,
            .chooseRepository, .firstBackup, .exportRecoveryKit, .done,
        ])
        #expect(OnboardingStep.connectionDetails < OnboardingStep.done)
    }

    @Test("the kit step explains why it cannot be skipped")
    func kitStepExplainsItself() {
        #expect(OnboardingStep.exportRecoveryKit.explanation.contains("cannot be read"))
    }
}
