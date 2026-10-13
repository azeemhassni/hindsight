import Foundation
import HindsightCore
import HindsightProtocol
import Observation

/// Drives a restore from the interface.
///
/// The order is the safety property: a preview is fetched before the confirm
/// step is reachable, and the agent is asked to restore only after the hostname
/// has been typed and matched. Nothing here writes to a server — the agent
/// does, and it re-checks the confirmation itself.
@MainActor
@Observable
public final class RestoreFlow: Identifiable {
    public let id = UUID()

    public enum Stage: Sendable, Equatable {
        case choosing
        case preparing
        case reviewing
        case confirming
        /// Waiting for Touch ID, or the password.
        case authorizing
        case running
        case finished(succeeded: Bool, safetySnapshotID: String?)
        case failed(String)
    }

    public var stage: Stage = .choosing
    public var serverID: String
    public var serverHostname: String
    /// Where the snapshot is written, when that is not where it came from.
    /// Both the hostname that has to be typed and the permission asked for
    /// belong to this machine, because this is the one that changes.
    public var targetServerID: String?
    public var targetHostname: String?
    /// Set when the chosen snapshot holds a database dump rather than files.
    /// A dump is loaded into a database; it is not written onto the disk.
    public var isDatabaseDump = false
    /// The database inside the dump, from its `dbname:` tag.
    public var databaseName: String?
    /// Which database on the target to load it into.
    public var loadIntoDatabase: String?
    public var availableDatabases: [DatabaseTargetReport] = []
    public var snapshotID: String?
    public var paths: [String] = []
    public var targetPath: String?
    public var mode: String = "standard"
    public var optedInExclusions: Set<String> = []
    public var typedHostname: String = ""
    public var preview: RestorePreviewReport?

    private let model: AppModel
    private let presence: any UserPresenceCheck

    public init(
        model: AppModel,
        serverID: String,
        serverHostname: String,
        presence: any UserPresenceCheck = TouchIDPresence()
    ) {
        self.model = model
        self.serverID = serverID
        self.serverHostname = serverHostname
        self.presence = presence
    }

    public var command: RestoreCommand? {
        guard let snapshotID else { return nil }
        return RestoreCommand(
            serverID: serverID,
            targetServerID: targetServerID,
            snapshotID: snapshotID,
            paths: paths,
            targetPath: targetPath,
            mode: mode,
            typedHostname: typedHostname,
            optedInExclusions: Array(optedInExclusions).sorted(),
            loadIntoDatabase: isDatabaseDump ? loadIntoDatabase : nil,
            databaseName: isDatabaseDump ? databaseName : nil
        )
    }

    /// What the sheet is headed, which changes when the files are going
    /// somewhere other than where they came from.
    public var title: String {
        guard let targetHostname, targetHostname != serverHostname else {
            return "Restore \(serverHostname)"
        }
        return "Restore \(serverHostname) onto \(targetHostname)"
    }

    public var canReview: Bool { snapshotID != nil }

    /// Loads the databases a dump could go into, once the target is known.
    public func loadDatabaseChoices() async {
        guard isDatabaseDump else { return }
        availableDatabases = await model.databases(onServer: writtenServerID)
        // The obvious one, when there is only one it could be.
        let loadable = availableDatabases.filter(\.canLoadWhileRunning)
        if loadIntoDatabase == nil, loadable.count == 1 {
            loadIntoDatabase = loadable[0].id
        }
    }

    /// The confirm button stays disabled until the hostname matches exactly.
    public var canConfirm: Bool {
        // A dump needs somewhere to go, and takes no preview: what it would
        // replace is inside a database, which a filesystem diff cannot show.
        if isDatabaseDump {
            return loadIntoDatabase != nil && typedHostname
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(hostnameToConfirm) == .orderedSame
        }
        return preview != nil && typedHostname.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(hostnameToConfirm) == .orderedSame
    }

