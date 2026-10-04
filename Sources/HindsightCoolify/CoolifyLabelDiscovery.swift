import Foundation
import HindsightCore

/// Builds the resource tree from container labels.
///
/// This is the path that always works: Coolify's API is disabled on a fresh
/// install, so a token is a bonus rather than a prerequisite. Its limitation is
/// real and stated plainly — a stopped resource has no container, so it cannot
/// appear here.
public enum CoolifyLabelDiscovery {
    /// One container as `docker inspect` reports the parts we need.
    public struct ContainerInfo: Sendable, Hashable, Codable {
        public var name: String
        public var image: String
        public var labels: [String: String]
        public var mounts: [CoolifyVolume]
        public var state: String?

        public init(
            name: String,
            image: String,
            labels: [String: String],
            mounts: [CoolifyVolume] = [],
            state: String? = nil
        ) {
            self.name = name
            self.image = image
            self.labels = labels
            self.mounts = mounts
            self.state = state
        }
    }

    /// The command whose output `parse(inspectJSON:)` expects.
    ///
    /// `docker inspect` on all containers at once, rather than one call per
    /// container: a server with fifty containers would otherwise mean fifty
    /// round trips.
    public static let inspectCommand = """
    ids=$(docker ps -a --filter label=coolify.managed=true --format '{{.ID}}')
    [ -z "$ids" ] && echo '[]' && exit 0
    docker inspect $ids
    """

    public static func discover(inspectJSON: String) throws -> [CoolifyResource] {
        let containers = try parse(inspectJSON: inspectJSON)
        return containers.compactMap(resource(from:))
    }

    public static func parse(inspectJSON: String) throws -> [ContainerInfo] {
        guard let data = inspectJSON.data(using: .utf8) else { return [] }
        let decoded = try JSONDecoder().decode([DockerInspectEntry].self, from: data)
        return decoded.map { entry in
            ContainerInfo(
                // docker reports names with a leading slash.
                name: entry.name.hasPrefix("/") ? String(entry.name.dropFirst()) : entry.name,
                image: entry.config.image ?? "",
                labels: entry.config.labels ?? [:],
                mounts: (entry.mounts ?? []).map { mount in
                    CoolifyVolume(
                        name: mount.name ?? mount.source ?? "",
                        mountPath: mount.destination,
                        // A bind mount has no volume name; its source is a path.
                        hostPath: mount.type == "bind" ? mount.source : nil
                    )
                },
                state: entry.state?.status
            )
        }
    }

    public static func resource(from container: ContainerInfo) -> CoolifyResource? {
        guard container.labels["coolify.managed"] == "true" else { return nil }
        guard let kindLabel = container.labels["coolify.type"],
              let kind = CoolifyResourceKind(labelValue: kindLabel)
        else { return nil }

        // Identity is the compose project, then the container name. Verified
        // against v4.3.23: there is no uuid among the coolify.* labels, and the
        // numeric ids that are there are not stable across a restore.
        let uuid = container.labels["com.docker.compose.project"]
            ?? container.name
        guard !uuid.isEmpty else { return nil }

        let internalID = [
            "coolify.databaseId", "coolify.applicationId", "coolify.serviceId",
        ]
        .compactMap { container.labels[$0] }
        .compactMap(Int.init)
        .first

        return CoolifyResource(
            uuid: uuid,
            name: container.labels["coolify.resourceName"]
                ?? container.labels["coolify.serviceName"]
                ?? container.labels["coolify.name"]
                ?? uuid,
            kind: kind,
            projectName: container.labels["coolify.projectName"],
            environmentName: container.labels["coolify.environmentName"],
            subType: container.labels["coolify.database.subType"]
                ?? container.labels["coolify.service.subType"],
            containerName: container.name,
            image: container.image,
            status: container.state,
            volumes: container.mounts.filter { !$0.mountPath.isEmpty },
            internalID: internalID
        )
    }

    /// Recovers the resource kind from the working directory Coolify sets, for
    /// a container whose `coolify.type` is missing.
    public static func kindFromWorkingDirectory(_ path: String) -> CoolifyResourceKind? {
        for kind in CoolifyResourceKind.allCases where path.contains("/data/coolify/\(kind.directoryName)/") {
            return kind
        }
        return nil
    }
}

private struct DockerInspectEntry: Decodable {
    struct Config: Decodable {
        let image: String?
        let labels: [String: String]?

        enum CodingKeys: String, CodingKey {
            case image = "Image"
            case labels = "Labels"
        }
    }

    struct Mount: Decodable {
        let type: String?
        let name: String?
        let source: String?
        let destination: String

        enum CodingKeys: String, CodingKey {
            case type = "Type"
            case name = "Name"
            case source = "Source"
            case destination = "Destination"
        }
    }

    struct State: Decodable {
        let status: String?

        enum CodingKeys: String, CodingKey {
            case status = "Status"
        }
    }

    let name: String
    let config: Config
    let mounts: [Mount]?
    let state: State?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case config = "Config"
        case mounts = "Mounts"
        case state = "State"
    }
}
