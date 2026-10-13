import Foundation
import HindsightCatalog
import HindsightCore
import HindsightEngine
import HindsightProtocol
import HindsightRestic
import HindsightSSH

/// Building the seed that turns a fresh cloud image into a replica.
///
/// Read out of the metadata snapshot, which is where the package selections,
/// the enabled services and the operating system's identity are recorded. The
/// agent does it because reading a repository needs its password.
extension AgentCore {
    func buildReplicaSeed(
        serverID: String,
        snapshotID: String?,
        destinationDirectory: String
    ) async -> AgentResponse {
        do {
            let id = try ServerID(validating: serverID)
            guard let server = try catalog.server(id),
                  let repository = try catalog.repository(forServer: id)
            else { return .failed(message: "No server with id \(serverID).") }

            // The metadata snapshot, not the filesystem one: the package list
            // lives there, and it is a few kilobytes rather than gigabytes.
            let snapshots = try catalog.snapshots(inRepository: repository.id)
            guard let metadata = resolveMetadataSnapshot(snapshotID: snapshotID, in: snapshots)
            else { throw SeedISOError.noMetadataSnapshot }

            let client = try await repositoryClient(forServer: serverID)
            let base = MetadataCollector.remoteDirectory
            func read(_ name: String) async -> String {
                (try? await client.readTextFile(
                    snapshot: metadata.id,
                    path: "\(base)/\(name)"
                )) ?? ""
            }

            let source = ReplicaSeed.Source(
                hostname: server.endpoint.host,
                osRelease: await read("os-release"),
                packages: await read("packages.txt"),
                systemdUnits: await read("systemd-units.txt"),
                dockerPresent: server.platform != nil
                    ? !(await read("docker-ps.json")).isEmpty
                    : false,
                sshUser: server.endpoint.user,
                authorizedKey: publicKey(for: server)
            )
            let seed = ReplicaSeed.build(from: source)

            let folder = URL(fileURLWithPath: destinationDirectory)
            let destination = folder.appendingPathComponent("\(server.name) replica seed.iso")
            _ = try await SeedISO.write(
                userData: seed.userData,
                metaData: seed.metaData,
                to: destination
            )

            // The same thing unwrapped. An ISO is what a hypervisor wants —
            // Proxmox, libvirt, VMware — but a cloud provider usually takes
            // cloud-config pasted into a "user data" box when the machine is
            // created, and DigitalOcean cannot attach an ISO to a droplet at
            // all. Writing both costs a few kilobytes and saves having to
            // mount the image to get at what is inside it.
            try? Data(seed.userData.utf8).write(
                to: folder.appendingPathComponent("\(server.name) user-data.yml"),
                options: .atomic
            )
            try? Data(seed.notes.utf8).write(
                to: folder.appendingPathComponent("\(server.name) replica notes.md"),
                options: .atomic
            )
            return .replicaSeed(
                path: destination.path,
                notes: seed.notes,
                warnings: seed.warnings
            )
        } catch {
            return .failed(message: "\(error)")
        }
    }

    /// The newest metadata snapshot at or before the one asked for, so the
    /// image describes the machine as it was at that point rather than now.
    func resolveMetadataSnapshot(snapshotID: String?, in snapshots: [Snapshot]) -> Snapshot? {
        let metadata = snapshots.filter { $0.kind == .metadata }.sorted { $0.time > $1.time }
        guard let snapshotID, let chosen = snapshots.first(where: { $0.id.value == snapshotID })
        else { return metadata.first }
        return metadata.first { $0.time <= chosen.time } ?? metadata.first
    }

    /// Hindsight's own public key for this server, so the replica accepts the
    /// restore that follows without anybody editing a file on it by hand.
    func publicKey(for server: Server) -> String? {
        let paths = sshPaths()
        let privateKey = identityFile(for: server, paths: paths)
        let text = try? String(contentsOfFile: privateKey + ".pub", encoding: .utf8)
        return text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Finding the databases on a server, so a dump can be pointed at one.
extension AgentCore {
    func discoverDatabases(serverID: String) async -> AgentResponse {
        do {
            let id = try ServerID(validating: serverID)
            guard let server = try catalog.server(id) else {
                return .failed(message: "No server with id \(serverID).")
            }
            refreshSSHConfiguration()
            let paths = sshPaths()
            let client = SSHClient(paths: paths, policy: .fromEnvironment())
            let destination = SSHDestination(
                server: server,
                identityFile: identityFile(for: server, paths: paths)
            )
            let facts = try await client.probeFacts(on: destination)
            let targets = try await DatabaseDiscovery(client: client)
                .discover(on: destination, facts: facts)

            return .databases(targets.map { target in
                DatabaseTargetReport(
                    id: target.identifier,
                    engine: target.engine.rawValue,
                    displayName: target.displayName,
                    canLoadWhileRunning: DatabaseLoadCommand
                        .canLoadIntoRunningServer(target.engine)
                )
            })
        } catch {
            return .failed(message: "\(error)")
        }
    }
}
