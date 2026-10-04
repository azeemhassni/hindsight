import Foundation
import HindsightCore
import HindsightCoolify

public enum RestoreScope: Sendable, Hashable, Codable {
    case fullServer
    case paths([String])
    case coolifyResource(uuid: String, kind: CoolifyResourceKind)
    /// A logical dump, restored into a database rather than onto the filesystem.
    case databaseDump(database: String?)

    public var describedForConfirmation: String {
        switch self {
        case .fullServer: "the whole server"
        case let .paths(paths) where paths.count == 1: paths[0]
        case let .paths(paths): "\(paths.count) paths"
        case let .coolifyResource(uuid, kind): "the \(kind.rawValue) \(uuid)"
        case let .databaseDump(database): "the database \(database ?? "dump")"
        }
    }
}

public enum RestoreTarget: Sendable, Hashable, Codable {
    case inPlace
    case alternatePath(String)
    case anotherServer(serverID: String)

    public var isInPlace: Bool {
        if case .inPlace = self { return true }
        return false
    }
}

public enum RestoreMode: String, Sendable, Hashable, Codable, CaseIterable {
    case zeroDowntime
    case minimalDowntime
    case standard

    public var title: String {
        switch self {
        case .zeroDowntime: "Zero downtime"
        case .minimalDowntime: "Minimal downtime"
        case .standard: "Standard"
        }
    }

    public var summary: String {
        switch self {
        case .zeroDowntime:
            """
            Restores alongside the live copy, starts a second container on it, \
            health-checks it, then switches traffic over.
            """
        case .minimalDowntime:
            """
            Stages the restored data next to the live data, then stops, swaps, \
            and starts again.
            """
        case .standard:
            "Stops the service, restores over the live data, and starts it again."
        }
    }
}

public struct RestoreModeAvailability: Sendable, Hashable {
    public var mode: RestoreMode
    public var isAvailable: Bool
    /// Always populated. When a mode is unavailable the UI must say why, and
    /// when it is available it must say what it costs.
    public var explanation: String
    /// Non-nil only for zero-downtime, which cannot preserve writes made
    /// between the snapshot and the switch.
    public var dataLossWarning: String?

    public init(
        mode: RestoreMode,
        isAvailable: Bool,
        explanation: String,
        dataLossWarning: String? = nil
    ) {
        self.mode = mode
        self.isAvailable = isAvailable
        self.explanation = explanation
        self.dataLossWarning = dataLossWarning
    }
}

/// What the planner needs to know about the thing being restored.
public struct RestoreFacts: Sendable, Hashable {
    public var isCoolifyManaged: Bool
    public var volumes: [CoolifyVolume]
    public var proxy: CoolifyProxyFlavour
    /// Whether a staging directory can be created on the same filesystem as the
    /// live data, which is what makes a rename swap possible.
    public var stagingIsOnSameFilesystem: Bool
    public var isDatabase: Bool
    public var hasRunningContainer: Bool
    public var coolifySupportsRollingUpdate: Bool

    public init(
        isCoolifyManaged: Bool = false,
        volumes: [CoolifyVolume] = [],
        proxy: CoolifyProxyFlavour = .none,
        stagingIsOnSameFilesystem: Bool = true,
        isDatabase: Bool = false,
        hasRunningContainer: Bool = false,
        coolifySupportsRollingUpdate: Bool = false
    ) {
        self.isCoolifyManaged = isCoolifyManaged
        self.volumes = volumes
        self.proxy = proxy
        self.stagingIsOnSameFilesystem = stagingIsOnSameFilesystem
        self.isDatabase = isDatabase
        self.hasRunningContainer = hasRunningContainer
        self.coolifySupportsRollingUpdate = coolifySupportsRollingUpdate
    }
}

public struct RestorePlan: Sendable, Hashable {
    public var snapshotID: SnapshotID
    public var scope: RestoreScope
    public var target: RestoreTarget
    public var mode: RestoreMode
    /// Categories of excluded path the person has deliberately opted into.
    public var optedInExclusions: Set<RestoreExclusions.Category>
    public var serverHostname: String
    public var sshAuthorizedKeysPath: String

    public init(
        snapshotID: SnapshotID,
        scope: RestoreScope,
        target: RestoreTarget,
        mode: RestoreMode,
        optedInExclusions: Set<RestoreExclusions.Category> = [],
        serverHostname: String,
        sshAuthorizedKeysPath: String = "/root/.ssh/authorized_keys"
    ) {
        self.snapshotID = snapshotID
        self.scope = scope
        self.target = target
        self.mode = mode
        self.optedInExclusions = optedInExclusions
        self.serverHostname = serverHostname
        self.sshAuthorizedKeysPath = sshAuthorizedKeysPath
    }
}

/// Decides which modes are possible, and says why for every one of them.
public enum RestorePlanner {
    public static func availability(
        scope: RestoreScope,
        target: RestoreTarget,
        facts: RestoreFacts
    ) -> [RestoreModeAvailability] {
        [
            zeroDowntime(scope: scope, target: target, facts: facts),
            minimalDowntime(scope: scope, target: target, facts: facts),
            standard(scope: scope, target: target, facts: facts),
        ]
    }

