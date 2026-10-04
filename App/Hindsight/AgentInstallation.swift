import Foundation
import HindsightCore
import HindsightProtocol
import ServiceManagement

/// Registering the background agent with launchd.
///
/// The agent is what keeps backups running when the window is closed, so the
/// app registers it on launch rather than asking anyone to do it. macOS shows
/// it to the person in Login Items, where they can turn it off — and if they
/// do, that is an answer, not an error to work around.
@MainActor
enum AgentInstallation {
    static let plistName = "app.hindsight.agent.plist"

    static var service: SMAppService {
        SMAppService.agent(plistName: plistName)
    }

    enum Outcome: Sendable, Equatable {
        case registered
        /// Already registered, and launchd has it.
        case alreadyEnabled
        /// The person has to allow it in Login Items.
        case needsApproval
        /// Registration is impossible for this build — an unsigned one, most
        /// likely, which launchd will not accept.
        case failed(String)

        var isUsable: Bool {
            switch self {
            case .registered, .alreadyEnabled: true
            case .needsApproval, .failed: false
            }
        }

        var explanation: String? {
            switch self {
            case .registered, .alreadyEnabled:
                nil
            case .needsApproval:
                """
                Hindsight's background agent is waiting to be allowed in \
                Login Items. Backups do not run until it is.
                """
            case let .failed(reason):
                "The background agent could not be registered: \(reason)"
            }
        }
    }

    @discardableResult
    static func registerIfNeeded() -> Outcome {
        let service = service
        switch service.status {
        case .enabled:
            return .alreadyEnabled
        case .requiresApproval:
            return .needsApproval
        default:
            break
        }

        do {
            try service.register()
            // Registration is asynchronous in launchd's eyes; the status right
            // after can still be "requires approval" on a first install.
            return service.status == .requiresApproval ? .needsApproval : .registered
        } catch {
            return .failed("\(error)")
        }
    }

    /// Submits the job description again.
    ///
    /// `status` can say `enabled` while launchd has no such job — after the app
    /// bundle moved, or after someone removed it with `launchctl bootout`.
    /// Re-registering is how launchd is told again, and it is what turns "the
    /// agent is not responding" back into a working install without anyone
    /// having to know any of this.
    @discardableResult
    static func reregister() async -> Outcome {
        try? await service.unregister()
        do {
            try service.register()
            return service.status == .requiresApproval ? .needsApproval : .registered
        } catch {
            return .failed("\(error)")
        }
    }

    /// Takes the agent out of launchd. Used when uninstalling, and by hand
    /// during development.
    static func unregister() async throws {
        try await service.unregister()
    }

    /// The agent that ships inside this app bundle.
    static var bundledAgentURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents/HindsightAgent.app")
    }

    /// Whether the agent launchd is running is the one in this bundle.
    ///
    /// After an update they differ: launchd keeps running the old executable
    /// from the replaced bundle, so the new app talks to the previous build
    /// until something restarts it.
    static func isRunningAgentCurrent(reportedIdentity: String?) -> Bool {
        guard let reportedIdentity,
              let bundled = CodeIdentity.binaryIdentity(ofBundleAt: bundledAgentURL)
        else {
            // Unsigned or unreadable: nothing can be compared, so nothing is
            // claimed and nothing is restarted.
            return true
        }
        return reportedIdentity == bundled
    }

    /// Opens the Login Items pane, which is where the person can allow it.
    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
