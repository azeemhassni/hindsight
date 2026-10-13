import Foundation
import HindsightCore
import HindsightSSH

public enum DatabaseEngine: String, Sendable, Hashable, Codable, CaseIterable {
    case postgres
    case mysql
    case mariadb
    case mongodb
    case redis

    /// The ports these engines listen on by default, used only as a hint.
    public var defaultPort: Int {
        switch self {
        case .postgres: 5432
        case .mysql, .mariadb: 3306
        case .mongodb: 27017
        case .redis: 6379
        }
    }

    /// Matched against a container's image name.
    public var imageKeywords: [String] {
        switch self {
        case .postgres: ["postgres", "postgis", "timescale", "pgvector", "supabase/postgres"]
        case .mysql: ["mysql", "percona"]
        case .mariadb: ["mariadb"]
        case .mongodb: ["mongo"]
        case .redis: ["redis", "valkey", "keydb"]
        }
    }

    public var isTransactionalDump: Bool {
        switch self {
        case .postgres, .mysql, .mariadb, .mongodb: true
        // Redis has no transactional export; the RDB is a point-in-time copy.
        case .redis: false
        }
    }
}

/// A database Hindsight can dump, and how to reach it.
public struct DatabaseTarget: Sendable, Hashable, Codable {
    public enum Location: Sendable, Hashable, Codable {
        /// Reached with `docker exec`, which avoids needing a client on the host.
        case container(name: String, image: String)
        /// A service on the host itself.
        case hostService(port: Int)
        /// A database the server can reach over the network: a managed
        /// instance, or a service reached by its container name.
        case networkService(host: String, port: Int)
    }

    public var engine: DatabaseEngine
    public var location: Location
    public var databaseName: String?
    public var user: String?

    public init(
        engine: DatabaseEngine,
        location: Location,
        databaseName: String? = nil,
        user: String? = nil
    ) {
        self.engine = engine
        self.location = location
        self.databaseName = databaseName
        self.user = user
    }

    public var displayName: String {
        switch location {
        case let .container(name, _): "\(engine.rawValue) in \(name)"
        case let .hostService(port): "\(engine.rawValue) on port \(port)"
        case let .networkService(host, port): "\(engine.rawValue) at \(host):\(port)"
        }
    }

    public var containerName: String? {
        guard case let .container(name, _) = location else { return nil }
        return name
    }

    public var identifier: String {
        switch location {
        case let .container(name, _): "\(engine.rawValue)-\(name)"
        case let .hostService(port): "\(engine.rawValue)-host-\(port)"
        case let .networkService(host, port): "\(engine.rawValue)-\(host)-\(port)"
        }
    }
}

/// Finds databases worth dumping.
///
/// Copying a live database file is not a backup, so the filesystem pass alone
/// is not enough: anything found here gets a logical dump as well.
public struct DatabaseDiscovery: Sendable {
    public let client: SSHClient

    public init(client: SSHClient) {
        self.client = client
    }

    public func discover(
        on destination: SSHDestination,
        facts: RemoteFacts
    ) async throws -> [DatabaseTarget] {
        var targets: [DatabaseTarget] = []

        if facts.hasDocker {
            targets += try await containerTargets(on: destination)
        }
        targets += hostTargets(from: facts, excluding: targets)
        return targets
    }

    func containerTargets(on destination: SSHDestination) async throws -> [DatabaseTarget] {
        // Name and image in one line each, so the parse cannot be confused by
        // a container whose name contains a space.
        let result = try await client.run(
            RemoteCommand(
                executable: "/bin/sh",
                arguments: ["-c", "docker ps --format '{{.Names}}\t{{.Image}}'"],
                requiresRoot: true
            ),
            on: destination,
            allowedExitCodes: [0, 1, 125, 127]
        )
        return Self.parseContainers(result.standardOutputLines)
    }

    static func parseContainers(_ lines: [String]) -> [DatabaseTarget] {
        var targets: [DatabaseTarget] = []
        for line in lines where !line.isEmpty {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2 else { continue }
            let name = fields[0]
            let image = fields[1].lowercased()

            guard let engine = engineForImage(image) else { continue }
            targets.append(
                DatabaseTarget(engine: engine, location: .container(name: name, image: fields[1]))
            )
        }
        return targets
    }

    /// Longest keyword first, so `mariadb` is not mistaken for `mysql` and a
    /// `postgres-exporter` sidecar is not mistaken for a database.
    static func engineForImage(_ image: String) -> DatabaseEngine? {
        let lowered = image.lowercased()
        guard !lowered.contains("exporter"), !lowered.contains("backup") else { return nil }

        let candidates = DatabaseEngine.allCases
            .flatMap { engine in engine.imageKeywords.map { (keyword: $0, engine: engine) } }
            .sorted { $0.keyword.count > $1.keyword.count }

        for candidate in candidates where lowered.contains(candidate.keyword) {
            return candidate.engine
        }
        return nil
    }

