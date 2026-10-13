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
            let snapshot = SnapshotID(unchecked: snapshotID)
            let fetch: SnapshotListingCache.Fetch = { paths in
                try await client
                    .children(ofSnapshot: snapshot, paths: paths)
                    .mapValues { $0.map(SnapshotNodeReport.init(node:)) }
            }

            let nodes = try await listings.listing(
                serverID: serverID,
                snapshotID: snapshotID,
                path: path,
                fetch: fetch
            )
            // Reading the subdirectories now, while nobody is waiting, is what
            // makes opening one of them instant: one more index load off
            // screen instead of one per folder opened.
            await listings.prefetchChildren(
                serverID: serverID,
                snapshotID: snapshotID,
                of: nodes,
                fetch: fetch
            )
            return .snapshotNodes(nodes)
        } catch {
            return .failed(message: "\(error)")
        }
    }

    /// Finds entries in a snapshot by name.
    ///
    /// One recursive listing of the whole snapshot, which is the only way:
    /// restic has no search, and a tree walk a directory at a time would pay
    /// the index load for every directory on the server. Expensive and
    /// deliberate — the person asked — so it is capped, and the reply says
    /// when the cap was reached rather than presenting the first few hundred
    /// matches as all of them.
    func searchSnapshot(
        serverID: String,
        snapshotID: String,
        term: String,
        limit: Int
    ) async -> AgentResponse {
        let needle = term.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return .snapshotMatches(nodes: [], truncated: false) }

        do {
            let client = try await repositoryClient(forServer: serverID)
            var matches: [SnapshotNodeReport] = []
            var truncated = false
            let cap = max(1, limit)
            // Streamed and stopped at the cap: a recursive listing of a real
            // server is far too large to hold, and stopping early is what
            // keeps a common word from reading the whole snapshot.
            try await client.walk(
                snapshot: SnapshotID(unchecked: snapshotID),
                recursive: true,
                // The needle has to appear somewhere in the line for it to
                // appear in the name, so this throws out almost everything
                // before the expensive part. The real test is below.
                considering: { $0.localizedCaseInsensitiveContains(needle) }
            ) { node in
                guard node.name.lowercased().contains(needle) else { return true }
                matches.append(SnapshotNodeReport(node: node))
                if matches.count >= cap {
                    truncated = true
                    return false
                }
                return true
            }
            return .snapshotMatches(nodes: matches, truncated: truncated)
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
    func repositoryClient(forServer serverID: String) async throws -> ResticClient {
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
