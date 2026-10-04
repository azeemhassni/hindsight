import Foundation
import HindsightCore

/// Pins both ends of the XPC connection to this team's signature.
///
/// Without this, any process on the machine could drive backups and restores,
/// or ask the agent for things it should not have. The requirement is applied
/// on the listener and on the client, because each is a way in.
public enum ConnectionSecurity {
    public static let appBundleIdentifier = "app.hindsight"
    public static let agentBundleIdentifier = "app.hindsight.agent"

    /// Built from the team identifier rather than hardcoded, so a build signed
    /// with a different identity fails closed instead of trusting strangers.
    ///
    /// The bundle identifier is named explicitly because the two ends do not
    /// share one: the agent is `app.hindsight.agent`, and a requirement naming
    /// only the app would refuse the very connection it is meant to protect.
    public static func codeSigningRequirement(
        teamIdentifier: String,
        bundleIdentifier: String
    ) -> String {
        """
        anchor apple generic \
        and certificate leaf[subject.OU] = "\(teamIdentifier)" \
        and identifier "\(bundleIdentifier)"
        """
    }

    /// What the app requires of the agent it is talking to.
    public static func agentRequirement(teamIdentifier: String) -> String {
        codeSigningRequirement(
            teamIdentifier: teamIdentifier,
            bundleIdentifier: agentBundleIdentifier
        )
    }

    /// What the agent requires of whoever is talking to it.
    public static func appRequirement(teamIdentifier: String) -> String {
        codeSigningRequirement(
            teamIdentifier: teamIdentifier,
            bundleIdentifier: appBundleIdentifier
        )
    }

    /// The team to pin to: this process's own, so each build pins itself to
    /// whatever identity signed it. The environment variable stays as an
    /// override for builds that are signed outside Xcode.
    ///
    /// An unsigned build has no team, and pins nothing — it cannot, and saying
    /// so is better than inventing a requirement that would refuse every
    /// connection.
    public static var teamIdentifier: String? {
        ProcessInfo.processInfo.environment["HINDSIGHT_TEAM_ID"] ?? CodeIdentity.teamIdentifier
    }

    @available(*, deprecated, renamed: "teamIdentifier")
    public static var teamIdentifierFromEnvironment: String? { teamIdentifier }
}
