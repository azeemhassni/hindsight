import Foundation
import HindsightCore
import HindsightProtocol
import Testing
@testable import HindsightUI

@MainActor
@Suite("Onboarding controller")
struct OnboardingControllerTests {
    final class Recorder {
        var requests: [AgentRequest] = []
    }

    private func makeController(
        chooseRepository: @escaping @MainActor @Sendable () -> String? = { "/Volumes/Backups" },
        exportRecoveryKit: @escaping @MainActor @Sendable (String) async -> Bool = { _ in true },
        reply: @escaping @MainActor (AgentRequest) async -> AgentResponse?
    ) -> (OnboardingController, Recorder) {
        let recorder = Recorder()
        let model = AppModel()
        model.send = { request in
            recorder.requests.append(request)
            return await reply(request)
        }
        let controller = OnboardingController(
            model: model,
            chooseRepository: chooseRepository,
            exportRecoveryKit: exportRecoveryKit
        )
        controller.state.host = "198.51.100.1"
        controller.state.user = "root"
        return (controller, recorder)
    }

    private let hostKey = HostKeyReport(
        keyType: "ssh-ed25519",
        base64Key: "AAAAC3NzaC1lZDI1NTE5",
        fingerprint: "SHA256:abcdef"
    )

    private let probe = ServerProbeReport(
        prettyName: "Ubuntu 24.04.1 LTS",
        architecture: "x86_64",
        hasPasswordlessSudo: false,
        dockerVersion: "27.3.1",
        coolifyVersion: "4.3.23",
        homeDirectory: "/root",
        isTestTarget: false
    )

    @Test("shows the fingerprint it was given, and records it only on continuing")
    func trustsOnlyWhenContinuing() async {
        let (controller, recorder) = makeController { request in
            switch request {
            case .scanHostKey: .hostKey(self.hostKey)
            case .trustHostKey: .done
            default: .done
            }
        }
        controller.state.step = .confirmHostKey
        await controller.scanHostKey()
        #expect(controller.state.hostKeyFingerprint == "SHA256:abcdef")
        // Seeing a key is not trusting it: nothing is written to known_hosts
        // until the person says it matches and moves on.
        #expect(!recorder.requests.contains { if case .trustHostKey = $0 { true } else { false } })

        controller.state.hostKeyConfirmed = true
        await controller.continueFromCurrentStep()
        #expect(recorder.requests.contains { if case .trustHostKey = $0 { true } else { false } })
        #expect(controller.state.step == .checkPrivileges)
    }

    @Test("stays on the host key step if the key could not be recorded")
    func staysOnFailureToTrust() async {
        let (controller, _) = makeController { request in
            switch request {
            case .scanHostKey: .hostKey(self.hostKey)
            case .trustHostKey: .failed(message: "known_hosts is not writable")
            default: .done
            }
        }
        controller.state.step = .confirmHostKey
        await controller.scanHostKey()
        controller.state.hostKeyConfirmed = true
        await controller.continueFromCurrentStep()
        #expect(controller.state.step == .confirmHostKey)
        #expect(controller.error?.contains("known_hosts") == true)
    }

    @Test("one probe answers both the access question and the detection question")
    func probeFillsBothSteps() async {
        let (controller, recorder) = makeController { request in
            if case .probeServer = request { return .probe(self.probe) }
            return .done
        }
        controller.state.user = "deploy"
        controller.state.step = .checkPrivileges
        await controller.probeServer()

        #expect(recorder.requests.count == 1)
        #expect(controller.state.sudoAvailable == false)
        // No sudo and not root, so the step is blocked and says why rather
        // than letting a backup fail later.
        #expect(controller.state.privilegeMode == nil)
        #expect(controller.state.blockingReason?.contains("sudo") == true)
        #expect(controller.state.detectedPlatform?.prettyName == "Ubuntu 24.04.1 LTS")
        #expect(controller.state.detectedCoolifyVersion == "4.3.23")
    }

    @Test("connecting as root is enough on its own")
    func rootNeedsNoSudo() async {
        let (controller, _) = makeController { _ in .probe(self.probe) }
        await controller.probeServer()
        #expect(controller.state.privilegeMode == .root)
    }

