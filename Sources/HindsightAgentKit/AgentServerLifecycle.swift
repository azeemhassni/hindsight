import Foundation
import HindsightCatalog
import HindsightCore
import HindsightKeychain
import HindsightProtocol
import HindsightRestic

/// Stopping work, and removing a server.
extension AgentCore {
    /// Stops whatever is running or queued for one server.
    func stopWork(serverID: String) async -> AgentResponse {
        guard let id = try? ServerID(validating: serverID) else {
            return .failed(message: "Not a server id: \(serverID).")
        }
        let stopped = await queue.cancelAll(forServer: id)
        // The rows are closed off here rather than waiting for the next start,
        // so the history never shows something running that is not.
        reconcileInterruptedJobs(forServer: id, reason: "Stopped.")
        return stopped > 0 ? .done : .failed(message: "Nothing was running for that server.")
    }

    /// Forgets a server.
    ///
    /// The repository is kept unless asked otherwise, and so is the password
    /// that reads it: a repository without its password is a pile of bytes
    /// nobody can open, and deleting the password while leaving the backups is
    /// the one combination that is never what anybody wants.
    func removeServer(serverID: String, deleteBackups: Bool) async -> AgentResponse {
        guard let id = try? ServerID(validating: serverID),
              let server = try? catalog.server(id)
        else { return .failed(message: "No server with id \(serverID).") }

        _ = await queue.cancelAll(forServer: id)
        reconcileInterruptedJobs(forServer: id, reason: "The server was removed.")

        let repository = try? catalog.repository(forServer: id)
        if deleteBackups, let repository {
            do {
                try FileManager.default.removeItem(atPath: repository.path)
            } catch {
                return .failed(
                    message: "Could not delete the backups at \(repository.path): \(error)"
                )
            }
            try? await deleteSecret(.repositoryPassword(id))
            try? await deleteSecret(.restServerCredential(id))
        }
        try? await deleteSecret(.coolifyToken(id))

        do {
            try catalog.deleteServer(id)
        } catch {
            return .failed(message: "Could not remove \(server.name): \(error)")
        }
        refreshSSHConfiguration()
        await reloadSchedules()
        return .done
    }
}
