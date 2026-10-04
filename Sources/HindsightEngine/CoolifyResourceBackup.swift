import Foundation
import HindsightCoolify
import HindsightCore
import HindsightRestic
import HindsightSSH

public struct CoolifyResourceOutcome: Sendable, Hashable {
    public var resourceUUID: String
    public var snapshotID: SnapshotID?
    public var dumps: [DatabaseDumpResult]
    public var capturedPaths: [String]
    public var bytesAdded: Int64
    public var failure: String?

    public var succeeded: Bool { failure == nil && snapshotID != nil }
}

/// Backs up one Coolify resource.
///
/// A resource is not a directory: it is some volumes, a generated compose file,
/// and — for a database — data that must be dumped rather than copied. The
/// snapshot is tagged with the resource's uuid so its history is queryable on
/// its own and survives the resource being renamed or moved between projects.
public struct CoolifyResourceBackup: Sendable {
    public let client: SSHClient

    public init(client: SSHClient) {
        self.client = client
    }

    /// The paths that make up a resource's state on disk.
    ///
    /// Named volumes are read from where Docker keeps them, which needs root —
    /// the alternative, `docker cp` out of a running container, would be slower
    /// and would miss anything the container has not flushed.
    public func capturePaths(for resource: CoolifyResource) -> [String] {
        var paths = [resource.configurationDirectory]
        paths += resource.volumes.map(\.dataPath)
        return paths
    }

    public func backUp(
        _ resource: CoolifyResource,
        remoteResticPath: String,
        repositorySecret: Secret,
        repositoryPassword: Secret,
        on destination: SSHDestination,
        facts: RemoteFacts,
        databaseCredentials: [String: Secret] = [:]
    ) async -> CoolifyResourceOutcome {
        var outcome = CoolifyResourceOutcome(
            resourceUUID: resource.uuid,
            snapshotID: nil,
            dumps: [],
            capturedPaths: [],
            bytesAdded: 0,
            failure: nil
        )

        // Only paths that exist: a resource with no persistent volume has a
        // config directory and nothing else, and restic treats a missing path
        // as an error.
        let candidates = capturePaths(for: resource)
        let present = await existing(candidates, on: destination)
        outcome.capturedPaths = present

        if present.isEmpty {
            outcome.failure = "none of this resource's paths exist on the server"
        } else {
            var arguments = ["backup", "--json", "--retry-lock", "5m"]
            for tag in resource.snapshotTags { arguments += ["--tag", tag.rawValue] }
            arguments += present

            do {
                let result = try await client.run(
                    RemoteCommand(
                        executable: remoteResticPath,
                        arguments: arguments,
                        secretEnvironment: [
                            "RESTIC_REPOSITORY": repositorySecret,
                            "RESTIC_PASSWORD": repositoryPassword,
                        ],
                        requiresRoot: true,
                        priorityPrefix: facts.lowPriorityPrefix
                    ),
                    on: destination,
                    allowedExitCodes: [0, 3],
                    timeout: .seconds(3600)
                )
                for line in result.standardOutputLines.reversed() {
                    if case let .summary(summary) = ResticMessage.decode(line: line) {
                        outcome.snapshotID = summary.snapshotID.map { SnapshotID(unchecked: $0) }
                        outcome.bytesAdded = summary.dataAdded
                        break
                    }
                }
                if outcome.snapshotID == nil {
                    outcome.failure = "restic did not report a snapshot"
                }
            } catch {
                outcome.failure = "\(error)"
            }
        }

        // A database resource's volume copy is crash-consistent at best, so the
        // dump is what makes it restorable.
        if resource.kind == .database, let engine = databaseEngine(for: resource) {
            let target = DatabaseTarget(
                engine: engine,
                location: .container(
                    name: resource.containerName ?? resource.uuid,
                    image: resource.image ?? ""
                ),
                coolifyResourceUUID: resource.uuid
            )
            let backup = DatabaseBackup(client: client)
            do {
                let dump = try await backup.backUp(
                    target,
                    database: nil,
                    remoteResticPath: remoteResticPath,
                    repositorySecret: repositorySecret,
                    repositoryPassword: repositoryPassword,
                    databasePassword: databaseCredentials[target.identifier],
                    on: destination,
                    hasBash: facts.hasBash,
                    priorityPrefix: facts.lowPriorityPrefix
                )
                outcome.dumps = [dump]
            } catch {
                outcome.dumps = [
                    DatabaseDumpResult(
                        target: target,
                        database: nil,
                        snapshotID: nil,
                        bytesAdded: 0,
                        bytesProcessed: 0,
                        consistencyNote: nil,
                        failure: "\(error)"
                    ),
                ]
            }
        }

        return outcome
    }

    /// Maps Coolify's sub-type onto a database engine.
    ///
    /// Coolify names them `standalone-postgresql`, `standalone-mysql` and so
    /// on, verified against a live install.
    public func databaseEngine(for resource: CoolifyResource) -> DatabaseEngine? {
        guard let name = resource.databaseEngineName?.lowercased() else { return nil }
        if name.contains("postgres") { return .postgres }
        if name.contains("mariadb") { return .mariadb }
        if name.contains("mysql") { return .mysql }
        if name.contains("mongo") { return .mongodb }
        if name.contains("redis") || name.contains("keydb") || name.contains("valkey") {
            return .redis
        }
        return nil
    }

    private func existing(_ paths: [String], on destination: SSHDestination) async -> [String] {
        let script = paths
            .map { "[ -e \(ShellQuoting.quote($0)) ] && printf '%s\\n' \(ShellQuoting.quote($0))" }
            .joined(separator: "\n")
        guard let result = try? await client.run(
            RemoteCommand(
                executable: "/bin/sh",
                arguments: ["-c", script + "\nexit 0"],
                requiresRoot: true
            ),
            on: destination
        ) else { return [] }
        let found = Set(result.standardOutputLines.filter { !$0.isEmpty })
        return paths.filter(found.contains)
    }
}
