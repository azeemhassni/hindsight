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
