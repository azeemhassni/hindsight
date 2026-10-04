import Foundation
import HindsightCatalog
import HindsightCore
import HindsightKeychain
import HindsightProtocol
import HindsightSSH

/// Adding a server.
///
/// Each step is a separate request because each can fail on its own, and
/// because the host key has to be shown to a person and confirmed before
/// anything else happens — a flow that did all of this at once could not pause
/// for that.
extension AgentCore {
    func scanHostKey(host: String, port: Int) async throws -> HostKeyReport {
        let client = SSHClient(paths: sshPaths(), policy: .fromEnvironment())
        let keys = try await client.scanHostKeys(host: host, port: port)
        guard let preferred = keys.first else {
            throw SSHError.noHostKeyOfSupportedType(host: host)
        }
        return HostKeyReport(
            keyType: preferred.keyType,
            base64Key: preferred.base64Key,
            fingerprint: preferred.fingerprint
        )
    }

    /// Records a host key as trusted.
    ///
    /// Called only after a person has compared the fingerprint, which is the
    /// whole point of the step: from here on any change is a hard failure.
    func trustHostKey(host: String, port: Int, keyType: String, base64Key: String) throws {
        let paths = sshPaths()
        let client = SSHClient(paths: paths, policy: .fromEnvironment())
        let destination = SSHDestination(
            serverID: ServerID(unchecked: "pending"),
            host: host,
            port: port,
            user: "root",
            identityFile: "",
            privilege: .root
        )
        try client.trust(
            HostKey(host: host, keyType: keyType, base64Key: base64Key, fingerprint: ""),
            for: destination
        )
    }

    func probeServer(_ draft: AddServerDraft) async throws -> ServerProbeReport {
        let paths = sshPaths()
        let client = SSHClient(paths: paths, policy: .fromEnvironment())
        let destination = try draftDestination(draft, paths: paths)

        // The config has to exist before ssh can use the alias.
        try SSHConfiguration(paths: paths).write(for: existingDestinations() + [destination])

        let facts = try await client.probeFacts(on: destination)
        return ServerProbeReport(
            prettyName: facts.platform.prettyName,
            architecture: facts.platform.architecture.rawValue,
            hasPasswordlessSudo: facts.hasPasswordlessSudo,
            dockerVersion: facts.dockerServerVersion,
            coolifyVersion: facts.looksLikeCoolify ? "detected" : nil,
            homeDirectory: facts.homeDirectory,
            isTestTarget: facts.hasTestMarker
        )
    }

    func addServer(_ draft: AddServerDraft) async throws -> ServerID {
        let id = try uniqueIdentifier(for: draft.name.isEmpty ? draft.host : draft.name)
        let paths = sshPaths()

        let server = try Server(
            id: id,
            name: draft.name.isEmpty ? draft.host : draft.name,
            endpoint: try SSHEndpoint(host: draft.host, port: draft.port, user: draft.user),
            authentication: draft.identityFile.map { .existingKey(path: $0) } ?? .managedKey,
            privilege: draft.user == "root" ? .root : .sudo
        )
        try catalog.save(server)

        let root = draft.repositoryPath.map { URL(fileURLWithPath: $0) }
            ?? configuration.repositoryRoot
        try catalog.save(
            RepositoryRecord(
                id: "repo-\(id.value)",
                serverId: id.value,
                path: root.appendingPathComponent(id.value).path
            )
        )

        // Generated here rather than at first backup: the recovery kit has to
        // be exportable before anything has run, and a password that appears
        // later is a password somebody can miss.
        _ = try await secretOrCreate(.repositoryPassword(id))

        try catalog.save(
            ScheduleRecord(
                id: "schedule-\(id.value)",
                serverId: id.value,
                schedule: try Schedule(cadence: .everyHours(6), onlyOnACPower: true)
            )
        )

        try SSHConfiguration(paths: paths).write(for: existingDestinations())
        await reloadSchedules()
        return id
    }

    /// An id no existing server already uses.
    ///
    /// Names are normalised to something safe as a path and a username, and
    /// that normalisation can collapse two different names onto one id —
    /// "Böx" and "B x" both become "b-x". Saving under an id that is already
    /// taken would overwrite somebody's server, so a suffix is added instead.
    func uniqueIdentifier(for name: String) throws -> ServerID {
        let base = Self.identifier(from: name)
        let taken = Set(((try? catalog.servers()) ?? []).map(\.id.value))
        guard taken.contains(base) else { return try ServerID(validating: base) }

        for suffix in 2...99 {
            let room = ServerID.maximumLength - String(suffix).count - 1
            let candidate = "\(String(base.prefix(room)))-\(suffix)"
            if !taken.contains(candidate) {
                return try ServerID(validating: candidate)
            }
        }
        return ServerID.generate()
    }

    func draftDestination(_ draft: AddServerDraft, paths: SSHPaths) throws -> SSHDestination {
        SSHDestination(
            serverID: try ServerID(
                validating: Self.identifier(from: draft.name.isEmpty ? draft.host : draft.name)
            ),
            host: draft.host,
            port: draft.port,
            user: draft.user,
            identityFile: draft.identityFile
                ?? paths.configurationDirectory.appendingPathComponent("pending.key").path,
            privilege: draft.user == "root" ? .root : .sudo
        )
    }

    /// Writes the managed ssh config for every server that exists.
    ///
    /// Called before anything that uses ssh, not only during onboarding: a
    /// server added after the last write had no stanza, and every job for it
    /// failed with "could not resolve hostname hs-…", which looks like a DNS
    /// problem and is not one.
    func refreshSSHConfiguration() {
        try? SSHConfiguration(paths: sshPaths()).write(for: existingDestinations())
    }

    func existingDestinations() -> [SSHDestination] {
        let paths = sshPaths()
        return ((try? catalog.servers()) ?? []).map { server in
            SSHDestination(server: server, identityFile: identityFile(for: server, paths: paths))
        }
    }

    /// Turns a name into something usable as a path component, a username and
    /// an ssh alias — the three places a server id ends up.
    static func identifier(from name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let lowered = name.lowercased().map { character -> Character in
            allowed.contains(character) ? character : "-"
        }
        let collapsed = String(lowered)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let trimmed = String(collapsed.prefix(ServerID.maximumLength))
        return trimmed.isEmpty ? "server-\(UUID().uuidString.prefix(8).lowercased())" : trimmed
    }
}
