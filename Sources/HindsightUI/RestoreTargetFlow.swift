import Foundation
import HindsightProtocol
import Observation

/// Adding a machine to restore onto, from its connection details.
///
/// The same host key confirmation onboarding does, for the same reason: a
/// restore writes to a server, and writing to a machine whose identity nobody
/// has checked is how you end up restoring onto a stranger. What it skips is
/// everything to do with keeping backups — no repository, no password, no
/// schedule — because this machine is a destination, not a source.
@MainActor
@Observable
public final class RestoreTargetFlow: Identifiable {
    public let id = UUID()

    public enum Stage: Sendable, Equatable {
        case details
        /// The key has been fetched and is waiting to be compared.
        case confirmingHostKey(HostKeyReport)
        case probing
        case adding
        case added(serverID: String, hostname: String, name: String)
        case failed(String)
    }

    public var name = ""
    public var host = ""
    public var port = "22"
    public var user = "root"
    public var identityFile: String?
    public private(set) var stage: Stage = .details
    public private(set) var probe: ServerProbeReport?

    private let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var portNumber: Int? {
        guard let value = Int(port.trimmingCharacters(in: .whitespaces)), (1...65535).contains(value)
        else { return nil }
        return value
    }

    public var canScan: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !user.trimmingCharacters(in: .whitespaces).isEmpty
            && portNumber != nil
    }

    private var draft: AddServerDraft {
        AddServerDraft(
            name: name.trimmingCharacters(in: .whitespaces),
            host: host.trimmingCharacters(in: .whitespaces),
            port: portNumber ?? 22,
            user: user.trimmingCharacters(in: .whitespaces),
            identityFile: identityFile,
            repositoryPath: nil
        )
    }

    /// Fetches the host key so it can be compared before anything connects.
    public func scan() async {
        guard canScan else { return }
        stage = .probing
        guard let report = await model.scanHostKey(host: draft.host, port: draft.port) else {
            stage = .failed(model.lastError ?? "Could not reach that machine to read its host key.")
            return
        }
        stage = .confirmingHostKey(report)
    }

    /// Accepts the key, checks the connection works, and records the machine.
    public func confirmHostKey() async {
        guard case let .confirmingHostKey(report) = stage else { return }
        stage = .probing
        guard await model.trustHostKey(host: draft.host, port: draft.port, report: report) else {
            stage = .failed(model.lastError ?? "That host key could not be trusted.")
            return
        }

        // Proving the connection works before recording it, so a target that
        // cannot be reached is found now rather than half way through a
        // restore.
        guard let found = await model.probeServer(draft) else {
            stage = .failed(model.lastError ?? "Could not connect with those details.")
            return
        }
        probe = found

        stage = .adding
        guard let serverID = await model.addRestoreTarget(draft) else {
            stage = .failed(model.lastError ?? "That machine could not be added.")
            return
        }
        stage = .added(
            serverID: serverID,
            hostname: draft.host,
            name: draft.name.isEmpty ? draft.host : draft.name
        )
    }

    public func startOver() {
        stage = .details
        probe = nil
    }

    public var statusText: String {
        switch stage {
        case .details: "Where should this snapshot be written?"
        case .confirmingHostKey: "Compare this fingerprint with the machine itself."
        case .probing: "Checking the connection…"
        case .adding: "Recording the machine…"
        case let .added(_, hostname, _): "Ready to restore onto \(hostname)."
        case let .failed(reason): reason
        }
    }
}