    func hostTargets(from facts: RemoteFacts, excluding existing: [DatabaseTarget]) -> [DatabaseTarget] {
        let containerEngines = Set(existing.map(\.engine))
        var targets: [DatabaseTarget] = []
        for engine in DatabaseEngine.allCases {
            guard facts.listeningPorts.contains(engine.defaultPort) else { continue }
            // A container publishing its port looks identical from the host, so
            // prefer the container we already found over guessing at a service.
            guard !containerEngines.contains(engine) else { continue }
            targets.append(DatabaseTarget(engine: engine, location: .hostService(port: engine.defaultPort)))
        }
        return targets
    }
}

/// Finds the password a database wants, where the server already knows it.
///
/// Nothing populated `BackupPlan.databaseCredentials`, so every dump ran with
/// no password at all. Postgres did not care — `docker exec pg_dump` reaches
/// the socket as the container's superuser — but a Redis with `requirepass`
/// answered `NOAUTH` to everything, and the dump reported nothing for ten
/// minutes.
///
/// A container already holds its own credential, in the environment it was
/// started with or in the arguments it was given. Reading it there means a
/// person does not have to type a password Hindsight could have found, and it
/// is the same place the database itself reads it from.
public struct DatabaseCredentialDiscovery: Sendable {
    public let client: SSHClient

    public init(client: SSHClient) {
        self.client = client
    }

    /// Environment variables each engine's image conventionally carries,
    /// most specific first.
    static func variables(for engine: DatabaseEngine) -> [String] {
        switch engine {
        case .redis: ["REDIS_PASSWORD", "REDIS_AUTH", "REDISCLI_AUTH"]
        case .postgres: ["POSTGRES_PASSWORD", "PGPASSWORD"]
        case .mysql: ["MYSQL_ROOT_PASSWORD", "MYSQL_PASSWORD", "MYSQL_PWD"]
        case .mariadb: ["MARIADB_ROOT_PASSWORD", "MYSQL_ROOT_PASSWORD", "MARIADB_PASSWORD"]
        case .mongodb: ["MONGO_INITDB_ROOT_PASSWORD", "MONGODB_ROOT_PASSWORD"]
        }
    }

    public func credential(
        for target: DatabaseTarget,
        on destination: SSHDestination,
        timeout: Duration = .seconds(60)
    ) async throws -> Secret? {
        guard case let .container(name, _) = target.location else { return nil }

        // Environment and command in one call, separated by a marker: two
        // round trips per database adds up over eleven of them.
        let script = """
        docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' \(ShellQuoting.quote(name))
        echo '---hindsight-cmd---'
        docker inspect --format '{{range .Config.Cmd}}{{println .}}{{end}}' \(ShellQuoting.quote(name))
        """
        let result = try await client.run(
            RemoteCommand(
                executable: "/bin/sh",
                arguments: ["-c", script],
                requiresRoot: true
            ),
            on: destination,
            allowedExitCodes: [0, 1, 125, 127],
            timeout: timeout
        )
        guard result.exit.terminationStatus == 0 else { return nil }

        let label = "database password for \(target.identifier)"
        if let value = Self.password(
            inEnvironment: result.standardOutputLines,
            engine: target.engine
        ) {
            return Secret(label: label, value: value)
        }
        if let value = Self.password(inArguments: result.standardOutputLines) {
            return Secret(label: label, value: value)
        }
        return nil
    }

    static func password(inEnvironment lines: [String], engine: DatabaseEngine) -> String? {
        var found: [String: String] = [:]
        for line in lines {
            guard line != "---hindsight-cmd---" else { break }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let name = String(line[line.startIndex..<separator])
            let value = String(line[line.index(after: separator)...])
            guard !value.isEmpty else { continue }
            found[name] = value
        }
        for variable in variables(for: engine) {
            if let value = found[variable] { return value }
        }
        return nil
    }

    /// `redis-server --requirepass hunter2`, and the same shape for anything
    /// else that takes its password on the command line.
    static func password(inArguments lines: [String]) -> String? {
        guard let marker = lines.firstIndex(of: "---hindsight-cmd---") else { return nil }
        let arguments = lines[lines.index(after: marker)...].map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        for (index, argument) in arguments.enumerated() {
            let flag = argument.lowercased()
            guard flag == "--requirepass" || flag == "--password" else { continue }
            let next = index + 1
            guard next < arguments.count, !arguments[next].isEmpty,
                  !arguments[next].hasPrefix("--")
            else { continue }
            return arguments[next]
        }
        // `--requirepass=hunter2`
        for argument in arguments {
            for flag in ["--requirepass=", "--password="] where argument.hasPrefix(flag) {
                let value = String(argument.dropFirst(flag.count))
                if !value.isEmpty { return value }
            }
        }
        return nil
    }
}
