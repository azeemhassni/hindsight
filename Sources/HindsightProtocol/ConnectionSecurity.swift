import Foundation

/// Pins both ends of the XPC connection to this team's signature.
///
/// Without this, any process on the machine could drive backups and restores,
/// or ask the agent for things it should not have. The requirement is applied
/// on the listener and on the client, because each is a way in.
public enum ConnectionSecurity {
    /// Built from the team identifier rather than hardcoded, so a build signed
    /// with a different identity fails closed instead of trusting strangers.
    public static func codeSigningRequirement(teamIdentifier: String) -> String {
        """
        anchor apple generic \
        and certificate leaf[subject.OU] = "\(teamIdentifier)" \
        and identifier "app.hindsight"
        """
    }

    public static var teamIdentifierFromEnvironment: String? {
        ProcessInfo.processInfo.environment["HINDSIGHT_TEAM_ID"]
    }
}
