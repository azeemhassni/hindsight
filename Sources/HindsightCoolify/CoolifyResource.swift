import Foundation
import HindsightCore

public enum CoolifyResourceKind: String, Sendable, Hashable, Codable, CaseIterable {
    case application
    case service
    case database

    /// The directory under `/data/coolify` that holds this kind's generated
    /// files, verified against a live v4.3.23 install.
    public var directoryName: String {
        switch self {
        case .application: "applications"
        case .service: "services"
        case .database: "databases"
        }
    }

    init?(labelValue: String) {
        switch labelValue {
        case "application": self = .application
        case "service": self = .service
        case "database": self = .database
        default: return nil
        }
    }
}

public struct CoolifyVolume: Sendable, Hashable, Codable {
    public var name: String
    public var mountPath: String
    /// Set only for a bind mount. A named volume reports nil, which is what
    /// makes restoring into a parallel volume possible.
    public var hostPath: String?

    public init(name: String, mountPath: String, hostPath: String? = nil) {
        self.name = name
        self.mountPath = mountPath
        self.hostPath = hostPath
    }

    public var isNamedVolume: Bool { hostPath == nil }

    /// Where a named volume's bytes live on the server.
    public var dataPath: String {
        hostPath ?? "/var/lib/docker/volumes/\(name)/_data"
    }
}

public struct CoolifyResource: Sendable, Hashable, Codable, Identifiable {
    public var uuid: String
    public var name: String
    public var kind: CoolifyResourceKind
    public var projectName: String?
    public var environmentName: String?
    public var subType: String?
    public var containerName: String?
    public var image: String?
    public var status: String?
    public var volumes: [CoolifyVolume]
    /// Numeric primary key in Coolify's own database. Useful for joining
    /// against it and nothing else: it is not stable across a Coolify restore.
    public var internalID: Int?

    public var id: String { uuid }

    public init(
        uuid: String,
        name: String,
        kind: CoolifyResourceKind,
        projectName: String? = nil,
        environmentName: String? = nil,
        subType: String? = nil,
        containerName: String? = nil,
        image: String? = nil,
        status: String? = nil,
        volumes: [CoolifyVolume] = [],
        internalID: Int? = nil
    ) {
        self.uuid = uuid
        self.name = name
        self.kind = kind
        self.projectName = projectName
        self.environmentName = environmentName
        self.subType = subType
        self.containerName = containerName
        self.image = image
        self.status = status
        self.volumes = volumes
        self.internalID = internalID
    }

    /// Coolify's generated files for this resource, which a restore needs.
    public var configurationDirectory: String {
        "/data/coolify/\(kind.directoryName)/\(uuid)"
    }

    public var snapshotTags: [SnapshotTag] {
        var tags: [SnapshotTag] = [.hindsight, .coolifyResource(uuid)]
        if let projectName { tags.append(.coolifyProject(projectName)) }
        if let environmentName { tags.append(.coolifyEnvironment(environmentName)) }
        return tags
    }

    /// The engine behind a database resource, from Coolify's own sub-type.
    public var databaseEngineName: String? {
        guard kind == .database, let subType else { return nil }
        // "standalone-postgresql", "standalone-mysql", and so on.
        return subType.replacingOccurrences(of: "standalone-", with: "")
    }

    public var isRunning: Bool {
        status?.hasPrefix("running") ?? false
    }
}

/// Project → Environment → Resource.
public struct CoolifyTree: Sendable, Hashable, Codable {
    public struct Environment: Sendable, Hashable, Codable {
        public var name: String
        public var uuid: String?
        public var resources: [CoolifyResource]

        public init(name: String, uuid: String? = nil, resources: [CoolifyResource]) {
            self.name = name
            self.uuid = uuid
            self.resources = resources
        }
    }

    public struct Project: Sendable, Hashable, Codable {
        public var name: String
        public var uuid: String?
        public var environments: [Environment]

        public init(name: String, uuid: String? = nil, environments: [Environment]) {
            self.name = name
            self.uuid = uuid
            self.environments = environments
        }
    }

    public enum Source: String, Sendable, Hashable, Codable {
        case api
        case containerLabels
        case database

        /// Shown in the UI, because a label-only tree is less complete and a
        /// person should know which they are looking at.
        public var explanation: String {
            switch self {
            case .api:
                "Read from Coolify's API."
            case .containerLabels:
                """
                Read from container labels, because no API token is configured \
                or the API is disabled. Resources that are not running will \
                not appear.
                """
            case .database:
                """
                Read directly from Coolify's database, because the API was \
                unavailable. This reads a private interface and may be \
                incomplete after a Coolify upgrade.
                """
            }
        }
    }

    public var projects: [Project]
    public var source: Source
    public var coolifyVersion: String?
    /// True when a source returned nothing but could not prove the instance is
    /// empty — an API token that belongs to a team with no servers, say.
    public var mayBeIncomplete: Bool

    public init(
        projects: [Project],
        source: Source,
        coolifyVersion: String? = nil,
        mayBeIncomplete: Bool = false
    ) {
        self.projects = projects
        self.source = source
        self.coolifyVersion = coolifyVersion
        self.mayBeIncomplete = mayBeIncomplete
    }

    public var allResources: [CoolifyResource] {
        projects.flatMap { $0.environments.flatMap(\.resources) }
    }

    public func resource(uuid: String) -> CoolifyResource? {
        allResources.first { $0.uuid == uuid }
    }

    /// Groups loose resources into the tree shape, used by every discovery path.
    public static func assemble(
        _ resources: [CoolifyResource],
        source: Source,
        coolifyVersion: String? = nil,
        mayBeIncomplete: Bool = false
    ) -> CoolifyTree {
        var byProject: [String: [String: [CoolifyResource]]] = [:]
        for resource in resources {
            let project = resource.projectName ?? "Ungrouped"
            let environment = resource.environmentName ?? "default"
            byProject[project, default: [:]][environment, default: []].append(resource)
        }

        let projects = byProject.keys.sorted().map { projectName in
            let environments = (byProject[projectName] ?? [:]).keys.sorted().map { environmentName in
                Environment(
                    name: environmentName,
                    resources: (byProject[projectName]?[environmentName] ?? [])
                        .sorted { $0.name < $1.name }
                )
            }
            return Project(name: projectName, environments: environments)
        }

        return CoolifyTree(
            projects: projects,
            source: source,
            coolifyVersion: coolifyVersion,
            mayBeIncomplete: mayBeIncomplete
        )
    }
}