    public static func availableModes(
        scope: RestoreScope,
        target: RestoreTarget,
        facts: RestoreFacts
    ) -> [RestoreMode] {
        availability(scope: scope, target: target, facts: facts)
            .filter(\.isAvailable)
            .map(\.mode)
    }

    /// The best mode that is actually possible, which is what the wizard
    /// should offer first.
    public static func recommendedMode(
        scope: RestoreScope,
        target: RestoreTarget,
        facts: RestoreFacts
    ) -> RestoreMode {
        availableModes(scope: scope, target: target, facts: facts).first ?? .standard
    }

    static func zeroDowntime(
        scope: RestoreScope,
        target: RestoreTarget,
        facts: RestoreFacts
    ) -> RestoreModeAvailability {
        let warning = """
        Writes made between the snapshot and the moment traffic switches over \
        are not preserved. Zero downtime means no interruption to requests, \
        not no loss of recent data.
        """

        func unavailable(_ reason: String) -> RestoreModeAvailability {
            RestoreModeAvailability(mode: .zeroDowntime, isAvailable: false, explanation: reason)
        }

        guard case .fullServer = scope else {
            guard facts.isCoolifyManaged else {
                return unavailable("""
                Zero downtime needs something that can run a second copy and \
                have traffic switched to it. This selection is not managed by \
                Coolify, so Hindsight has nothing to switch.
                """)
            }
            guard target.isInPlace else {
                return unavailable("""
                Zero downtime only applies to replacing a live resource. \
                Restoring to another location has no traffic to switch.
                """)
            }
            guard facts.hasRunningContainer else {
                return unavailable("""
                This resource is not running, so there is no downtime to \
                avoid. Use the standard restore.
                """)
            }
            guard facts.proxy != .none else {
                return unavailable("""
                No Coolify proxy was found on this server, so there is no \
                routing to switch.
                """)
            }
            guard facts.proxy != .unknown else {
                return unavailable("""
                The proxy on this server is not one Hindsight knows how to \
                switch routing on.
                """)
            }
            let bindMounts = facts.volumes.filter { !$0.isNamedVolume }
            guard bindMounts.isEmpty else {
                return unavailable("""
                This resource uses bind mounts (\(bindMounts.map(\.mountPath).joined(separator: ", "))), \
                so a second copy would read the same files as the live one. \
                Zero downtime needs named volumes that can be duplicated.
                """)
            }
            guard !facts.volumes.isEmpty else {
                return unavailable("""
                This resource has no persistent volumes, so there is nothing \
                to restore into a parallel copy.
                """)
            }
            return RestoreModeAvailability(
                mode: .zeroDowntime,
                isAvailable: true,
                explanation: facts.isDatabase
                    ? """
                    Restores into a new database instance and switches the \
                    connection over once it is healthy.
                    """
                    : """
                    Restores into new volumes, starts a parallel container, \
                    health-checks it, then switches the proxy over.
                    """,
                dataLossWarning: warning
            )
        }

        return unavailable("""
        A whole server cannot be replaced without interruption: there is no \
        second server to switch to. Restore a single resource for that, or use \
        minimal downtime.
        """)
    }

    static func minimalDowntime(
        scope: RestoreScope,
        target: RestoreTarget,
        facts: RestoreFacts
    ) -> RestoreModeAvailability {
        func unavailable(_ reason: String) -> RestoreModeAvailability {
            RestoreModeAvailability(mode: .minimalDowntime, isAvailable: false, explanation: reason)
        }

        guard target.isInPlace else {
            return unavailable("""
            Minimal downtime is about replacing live data quickly. Restoring \
            elsewhere does not touch the live copy, so there is no downtime.
            """)
        }
        guard facts.stagingIsOnSameFilesystem else {
            return unavailable("""
            The restored data cannot be staged on the same filesystem as the \
            live data, so the swap would be a copy rather than a rename and \
            would take as long as the restore itself.
            """)
        }
        if case .databaseDump = scope {
            return unavailable("""
            A database dump has to be loaded by the database itself, which \
            cannot be done by swapping files.
            """)
        }

        return RestoreModeAvailability(
            mode: .minimalDowntime,
            isAvailable: true,
            explanation: """
            Stages the restored data beside the live data, then stops, swaps it \
            in with a rename, and starts again. Downtime is the stop and start \
            only, not the transfer.
            """
        )
    }

    static func standard(
        scope: RestoreScope,
        target: RestoreTarget,
        facts: RestoreFacts
    ) -> RestoreModeAvailability {
        _ = facts
        _ = scope
        return RestoreModeAvailability(
            mode: .standard,
            isAvailable: true,
            explanation: target.isInPlace
                ? """
                Stops whatever is using the data, restores over it, and starts \
                again. Downtime lasts for the whole restore.
                """
                : "Restores to the chosen location, leaving the live data alone."
        )
    }
}
