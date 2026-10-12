import Foundation
import HindsightCore

public enum RestoreScope: Sendable, Hashable, Codable {
    case fullServer
    case paths([String])
    /// A logical dump, restored into a database rather than onto the filesystem.
    case databaseDump(database: String?)

    public var describedForConfirmation: String {
        switch self {
        case .fullServer: "the whole server"
        case let .paths(paths) where paths.count == 1: paths[0]
        case let .paths(paths): "\(paths.count) paths"
        case let .databaseDump(database): "the database \(database ?? "dump")"
        }
    }
}

public enum RestoreTarget: Sendable, Hashable, Codable {
    case inPlace
    case alternatePath(String)
    /// A parallel copy under a new name, for looking at without touching the
    /// live resource.
    case clone(suffix: String)
    case anotherServer(serverID: String)

    public var isInPlace: Bool {
        if case .inPlace = self { return true }
        return false
    }

    public var isClone: Bool {
        if case .clone = self { return true }
        return false
    }
}

public enum RestoreMode: String, Sendable, Hashable, Codable, CaseIterable {
    case minimalDowntime
    case standard

    public var title: String {
        switch self {
        case .minimalDowntime: "Minimal downtime"
        case .standard: "Standard"
        }
    }

    public var summary: String {
        switch self {
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
    /// Set when a mode can lose data that the explanation alone would not
    /// make obvious.
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
    /// Whether a staging directory can be created on the same filesystem as the
    /// live data, which is what makes a rename swap possible.
    public var stagingIsOnSameFilesystem: Bool
    public var isDatabase: Bool
    public var hasRunningContainer: Bool

    public init(
        stagingIsOnSameFilesystem: Bool = true,
        isDatabase: Bool = false,
        hasRunningContainer: Bool = false
    ) {
        self.stagingIsOnSameFilesystem = stagingIsOnSameFilesystem
        self.isDatabase = isDatabase
        self.hasRunningContainer = hasRunningContainer
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
