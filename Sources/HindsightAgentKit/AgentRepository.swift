import Foundation
import HindsightCatalog
import HindsightCore
import HindsightKeychain
import HindsightProtocol
import HindsightRestic

/// Reading a repository on behalf of the app.
///
/// The app used to do this itself, which meant it needed the repository
/// password — and two processes reading one Keychain means either a shared
/// access group (a provisioning profile, an App ID, an entitlement) or a
/// system prompt every time. Neither is worth it for reads that the agent can
/// do in a few milliseconds: the agent holds the secrets, so the agent reads
/// the repository.
extension AgentCore {
    func listSnapshotDirectory(
        serverID: String,
        snapshotID: String,
        path: String
    ) async -> AgentResponse {
        do {
            let client = try await repositoryClient(forServer: serverID)
            let nodes = try await client.children(
                ofSnapshot: SnapshotID(unchecked: snapshotID),
                path: path
            )
            return .snapshotNodes(nodes.map { node in
                SnapshotNodeReport(
                    path: node.path,
                    name: node.name,
                    isDirectory: node.isDirectory,
                    sizeBytes: node.size,
                    modifiedAt: node.mtime,
                    permissions: node.permissions
                )
            })
        } catch {
            return .failed(message: "\(error)")
        }
    }

    /// Extracts one file for Quick Look.
    ///
    /// Into a directory of its own under the temporary directory, readable by
    /// the app: it is a copy of something the person can already restore, and
    /// it is deliberately not written anywhere near the repository.
    func extractFile(
        serverID: String,
        snapshotID: String,
        path: String
    ) async -> AgentResponse {
        do {
            let client = try await repositoryClient(forServer: serverID)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Hindsight-preview/\(UUID().uuidString)")
            let file = try await client.extractFile(
                snapshot: SnapshotID(unchecked: snapshotID),
                path: path,
                toDirectory: directory
            )
            // Readable by the person who asked, and nobody else on the machine.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: file.path
            )
            return .extractedFile(path: file.path)
        } catch {
            return .failed(message: "\(error)")
        }
    }

    func recoveryKit(serverID: String?) async -> AgentResponse {
        guard let servers = try? catalog.servers() else {
            return .failed(message: "The catalog could not be read.")
        }

        var entries: [RecoveryKit.Entry] = []
        var missing: [String] = []
        for server in servers where serverID == nil || server.id.value == serverID {
            let repository = try? catalog.repository(forServer: server.id)
            let password = await optionalSecret(.repositoryPassword(server.id))
            if password == nil { missing.append(server.name) }
            entries.append(
                RecoveryKit.Entry(
                    serverID: server.id.value,
                    serverName: server.name,
                    host: server.endpoint.host,
                    repositoryPath: repository?.path ?? "",
                    repositoryPassword: password?.value ?? "",
                    createdAt: repository?.createdAt ?? Date()
                )
            )
        }

        let kit = RecoveryKit(
            entries: entries,
            resticVersion: RecoveryKit.defaultResticVersion,
            hindsightVersion: version
        )
        do {
            return .kit(
                RecoveryKitReport(
                    markdown: kit.markdown(),
                    json: try kit.json(),
                    missingPasswordServers: missing,
                    serverCount: entries.count
                )
            )
        } catch {
            return .failed(message: "Could not assemble the recovery kit: \(error)")
        }
    }

    /// A restic client for a server's repository, with the password read off
    /// the actor.
    private func repositoryClient(forServer serverID: String) async throws -> ResticClient {
        let id = try ServerID(validating: serverID)
        guard let server = try catalog.server(id) else {
            throw AgentError.unknownServer(serverID)
        }
        guard let repository = try catalog.repository(forServer: id) else {
            throw AgentError.noRepository(serverID)
        }
        return try await localClient(for: server, repository: repository)
    }
}
