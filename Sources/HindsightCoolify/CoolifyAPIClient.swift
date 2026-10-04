import Foundation
import HindsightCore
import HindsightProcess
import HindsightSSH

public enum CoolifyAPIError: Error, Hashable, Sendable, CustomStringConvertible {
    case apiDisabled
    case unauthorized
    case unreachable(details: String)
    case unexpectedResponse(endpoint: String, body: String)

    public var description: String {
        switch self {
        case .apiDisabled:
            """
            Coolify's API is turned off on this instance. Hindsight will use \
            container labels instead, which shows running resources only. To \
            get the full picture, enable the API in Coolify's settings.
            """
        case .unauthorized:
            """
            Coolify rejected the token. Note that a token belongs to one team \
            and only sees that team's servers.
            """
        case let .unreachable(details):
            "Could not reach Coolify's API: \(details)"
        case let .unexpectedResponse(endpoint, body):
            "Could not read Coolify's reply from \(endpoint): \(body)"
        }
    }
}

/// Reads Coolify's API, from the server itself.
///
/// The requests are made on the server over the existing ssh connection rather
/// than from the Mac, so Coolify's API never has to be exposed to the network
/// for Hindsight to work.
public struct CoolifyAPIClient: Sendable {
    public let client: SSHClient
    public let destination: SSHDestination
    public let token: Secret
    public let baseURL: String

    public init(
        client: SSHClient,
        destination: SSHDestination,
        token: Secret,
        baseURL: String = "http://localhost:8000"
    ) {
        self.client = client
        self.destination = destination
        self.token = token
        self.baseURL = baseURL
    }

    func get(_ endpoint: String) async throws -> String {
        let url = "\(baseURL)/api/v1\(endpoint)"
        // The token goes in a header built inside the remote shell from an
        // environment variable, so it never appears in the process list.
        let script = """
        curl --silent --show-error --max-time 30 \
          --header "Authorization: Bearer $COOLIFY_TOKEN" \
          --header "Accept: application/json" \
          \(ShellQuoting.quote(url))
        """

        let result = try await client.run(
            RemoteCommand(
                executable: "/bin/sh",
                arguments: ["-c", script],
                secretEnvironment: ["COOLIFY_TOKEN": token],
                requiresRoot: true
            ),
            on: destination,
            allowedExitCodes: Set((0...255).map(Int32.init)),
            timeout: .seconds(60)
        )

        guard result.exit.terminationStatus == 0 else {
            throw CoolifyAPIError.unreachable(details: result.standardError)
        }

        let body = result.standardOutput
        // A disabled API answers 200 with success:true and a message, which a
        // careless client would read as an empty instance.
        if body.contains("\"message\":\"API is disabled.\"") {
            throw CoolifyAPIError.apiDisabled
        }
        if body.contains("\"message\":\"Invalid token.\"") || body.contains("\"message\":\"Unauthenticated.\"") {
            throw CoolifyAPIError.unauthorized
        }
        return body
    }

    func decode<T: Decodable>(_ type: T.Type, from body: String, endpoint: String) throws -> T {
        guard let data = body.data(using: .utf8) else {
            throw CoolifyAPIError.unexpectedResponse(endpoint: endpoint, body: body)
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CoolifyAPIError.unexpectedResponse(
                endpoint: endpoint,
                body: String(body.prefix(400))
            )
        }
    }

    /// `GET /version` returns a bare string, not an object.
    public func version() async throws -> String {
        let body = try await get("/version")
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    public func projects() async throws -> [CoolifyAPIProject] {
        try decode([CoolifyAPIProject].self, from: await get("/projects"), endpoint: "/projects")
    }

    public func project(uuid: String) async throws -> CoolifyAPIProject {
        try decode(
            CoolifyAPIProject.self,
            from: await get("/projects/\(uuid)"),
            endpoint: "/projects/\(uuid)"
        )
    }

    public func applications() async throws -> [CoolifyAPIResource] {
        try decode([CoolifyAPIResource].self, from: await get("/applications"), endpoint: "/applications")
    }

    public func services() async throws -> [CoolifyAPIResource] {
        try decode([CoolifyAPIResource].self, from: await get("/services"), endpoint: "/services")
    }

    public func databases() async throws -> [CoolifyAPIResource] {
        try decode([CoolifyAPIResource].self, from: await get("/databases"), endpoint: "/databases")
    }

    public func storages(
        kind: CoolifyResourceKind,
        uuid: String
    ) async throws -> [CoolifyVolume] {
        let endpoint = "/\(kind.directoryName)/\(uuid)/storages"
        let response = try decode(CoolifyAPIStorages.self, from: await get(endpoint), endpoint: endpoint)
        return response.persistentStorages.map { storage in
            CoolifyVolume(
                name: storage.name,
                mountPath: storage.mountPath,
                hostPath: storage.hostPath
            )
        }
    }

    /// Builds the whole tree, including volumes for every resource.
    public func discover() async throws -> CoolifyTree {
        let version = try? await version()
        let projects = try await projects()

        var environmentNames: [Int: (project: String, environment: String)] = [:]
        for project in projects {
            let detail = (try? await self.project(uuid: project.uuid)) ?? project
            for environment in detail.environments ?? [] {
                environmentNames[environment.id] = (project.name, environment.name)
            }
        }

        var resources: [CoolifyResource] = []
        for (kind, fetched) in [
            (CoolifyResourceKind.application, try await applications()),
            (CoolifyResourceKind.service, try await services()),
            (CoolifyResourceKind.database, try await databases()),
        ] {
            for item in fetched {
                let placement = item.environmentID.flatMap { environmentNames[$0] }
                var resource = CoolifyResource(
                    uuid: item.uuid,
                    name: item.name ?? item.uuid,
                    kind: kind,
                    projectName: placement?.project,
                    environmentName: placement?.environment,
                    subType: item.databaseType,
                    containerName: item.uuid,
                    image: item.image,
                    status: item.status
                )
                resource.volumes = (try? await storages(kind: kind, uuid: item.uuid)) ?? []
                resources.append(resource)
            }
        }

        // An empty answer here is not proof of an empty instance: a token sees
        // only its own team's servers.
        return CoolifyTree.assemble(
            resources,
            source: .api,
            coolifyVersion: version,
            mayBeIncomplete: resources.isEmpty
        )
    }
}

public struct CoolifyAPIProject: Decodable, Sendable, Hashable {
    public struct Environment: Decodable, Sendable, Hashable {
        public var id: Int
        public var uuid: String?
        public var name: String
    }

    public var uuid: String
    public var name: String
    public var environments: [Environment]?
}

public struct CoolifyAPIResource: Decodable, Sendable, Hashable {
    public var uuid: String
    public var name: String?
    public var status: String?
    public var image: String?
    public var environmentID: Int?
    /// Present on database resources, e.g. "standalone-postgresql".
    public var databaseType: String?

    enum CodingKeys: String, CodingKey {
        case uuid
        case name
        case status
        case image
        case environmentID = "environment_id"
        case databaseType = "database_type"
    }
}

struct CoolifyAPIStorages: Decodable, Sendable {
    struct Storage: Decodable, Sendable {
        let name: String
        let mountPath: String
        let hostPath: String?

        enum CodingKeys: String, CodingKey {
            case name
            case mountPath = "mount_path"
            case hostPath = "host_path"
        }
    }

    let persistentStorages: [Storage]

    enum CodingKeys: String, CodingKey {
        case persistentStorages = "persistent_storages"
    }
}
