import Foundation
import HindsightCore
import HindsightSSH

/// Builds the shell pipeline that produces a logical dump.
///
/// Each one is a command whose standard output is the dump, so it can be piped
/// straight into `restic backup --stdin` without ever touching the server's
/// disk. Nothing here writes a temporary file: a multi-gigabyte dump on a full
/// disk would be a poor way to discover a backup was needed.
public enum DatabaseDumpCommand {
    public static func pipeline(for target: DatabaseTarget) throws -> String {
        let inner = try engineCommand(for: target)
        switch target.location {
        case let .container(name, _):
            return "docker exec -i \(ShellQuoting.quote(name)) sh -c \(ShellQuoting.quote(inner))"
        case .hostService, .networkService:
            return inner
        }
    }

    static func engineCommand(for target: DatabaseTarget) throws -> String {
        switch target.engine {
        case .postgres:
            // Custom format so a restore can be selective, and a single
            // database at a time so one failure does not lose the rest.
            let user = target.user ?? "$POSTGRES_USER"
            let database = target.databaseName ?? "$POSTGRES_DB"
            return """
            pg_dump --format=custom --no-owner --no-privileges \
            \(connectionFlags(for: target))--username="\(user)" --dbname="\(database)"
            """

        case .mysql, .mariadb:
            // --single-transaction gives a consistent view for InnoDB without
            // locking writers out. MyISAM tables are not covered by it, which
            // the UI says plainly rather than implying a guarantee.
            let user = target.user ?? "root"
            let database = target.databaseName
            let subject = database.map { "--databases \($0)" } ?? "--all-databases"
            return """
            \(target.engine == .mariadb ? "mariadb-dump" : "mysqldump") \
            --single-transaction --quick --routines --triggers --events \
            \(connectionFlags(for: target))--user="\(user)" \(subject)
            """

        case .mongodb:
            let database = target.databaseName.map { "--db=\($0) " } ?? ""
            return "mongodump --archive \(connectionFlags(for: target))\(database)--quiet"

        case .redis:
            // BGSAVE is asynchronous, so the dump waits for the save that it
            // started to finish before reading the file. Comparing the save
            // timestamp is the only reliable signal; polling the file is not.
            return """
            previous=$(redis-cli --no-raw LASTSAVE | tr -dc '0-9')
            redis-cli BGSAVE > /dev/null
            for attempt in $(seq 1 600); do
              current=$(redis-cli --no-raw LASTSAVE | tr -dc '0-9')
              [ "$current" != "$previous" ] && break
              sleep 1
            done
            [ "$current" = "$previous" ] && exit 75
            directory=$(redis-cli --no-raw CONFIG GET dir | tail -1 | tr -d '"')
            filename=$(redis-cli --no-raw CONFIG GET dbfilename | tail -1 | tr -d '"')
            cat "$directory/$filename"
            """
        }
    }

    /// Host and port flags for a database that is not local to the command.
    ///
    /// Passwords are never among them: they travel in the environment, where
    /// `ps` cannot read them.
    static func connectionFlags(for target: DatabaseTarget) -> String {
        guard case let .networkService(host, port) = target.location else { return "" }
        switch target.engine {
        case .postgres:
            return "--host=\(host) --port=\(port) "
        case .mysql, .mariadb:
            return "--host=\(host) --port=\(port) --protocol=TCP "
        case .mongodb:
            return "--host=\(host) --port=\(port) "
        case .redis:
            return "-h \(host) -p \(port) "
        }
    }

    /// The environment variable each client reads its password from.
    public static func passwordVariable(for engine: DatabaseEngine) -> String? {
        switch engine {
        case .postgres: "PGPASSWORD"
        case .mysql, .mariadb: "MYSQL_PWD"
        case .mongodb: nil
        case .redis: "REDISCLI_AUTH"
        }
    }

    /// Lists the databases on a server so each gets its own dump and its own
    /// history, rather than one opaque archive of everything.
    public static func listDatabasesCommand(for target: DatabaseTarget) -> String? {
        let inner: String
        switch target.engine {
        case .postgres:
            inner = """
            psql \(connectionFlags(for: target))--username="\(target.user ?? "${POSTGRES_USER:-postgres}")" \
            --dbname="\(target.databaseName ?? "${POSTGRES_DB:-postgres}")" \
            --tuples-only --no-align --command \
            "SELECT datname FROM pg_database WHERE datistemplate = false AND datallowconn"
            """
        case .mysql, .mariadb:
            inner = """
            mysql \(connectionFlags(for: target))--user="\(target.user ?? "root")" --batch --skip-column-names \
            --execute "SHOW DATABASES" | grep -vE '^(information_schema|performance_schema|mysql|sys)$'
            """
        case .mongodb, .redis:
            return nil
        }

        switch target.location {
        case let .container(name, _):
            return "docker exec -i \(ShellQuoting.quote(name)) sh -c \(ShellQuoting.quote(inner))"
        case .hostService, .networkService:
            return inner
        }
    }

    /// Postgres roles and permissions live outside any one database, so they
    /// are captured separately — a restore without them produces a database
    /// nobody can log into.
    public static func globalsCommand(for target: DatabaseTarget) -> String? {
        guard target.engine == .postgres else { return nil }
        let inner = "pg_dumpall --globals-only \(connectionFlags(for: target))"
            + "--username=\"\(target.user ?? "${POSTGRES_USER:-postgres}")\""
        switch target.location {
        case let .container(name, _):
            return "docker exec -i \(ShellQuoting.quote(name)) sh -c \(ShellQuoting.quote(inner))"
        case .hostService, .networkService:
            return inner
        }
    }

    public static func fileName(for target: DatabaseTarget, database: String?) -> String {
        let suffix: String
        switch target.engine {
        case .postgres: suffix = "dump"
        case .mysql, .mariadb: suffix = "sql"
        case .mongodb: suffix = "archive"
        case .redis: suffix = "rdb"
        }
        let name = database ?? "all"
        return "\(target.engine.rawValue)-\(name).\(suffix)"
    }

    public static func tags(for target: DatabaseTarget, database: String?) -> [SnapshotTag] {
        var tags: [SnapshotTag] = [.hindsight, .databaseEngine(target.engine.rawValue)]
        if let database { tags.append(.databaseName(database)) }
        if let uuid = target.coolifyResourceUUID { tags.append(.coolifyResource(uuid)) }
        return tags
    }
}