    @Test("creates the server when the repository has been chosen, and only once")
    func addsServerAfterRepository() async {
        let (controller, recorder) = makeController { request in
            if case .addServer = request { return .serverAdded(serverID: "web-01") }
            return .done
        }
        controller.state.step = .chooseRepository
        controller.chooseRepositoryPath()
        #expect(controller.state.repositoryPath == "/Volumes/Backups")

        await controller.continueFromCurrentStep()
        #expect(controller.addedServerID == "web-01")
        #expect(controller.state.step == .firstBackup)

        // Going back and forward again must not add a second server.
        controller.state.goBack()
        await controller.continueFromCurrentStep()
        let adds = recorder.requests.filter { if case .addServer = $0 { true } else { false } }
        #expect(adds.count == 1)
    }

    @Test("the draft carries what was typed, including a key the person already has")
    func buildsDraft() {
        let (controller, _) = makeController { _ in .done }
        controller.state.name = "Web 01"
        controller.state.port = 2222
        controller.state.identityFile = "/Users/me/.ssh/id_ed25519"
        controller.state.repositoryPath = "/Volumes/Backups"

        #expect(controller.draft.name == "Web 01")
        #expect(controller.draft.port == 2222)
        #expect(controller.draft.identityFile == "/Users/me/.ssh/id_ed25519")
        #expect(controller.draft.repositoryPath == "/Volumes/Backups")
    }

    @Test("a name that was left blank falls back to the host")
    func namesAfterHost() {
        let (controller, _) = makeController { _ in .done }
        #expect(controller.draft.name == "198.51.100.1")
    }

    @Test("notices the first backup finishing without polling")
    func noticesFirstBackup() async {
        let (controller, _) = makeController { request in
            if case .backUpNow = request { return .accepted(jobID: "job-1") }
            return .status(AgentStatus(version: "test", servers: [], runningJobs: []))
        }
        controller.addedServerID = "web-01"
        controller.state.step = .firstBackup
        await controller.startFirstBackup()
        #expect(controller.firstBackupJobID == "job-1")
        #expect(!controller.state.firstBackupCompleted)

        controller.state.hostKeyConfirmed = true
        model(controller).apply(
            .jobFinished(id: "job-1", serverID: "web-01", succeeded: true, message: nil)
        )
        controller.noteActivity()
        #expect(controller.state.firstBackupCompleted)
    }

    @Test("a failed first backup says so rather than looking finished")
    func reportsFailedFirstBackup() async {
        let (controller, _) = makeController { request in
            if case .backUpNow = request { return .accepted(jobID: "job-1") }
            return .status(AgentStatus(version: "test", servers: [], runningJobs: []))
        }
        controller.addedServerID = "web-01"
        await controller.startFirstBackup()
        model(controller).apply(
            .jobFinished(id: "job-1", serverID: "web-01", succeeded: false, message: "disk full")
        )
        controller.noteActivity()
        #expect(!controller.state.firstBackupCompleted)
        #expect(controller.error?.contains("failed") == true)
    }

    @Test("closing after the server exists but before the kit is saved is flagged")
    func flagsClosingWithoutAKit() async {
        let (controller, _) = makeController { _ in .done }
        #expect(!controller.closingLosesRecoveryKit)
        controller.addedServerID = "web-01"
        // The server is now being backed up with a password that exists
        // nowhere else, which is the one exit worth interrupting.
        #expect(controller.closingLosesRecoveryKit)
        await controller.exportKit()
        #expect(controller.state.recoveryKitExported)
        #expect(!controller.closingLosesRecoveryKit)
    }

    @Test("a cancelled save dialog does not count as having saved the kit")
    func cancelledExportDoesNotCount() async {
        let (controller, _) = makeController(exportRecoveryKit: { _ in false }) { _ in .done }
        controller.addedServerID = "web-01"
        await controller.exportKit()
        #expect(!controller.state.recoveryKitExported)
        #expect(controller.closingLosesRecoveryKit)
    }

    /// Reaches the model the controller was built with, for the event tests.
    private func model(_ controller: OnboardingController) -> AppModel {
        controller.testModel
    }
}
