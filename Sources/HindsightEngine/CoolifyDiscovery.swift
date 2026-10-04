import Foundation
import HindsightCoolify
import HindsightCore
import HindsightSSH

/// Finds the Coolify resources on a server.
///
/// Two paths, in order of how much they can see: the API, which knows about
/// resources that are stopped, and container labels, which only know about
/// containers that exist. The API is tried only when a token has been stored,
/// because Coolify ships with it disabled.
public struct CoolifyDiscovery: Sendable {
    public let client: SSHClient

    public init(client: SSHClient) {
        self.client = client
    }

    /// Coolify writes no version label, so the version comes off the image tag
    /// of its own container.
    public static let versionCommand =
        "docker inspect --format '{{.Config.Image}}' coolify 2>/dev/null || true"

    public static func version(fromImage image: String) -> String? {
        let trimmed = image.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.lastIndex(of: ":") else { return nil }
        let tag = String(trimmed[trimmed.index(after: colon)...])
        // A digest or a bare `latest` says nothing useful about the version.
        guard !tag.isEmpty, tag != "latest", !tag.contains("/") else { return nil }
        return tag
    }

    public func discover(
        on destination: SSHDestination,
        apiToken: Secret? = nil
    ) async throws -> CoolifyTree {
        let version = await detectVersion(on: destination)

        if let apiToken {
            let api = CoolifyAPIClient(client: client, destination: destination, token: apiToken)
            if let tree = try? await api.discover(), !tree.allResources.isEmpty {
                return CoolifyTree(
                    projects: tree.projects,
                    source: .api,
                    coolifyVersion: tree.coolifyVersion ?? version,
                    mayBeIncomplete: tree.mayBeIncomplete
                )
            }
        }

        let result = try await client.run(
            RemoteCommand(
                executable: "/bin/sh",
                arguments: ["-c", CoolifyLabelDiscovery.inspectCommand],
                requiresRoot: true
            ),
            on: destination,
            allowedExitCodes: [0, 1, 125, 127],
            timeout: .seconds(120)
        )
        // A server with no Docker answers with nothing at all, which is not an
        // error: it is a server with no Coolify on it, and saying so beats
        // failing a tab the person opened out of curiosity.
        let output = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            return CoolifyTree.assemble(
                [],
                source: .containerLabels,
                coolifyVersion: version,
                mayBeIncomplete: true
            )
        }

        let resources = try CoolifyLabelDiscovery.discover(inspectJSON: output)
        return CoolifyTree.assemble(
            resources,
            source: .containerLabels,
            coolifyVersion: version,
            // Labels cannot see a resource whose containers are gone, so an
            // empty answer is never proof of an empty instance.
            mayBeIncomplete: resources.isEmpty
        )
    }

    private func detectVersion(on destination: SSHDestination) async -> String? {
        guard let result = try? await client.run(
            RemoteCommand(
                executable: "/bin/sh",
                arguments: ["-c", Self.versionCommand],
                requiresRoot: true
            ),
            on: destination,
            allowedExitCodes: [0, 1, 125, 127],
            timeout: .seconds(30)
        ) else { return nil }
        return Self.version(fromImage: result.standardOutput)
    }
}
