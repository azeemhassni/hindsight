import Foundation
import HindsightCore
import HindsightRestic
import HindsightSSH

public struct DatabaseDumpResult: Sendable, Hashable {
    public var target: DatabaseTarget
    public var database: String?
    public var snapshotID: SnapshotID?
    public var bytesAdded: Int64
    public var bytesProcessed: Int64
    /// Set when the dump is a point-in-time copy rather than a transactional
    /// one, so the UI never implies a guarantee the engine cannot give.
    public var consistencyNote: String?
    public var failure: String?

    public var succeeded: Bool { failure == nil && snapshotID != nil }
}

/// Streams logical dumps into restic.
///
/// The dump never lands on the server's disk: the producing command's output
/// is piped straight into `restic backup --stdin` in the same remote shell.
public struct DatabaseBackup: Sendable {
    public let client: SSHClient

    public init(client: SSHClient) {
        self.client = client
    }

    public func backUp(
        _ target: DatabaseTarget,
        database: String?,
        remoteResticPath: String,
        repositorySecret: Secret,
        repositoryPassword: Secret,
        databasePassword: Secret? = nil,
        on destination: SSHDestination,
        hasBash: Bool,
        priorityPrefix: [String] = [],
        timeout: Duration = .seconds(3600)
    ) async throws -> DatabaseDumpResult {
        var resolved = target
        resolved.databaseName = database ?? target.databaseName

        let dump = try DatabaseDumpCommand.pipeline(for: resolved)
        let fileName = DatabaseDumpCommand.fileName(for: resolved, database: database)
        let tags = DatabaseDumpCommand.tags(for: resolved, database: database)

        var resticArguments = [
            "backup", "--json", "--stdin", "--stdin-filename", fileName,
            "--retry-lock", "5m",
        ]
        for tag in tags { resticArguments += ["--tag", tag.rawValue] }

        // Catching a failure in the *producing* half of the pipe matters more
        // than it looks: without it, a dump that dies half way still exits
        // zero because restic succeeded, and a truncated snapshot gets
        // recorded as a good backup.
        //
        // `pipefail` is the clean way and needs bash. `sh` on most Linux
        // systems is dash, where `set -o pipefail` not only fails but exits
        // the shell, because `set` is a special builtin. So the shell is
        // chosen from what the server actually has, and the fallback records
        // the producer's status explicitly.
        let shell = hasBash ? "/bin/bash" : "/bin/sh"
        let resticInvocation = ShellQuoting.quote(priorityPrefix + [remoteResticPath] + resticArguments)
        let script: String
        if hasBash {
            script = """
            set -o pipefail
            \(dump) | \(resticInvocation)
            """
        } else {
            script = """
            status_file=$(mktemp)
            { \(dump); echo $? > "$status_file"; } | \(resticInvocation)
            restic_status=$?
            dump_status=$(cat "$status_file")
            rm -f "$status_file"
            [ "$dump_status" = "0" ] || exit "$dump_status"
            exit "$restic_status"
            """
        }

        var secrets: [String: Secret] = [
            "RESTIC_REPOSITORY": repositorySecret,
            "RESTIC_PASSWORD": repositoryPassword,
        ]
        if let databasePassword,
           let variable = DatabaseDumpCommand.passwordVariable(for: resolved.engine) {
            secrets[variable] = databasePassword
        }

        let result = try await client.run(
            RemoteCommand(
                executable: shell,
                arguments: ["-c", script],
                secretEnvironment: secrets,
                requiresRoot: true
            ),
            on: destination,
            allowedExitCodes: Set((0...255).map(Int32.init)),
            timeout: timeout
        )

        var outcome = DatabaseDumpResult(
            target: resolved,
            database: database,
            snapshotID: nil,
            bytesAdded: 0,
            bytesProcessed: 0,
            consistencyNote: consistencyNote(for: resolved),
            failure: nil
        )

        for line in result.standardOutputLines.reversed() {
            if case let .summary(summary) = ResticMessage.decode(line: line) {
                outcome.snapshotID = summary.snapshotID.map { SnapshotID(unchecked: $0) }
                outcome.bytesAdded = summary.dataAdded
                outcome.bytesProcessed = summary.totalBytesProcessed
                break
            }
        }

        if result.exit.terminationStatus != 0 || outcome.snapshotID == nil {
            outcome.failure = result.standardError.isEmpty
                ? "the dump exited with status \(result.exit.terminationStatus)"
                : result.standardError
        }

        return outcome
    }

    /// Asks the server which databases exist, so each gets its own snapshot.
    public func listDatabases(
        for target: DatabaseTarget,
        databasePassword: Secret? = nil,
        on destination: SSHDestination
    ) async throws -> [String] {
        guard let command = DatabaseDumpCommand.listDatabasesCommand(for: target) else { return [] }
        var secrets: [String: Secret] = [:]
        if let databasePassword, let variable = DatabaseDumpCommand.passwordVariable(for: target.engine) {
            secrets[variable] = databasePassword
        }
        let result = try await client.run(
            RemoteCommand(
                executable: "/bin/sh",
                arguments: ["-c", command],
                secretEnvironment: secrets,
                requiresRoot: true
            ),
            on: destination,
            allowedExitCodes: Set((0...255).map(Int32.init))
        )

        guard result.exit.terminationStatus == 0 else { return [] }
        return result.standardOutputLines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains(" ") }
    }

    func consistencyNote(for target: DatabaseTarget) -> String? {
        switch target.engine {
        case .postgres, .mongodb:
            nil
        case .mysql, .mariadb:
            """
            Consistent for InnoDB tables. Any MyISAM tables are not covered by \
            the transaction and may be from slightly different moments.
            """
        case .redis:
            """
            A point-in-time copy of the save file, not a transaction. Writes \
            made during the save may or may not be included.
            """
        }
    }
}
