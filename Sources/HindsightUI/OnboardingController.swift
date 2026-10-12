import Foundation
import HindsightCore
import HindsightProtocol
import Observation

/// Drives adding a server: the state machine plus the requests each step needs.
///
/// Separate from the view so the order of operations — trust the host key
/// before connecting, add the server before the first backup, never finish
/// without a recovery kit — can be tested without an interface.
@MainActor
@Observable
public final class OnboardingController: Identifiable {
    public let id = UUID()
    public var state = OnboardingState()
    public var hostKey: HostKeyReport?
    public var probe: ServerProbeReport?
    public var error: String?
    public var busy = false
    /// Set once the agent has accepted the server; everything after this point
    /// is about a server that exists.
    public var addedServerID: String?
    public var firstBackupJobID: String?

    private let model: AppModel
    private let chooseRepository: @MainActor () -> String?
    private let exportRecoveryKit: @MainActor (String) async -> Bool

    public init(
        model: AppModel,
        chooseRepository: @escaping @MainActor () -> String?,
        exportRecoveryKit: @escaping @MainActor (String) async -> Bool
    ) {
        self.model = model
        self.chooseRepository = chooseRepository
        self.exportRecoveryKit = exportRecoveryKit
    }

    /// Exposed for tests that need to feed the model an agent event.
    var testModel: AppModel { model }

    public var draft: AddServerDraft {
        AddServerDraft(
            name: state.suggestedName,
            host: state.host.trimmingCharacters(in: .whitespaces),
            port: state.port,
            user: state.user.trimmingCharacters(in: .whitespaces),
            identityFile: state.identityFile,
            repositoryPath: state.repositoryPath
        )
    }

    public func scanHostKey() async {
        busy = true
        defer { busy = false }
        guard let report = await model.scanHostKey(
            host: state.host.trimmingCharacters(in: .whitespaces),
            port: state.port
        ) else {
            error = model.lastError ?? "The server did not answer with a host key."
            return
        }
        hostKey = report
        state.hostKeyFingerprint = report.fingerprint
    }

    /// One probe answers both the privileges step and the detection step: they
    /// are two questions about the same round trip.
    public func probeServer() async {
        busy = true
        defer { busy = false }
        guard let report = await model.probeServer(draft) else {
            // Not "sudo is unavailable": nothing was learned about sudo. The
            // step stays blocked, retryable, and says what actually happened.
            error = model.lastError ?? "Could not reach the server."
            state.sudoAvailable = nil
            state.privilegeMode = nil
            return
        }
        probe = report
        state.sudoAvailable = report.hasPasswordlessSudo
        state.privilegeMode = state.user == "root"
            ? .root
            : (report.hasPasswordlessSudo ? .sudo : nil)
        state.detectedPlatform = Platform(
            distributionID: "",
            versionID: "",
            prettyName: report.prettyName,
            kernelRelease: "",
            architecture: Architecture(unameMachine: report.architecture) ?? .x86_64
        )
    }

    public func chooseRepositoryPath() {
        guard let path = chooseRepository() else { return }
        state.repositoryPath = path
    }

    public func exportKit() async {
        guard let serverID = addedServerID else { return }
        state.recoveryKitExported = await exportRecoveryKit(serverID)
    }

    /// The server is created here, at the end of the repository step, because
    /// everything after it — the first backup, the recovery kit — is about a
    /// server the agent already knows.
    public func continueFromCurrentStep() async {
        error = nil
        switch state.step {
        case .confirmHostKey:
            guard let hostKey else { return }
            busy = true
            let trusted = await model.trustHostKey(
                host: state.host.trimmingCharacters(in: .whitespaces),
                port: state.port,
                report: hostKey
            )
            busy = false
            guard trusted else {
                error = model.lastError ?? "Could not record the server's host key."
                return
            }

        case .chooseRepository:
            guard addedServerID == nil else { break }
            busy = true
            let id = await model.addServer(draft)
            busy = false
            guard let id else {
                error = model.lastError ?? "Could not add the server."
                return
            }
            addedServerID = id
            model.selectedServerID = id

        default:
            break
        }
        state.advance()
    }

    public func startFirstBackup() async {
        guard let serverID = addedServerID, firstBackupJobID == nil else { return }
        await model.backUpNow(serverID: serverID)
        firstBackupJobID = model.activity.last?.jobID
        noteActivity()
    }

    /// Called when the activity log changes, which is how the sheet learns that
    /// the first backup has finished without polling the agent.
    public func noteActivity() {
        guard let jobID = firstBackupJobID, let succeeded = model.finishedJobs[jobID] else { return }
        if succeeded {
            state.firstBackupCompleted = true
        } else {
            error = "The first backup failed. The log in the server's view says why."
        }
    }

    /// Whether closing the window now would leave a server whose backups
    /// cannot be read if this Mac is lost.
    public var closingLosesRecoveryKit: Bool {
        addedServerID != nil && !state.recoveryKitExported
    }
}
