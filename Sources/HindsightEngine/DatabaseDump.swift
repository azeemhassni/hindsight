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
            // `docker exec` starts with the container's environment, not the
            // caller's, so a password set for the ssh command does not reach
            // the client inside. `-e NAME` with no value forwards the
            // caller's — unlike `-e NAME=value`, which would put the password
            // in `argv` where `ps` can read it.
            let forwarded = passwordVariable(for: target.engine).map { "-e \($0) " } ?? ""
            return "docker exec -i \(forwarded)\(ShellQuoting.quote(name)) "
                + "sh -c \(ShellQuoting.quote(inner))"
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
            //
            // Every guard here is one that was missing. `redis-cli` prints
            // `(error) NOAUTH Authentication required.` to stdout and exits
            // zero, which `tr -dc '0-9'` reduced to an empty string — and an
            // empty string never differs from the previous empty string, so
            // the loop slept through all 600 of its attempts and then reported
            // nothing. And `--no-raw` keeps the `2) ` list prefix that
            // `CONFIG GET` numbers its values with, so the path came out as
            // `2) /data/2) dump.rdb`: the read would have failed even with a
            // password. Raw output, which is the default when stdout is a
            // pipe, gives the bare value.
            return """
            \(redisAuthPreamble)
            previous=$("$redis_cli" LASTSAVE | tr -dc '0-9')
            if [ -z "$previous" ]; then
              echo "$redis_cli could not read LASTSAVE:" 1>&2
              "$redis_cli" PING 1>&2
              exit 74
            fi
            "$redis_cli" BGSAVE > /dev/null
            current=""
            for attempt in $(seq 1 \(Self.redisSaveTimeoutSeconds)); do
              current=$("$redis_cli" LASTSAVE | tr -dc '0-9')
              [ -n "$current" ] && [ "$current" != "$previous" ] && break
              sleep 1
            done
            if [ -z "$current" ] || [ "$current" = "$previous" ]; then
              echo "BGSAVE did not finish within \(Self.redisSaveTimeoutSeconds)s" 1>&2
              exit 75
            fi
            directory=$("$redis_cli" CONFIG GET dir | tail -1)
            filename=$("$redis_cli" CONFIG GET dbfilename | tail -1)
            if [ -z "$directory" ] || [ -z "$filename" ]; then
              echo "could not read the RDB location from CONFIG GET" 1>&2
              exit 76
            fi
            if [ ! -s "$directory/$filename" ]; then
              echo "the RDB at $directory/$filename is missing or empty" 1>&2
              exit 77
            fi
            cat "$directory/$filename"
            """
        }
    }

    /// Where `redis-cli` gets its password when nobody passed one in.
    ///
    /// A Redis container holds the password it was started with, which is the
    /// same value `redis-cli` needs and the same place Redis itself read it
    /// from — so the common case needs no credential handling at all. Only
    /// exported when it is not empty: `REDISCLI_AUTH=""` makes `redis-cli`
    /// attempt an authentication and fail with `WRONGPASS`, where leaving it
    /// unset at least fails with something honest.
    static let redisAuthPreamble = """
    if [ -z "${REDISCLI_AUTH:-}" ] && [ -n "${REDIS_PASSWORD:-}" ]; then
      REDISCLI_AUTH="$REDIS_PASSWORD"
    fi
    if [ -n "${REDISCLI_AUTH:-}" ]; then export REDISCLI_AUTH; else unset REDISCLI_AUTH; fi
    \(redisClientPreamble)
    """

    /// Valkey and KeyDB are Redis forks that Hindsight already recognises by
    /// image name, and neither ships a binary called `redis-cli` — one
    /// container on a real server failed with `sh: redis-cli: not found`. The
    /// client is whichever of the three is actually there.
    static let redisClientPreamble = """
    for candidate in redis-cli valkey-cli keydb-cli; do
      if command -v "$candidate" > /dev/null 2>&1; then
        redis_cli="$candidate"
        break
      fi
    done
    if [ -z "${redis_cli:-}" ]; then
      echo "none of redis-cli, valkey-cli or keydb-cli is in this container" 1>&2
      exit 78
    fi
    """

    /// How long to wait for a `BGSAVE` to finish. Ten minutes was the old
    /// value, and with a Redis that could not be reached it was ten minutes
    /// of sleeping per instance before reporting nothing at all.
    static let redisSaveTimeoutSeconds = 120

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
        return tags
    }
}