    public func prepare() async {
        guard var command else { return }
        // A dump replaces the contents of a database, which a filesystem diff
        // cannot describe. There is nothing honest to preview, so it goes
        // straight to the confirmation that names what it will replace.
        if isDatabaseDump {
            stage = .confirming
            return
        }
        // The preview is taken under the same confirmation the restore will
        // need, so a preview cannot be used to probe a server the person has
        // not identified.
        command.typedHostname = serverHostname
        stage = .preparing

        guard let report = await model.previewRestore(command) else {
            stage = .failed(model.lastError ?? "Could not work out what would change.")
            return
        }
        preview = report
        stage = .reviewing
    }

    public func proceedToConfirmation() {
        guard preview != nil || isDatabaseDump else { return }
        stage = .confirming
    }

    public func run() async {
        guard canConfirm, var command else { return }

        // Permission first, then the person, then the restore. The agent hands
        // out a token that lasts minutes and is spent once, so what follows is
        // tied to this confirmation and cannot be replayed later.
        stage = .authorizing
        guard let token = await model.authorizeRestore(serverID: writtenServerID) else {
            stage = .failed(model.lastError ?? "The agent would not authorise this restore.")
            return
        }

        let outcome = await presence.confirm(reason: confirmationReason)
        guard outcome.isConfirmed else {
            stage = .failed(outcome.explanation ?? "The restore was not confirmed.")
            return
        }

        command.authorization = token
        stage = .running
        guard await model.runRestore(command) != nil else {
            stage = .failed(model.lastError ?? "The restore was refused.")
            return
        }
    }

    /// What the system prompt says, so the person is agreeing to something
    /// specific rather than to the word "authenticate".
    var confirmationReason: String {
        let what = paths.isEmpty
            ? "everything in this snapshot"
            : (paths.count == 1 ? paths[0] : "\(paths.count) paths")
        guard let targetHostname, targetHostname != serverHostname else {
            return "restore \(what) to \(serverHostname)"
        }
        // Naming both ends, because restoring one machine's files onto another
        // is not what somebody confirming a restore would assume.
        return "restore \(what) from \(serverHostname) onto \(targetHostname)"
    }

    /// The machine being written to, which is what has to be confirmed.
    public var writtenServerID: String { targetServerID ?? serverID }

    /// The hostname the person must type. The target's, when restoring
    /// somewhere else.
    public var hostnameToConfirm: String { targetHostname ?? serverHostname }

    /// Called when the agent reports the outcome, so the sheet reflects what
    /// actually happened rather than what was requested.
    public func apply(_ event: AgentEvent) {
        guard case let .restoreFinished(server, succeeded, safetySnapshotID, message) = event,
              server == serverID || server == targetServerID
        else { return }
        stage = succeeded
            ? .finished(succeeded: true, safetySnapshotID: safetySnapshotID)
            : .failed(message ?? "The restore failed.")
    }

    /// What to tell the person at this point, in plain words.
    public var statusText: String {
        switch stage {
        case .choosing:
            return "Choose a snapshot and what to restore."
        case .preparing:
            return """
            Taking a snapshot of what is there now, so this can be undone, then \
            comparing it with the one being restored.
            """
        case .reviewing:
            guard let preview else { return "" }
            return "\(preview.addedCount) to add, \(preview.modifiedCount) to change, "
                + "\(preview.removedCount) already there that the snapshot does not contain."
        case .confirming:
            return "Type the server's hostname to confirm."
        case .authorizing:
            return "Waiting for Touch ID. A restore writes to the server, so it asks first."
        case .running:
            return "Restoring."
        case let .finished(_, safetySnapshotID):
            return "Finished. Undo it by restoring snapshot "
                + "\(safetySnapshotID.map { String($0.prefix(8)) } ?? "—")."
        case let .failed(message):
            return message
        }
    }
}

/// A machine a snapshot could be restored onto.
public struct RestoreDestination: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var hostname: String

    public init(id: String, name: String, hostname: String) {
        self.id = id
        self.name = name
        self.hostname = hostname
    }
}
