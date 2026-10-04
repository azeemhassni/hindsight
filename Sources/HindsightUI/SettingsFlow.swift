import Foundation
import HindsightCore
import HindsightProtocol
import Observation

/// Edits a server's settings and saves them through the agent.
///
/// Changes are accumulated and sent as one sparse update: anything untouched
/// stays `nil`, so opening the settings form and closing it cannot silently
/// reset a field somebody set elsewhere.
@MainActor
@Observable
public final class SettingsFlow {
    public var cadence: Cadence
    public var onlyOnACPower: Bool
    public var retention: RetentionPolicy
    public var bandwidthLimitKiB: Int?
    public var repositoryPath: String
    public var coolifyToken: String
    public var checkRotationDivisor: Int
    public var excludePatterns: [String]

    public private(set) var isSaving = false
    public private(set) var lastSaveFailed: String?

    private let serverID: String
    private let model: AppModel
    private let original: Snapshot

    private struct Snapshot {
        var cadence: Cadence
        var onlyOnACPower: Bool
        var retention: RetentionPolicy
        var bandwidthLimitKiB: Int?
        var coolifyToken: String
        var checkRotationDivisor: Int
        var excludePatterns: [String]
    }

    public init(
        model: AppModel,
        serverID: String,
        cadence: Cadence,
        onlyOnACPower: Bool,
        retention: RetentionPolicy,
        bandwidthLimitKiB: Int?,
        repositoryPath: String,
        coolifyTokenIsSet: Bool,
        checkRotationDivisor: Int,
        excludePatterns: [String]
    ) {
        self.model = model
        self.serverID = serverID
        self.cadence = cadence
        self.onlyOnACPower = onlyOnACPower
        self.retention = retention
        self.bandwidthLimitKiB = bandwidthLimitKiB
        self.repositoryPath = repositoryPath
        // Never the token itself: it is in the Keychain, and reading it back
        // into a text field to display would be a reason to move it out.
        coolifyToken = coolifyTokenIsSet ? Self.tokenPlaceholder : ""
        self.checkRotationDivisor = checkRotationDivisor
        self.excludePatterns = excludePatterns

        original = Snapshot(
            cadence: cadence,
            onlyOnACPower: onlyOnACPower,
            retention: retention,
            bandwidthLimitKiB: bandwidthLimitKiB,
            coolifyToken: coolifyTokenIsSet ? Self.tokenPlaceholder : "",
            checkRotationDivisor: checkRotationDivisor,
            excludePatterns: excludePatterns
        )
    }

    /// Shown in place of a token that is already stored, so the field is not
    /// empty and the person is not invited to retype a secret they have.
    public static let tokenPlaceholder = "••••••••••••"

    public var hasChanges: Bool { update() != nil }

    /// A policy that keeps nothing would delete every snapshot on the next
    /// prune, so the form refuses to save it.
    public var keepsNothing: Bool {
        retention.keepWithinHours == 0 && retention.keepDaily == 0
            && retention.keepWeekly == 0 && retention.keepMonthly == 0
            && retention.keepYearly == 0
    }

    public var blockingReason: String? {
        if keepsNothing {
            return "A retention policy that keeps nothing would delete every snapshot."
        }
        if let limit = bandwidthLimitKiB, limit <= 0 {
            return "A bandwidth limit has to be greater than zero."
        }
        return nil
    }

    /// Only what actually changed.
    func update() -> ServerSettingsUpdate? {
        var update = ServerSettingsUpdate(serverID: serverID)
        var changed = false

        if cadence != original.cadence {
            update.cadence = try? JSONEncoder().encode(cadence)
            changed = true
        }
        if onlyOnACPower != original.onlyOnACPower {
            update.onlyOnACPower = onlyOnACPower
            changed = true
        }
        if retention.keepWithinHours != original.retention.keepWithinHours {
            update.keepWithinHours = retention.keepWithinHours
            changed = true
        }
        if retention.keepDaily != original.retention.keepDaily {
            update.keepDaily = retention.keepDaily
            changed = true
        }
        if retention.keepWeekly != original.retention.keepWeekly {
            update.keepWeekly = retention.keepWeekly
            changed = true
        }
        if retention.keepMonthly != original.retention.keepMonthly {
            update.keepMonthly = retention.keepMonthly
            changed = true
        }
        if retention.keepYearly != original.retention.keepYearly {
            update.keepYearly = retention.keepYearly
            changed = true
        }
        if bandwidthLimitKiB != original.bandwidthLimitKiB {
            update.bandwidthLimitKiB = bandwidthLimitKiB
            changed = true
        }
        if checkRotationDivisor != original.checkRotationDivisor {
            update.checkRotationDivisor = checkRotationDivisor
            changed = true
        }
        if excludePatterns != original.excludePatterns {
            update.excludePatterns = excludePatterns
            changed = true
        }
        // The placeholder means "unchanged"; an empty field means "remove it".
        if coolifyToken != original.coolifyToken, coolifyToken != Self.tokenPlaceholder {
            update.coolifyToken = coolifyToken
            changed = true
        }

        return changed ? update : nil
    }

    @discardableResult
    public func save() async -> Bool {
        guard blockingReason == nil, let update = update() else { return false }
        isSaving = true
        defer { isSaving = false }

        let succeeded = await model.updateSettings(update)
        lastSaveFailed = succeeded ? nil : (model.lastError ?? "The settings were not saved.")
        return succeeded
    }
}

extension SettingsFlow {
    /// Builds a flow from what the agent reports, so the view starts from the
    /// settings in force rather than from defaults that would overwrite them.
    public static func from(
        _ report: ServerSettingsReport,
        model: AppModel
    ) -> SettingsFlow {
        let cadence = report.cadence
            .flatMap { try? JSONDecoder().decode(Cadence.self, from: $0) }
            ?? .everyHours(6)
        // `RetentionPolicy` refuses a policy that keeps nothing, and a report
        // from an older catalog could be exactly that; falling back to the
        // default beats a crash in a settings pane.
        let retention = (try? RetentionPolicy(
            scope: .filesystem,
            keepWithinHours: report.keepWithinHours,
            keepDaily: report.keepDaily,
            keepWeekly: report.keepWeekly,
            keepMonthly: report.keepMonthly,
            keepYearly: report.keepYearly
        )) ?? .filesystemDefault

        return SettingsFlow(
            model: model,
            serverID: report.serverID,
            cadence: cadence,
            onlyOnACPower: report.onlyOnACPower,
            retention: retention,
            bandwidthLimitKiB: report.bandwidthLimitKiB,
            repositoryPath: report.repositoryPath,
            coolifyTokenIsSet: report.coolifyTokenIsSet,
            checkRotationDivisor: report.checkRotationDivisor,
            excludePatterns: report.excludePatterns
        )
    }
}
