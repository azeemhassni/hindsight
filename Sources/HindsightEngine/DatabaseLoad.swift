import Foundation
import HindsightCore
import HindsightRestic
import HindsightRestore
import HindsightSSH

/// Putting a logical dump back into a database.
///
/// The mirror of `DatabaseDumpCommand`, and the half that was missing: a dump
/// snapshot could be restored, but only as a file written onto the filesystem.
/// The dump landed intact and the database was untouched, which is a confusing
/// way to be told that nothing happened.
///
/// Every command here replaces data that is live. They are built to be
/// readable for that reason — somebody is going to want to run one by hand.
public enum DatabaseLoadCommand {
    /// Engines whose dump can be streamed into a running server.
    ///
    /// Redis is not one of them: an RDB is the file a Redis *starts from*, so
    /// loading it means stopping the server, replacing the file and starting
    /// again. Pretending otherwise would quietly do nothing.
    public static func canLoadIntoRunningServer(_ engine: DatabaseEngine) -> Bool {
        switch engine {
        case .postgres, .mysql, .mariadb, .mongodb: true
        case .redis: false
        }
    }

    public static func refusal(for engine: DatabaseEngine, container: String?) -> String? {
        guard !canLoadIntoRunningServer(engine) else { return nil }
        let name = container ?? "the container"
        return """
        A Redis dump is an RDB file, which is what Redis reads when it starts \
        rather than something that can be loaded into it while it is running. \
        Hindsight will not stop and start a database for you. To do it by \
        hand: stop \(name), put the restored .rdb at the path `CONFIG GET dir` \
        and `CONFIG GET dbfilename` report, and start it again.
        """
    }

    /// The command that reads a dump on standard input and loads it.
    ///
    /// `--clean --if-exists` for Postgres and `--drop` for MongoDB because a
    /// restore means "make it look like the snapshot", and loading on top of
    /// existing rows would leave a mixture of two moments.
    public static func loadCommand(
        for target: DatabaseTarget,
        database: String?
    ) throws -> String {
        switch target.engine {
        case .postgres:
            let user = target.user ?? "$POSTGRES_USER"
            let name = database ?? target.databaseName ?? "$POSTGRES_DB"
            return """
            pg_restore --clean --if-exists --no-owner --no-privileges \
            \(DatabaseDumpCommand.connectionFlags(for: target))--username="\(user)" \
            --dbname="\(name)"
            """

        case .mysql, .mariadb:
            let user = target.user ?? "root"
            let name = database ?? target.databaseName ?? ""
            let client = target.engine == .mariadb ? "mariadb" : "mysql"
            return """
            \(client) \(DatabaseDumpCommand.connectionFlags(for: target))--user="\(user)" \
            \(name.isEmpty ? "" : "\"\(name)\"")
            """

        case .mongodb:
            let name = database.map { "--nsInclude=\($0).* " } ?? ""
            return "mongorestore --archive --drop \(DatabaseDumpCommand.connectionFlags(for: target))\(name)"

        case .redis:
            throw DatabaseLoadError.cannotLoadIntoRunningServer(engine: .redis)
        }
    }

    /// The whole thing: read the dump out of the repository and pipe it in.
    ///
    /// `pipefail` for the same reason the backup needs it — without it a
    /// restore whose source could not be read still exits zero because the
    /// loader succeeded at loading nothing.
    public static func pipeline(
        for target: DatabaseTarget,
        database: String?,
        snapshotID: String,
        dumpPath: String,
        remoteResticPath: String,
        hasBash: Bool
    ) throws -> String {
        let inner = try loadCommand(for: target, database: database)
        let loader: String
        switch target.location {
        case let .container(name, _):
            let forwarded = DatabaseDumpCommand.passwordVariable(for: target.engine)
                .map { "-e \($0) " } ?? ""
            loader = "docker exec -i \(forwarded)\(ShellQuoting.quote(name)) "
                + "sh -c \(ShellQuoting.quote(inner))"
        case .hostService, .networkService:
            loader = inner
        }

        let read = "\(ShellQuoting.quote(remoteResticPath)) dump "
            + "\(ShellQuoting.quote(snapshotID)) \(ShellQuoting.quote(dumpPath))"
        guard hasBash else {
            return """
            status_file=$(mktemp)
            { \(read); echo $? > "$status_file"; } | \(loader)
            load_status=$?
            read_status=$(cat "$status_file")
            rm -f "$status_file"
            [ "$read_status" = "0" ] || exit "$read_status"
            exit "$load_status"
            """
        }
        return """
        set -o pipefail
        \(read) | \(loader)
        """
    }
}

/// Running a load against a server.
public enum DatabaseLoadRunner {
    /// Loads a dump back into a database.
    ///
    /// The dump is streamed out of the repository and piped straight into the
    /// database's own client on the server, which is the backup run backwards.
    /// Nothing is written to the filesystem on the way: a dump left lying on
    /// a production server is a copy of the database somebody has to remember
    /// to delete.
    public static func loadDatabaseDump(
        client: SSHClient,
        snapshotID: SnapshotID,
        dumpPath: String,
        into target: DatabaseTarget,
        database: String?,
        session: RestoreSession,
        hasBash: Bool,
        databasePassword: Secret?
    ) async throws {
        if let refusal = DatabaseLoadCommand.refusal(
            for: target.engine,
            container: target.containerName
        ) {
            throw DatabaseLoadError.refused(refusal)
        }

        let script = try DatabaseLoadCommand.pipeline(
            for: target,
            database: database,
            snapshotID: snapshotID.value,
            dumpPath: dumpPath,
            remoteResticPath: session.remoteResticPath,
            hasBash: hasBash
        )
        var secrets: [String: Secret] = [
            "RESTIC_REPOSITORY": session.repositorySecret,
            "RESTIC_PASSWORD": session.repositoryPassword,
        ]
        if let databasePassword,
           let variable = DatabaseDumpCommand.passwordVariable(for: target.engine) {
            secrets[variable] = databasePassword
        }

        let result = try await client.run(
            RemoteCommand(
                executable: hasBash ? "/bin/bash" : "/bin/sh",
                arguments: ["-c", script],
                secretEnvironment: secrets,
                requiresRoot: true
            ),
            on: session.destination,
            allowedExitCodes: Set((0...255).map(Int32.init)),
            timeout: .seconds(7200)
        )
        guard result.exit.terminationStatus == 0 else {
            throw DatabaseLoadError.failed(
                result.standardError.isEmpty
                    ? "exited with status \(result.exit.terminationStatus)"
                    : result.standardError
            )
        }
    }

}

public enum DatabaseLoadError: Error, CustomStringConvertible {
    case cannotLoadIntoRunningServer(engine: DatabaseEngine)
    case refused(String)
    case failed(String)
    case noDatabaseChosen
    case snapshotIsNotADump

    public var description: String {
        switch self {
        case let .cannotLoadIntoRunningServer(engine):
            "A \(engine.rawValue) dump cannot be loaded into a running server."
        case let .refused(reason):
            reason
        case let .failed(detail):
            "The dump could not be loaded: \(detail)"
        case .noDatabaseChosen:
            "Choose which database this dump should be loaded into."
        case .snapshotIsNotADump:
            "That snapshot holds files, not a database dump."
        }
    }
}
