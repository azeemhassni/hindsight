import Foundation
import HindsightCatalog
import HindsightCore
import HindsightKeychain
import HindsightProtocol

/// Writing settings.
///
/// The agent applies them because it is the only writer of the catalog, and
/// because a Coolify token belongs in the Keychain rather than in a database
/// the app could read from disk.
extension AgentCore {
    func apply(_ update: ServerSettingsUpdate) async throws {
        let id = try ServerID(validating: update.serverID)
        guard try catalog.server(id) != nil else {
            throw AgentError.unknownServer(update.serverID)
        }

        try applySchedule(update, serverID: id)
        try applyRetention(update, serverID: id)
        try applyPathRules(update, serverID: id)
        try applyRotation(update, serverID: id)
        try applyBandwidthLimit(update, serverID: id)

        if let token = update.coolifyToken {
            // Never the catalog: a token is a credential, and the catalog is a
            // plain file the app can read.
            if token.isEmpty {
                try await deleteSecret(.coolifyToken(id))
            } else {
                try await writeSecret(token, for: .coolifyToken(id))
            }
        }
    }

    private func applySchedule(_ update: ServerSettingsUpdate, serverID: ServerID) throws {
        guard update.cadence != nil || update.onlyOnACPower != nil else { return }

        let existing = try catalog.schedules(forServer: serverID).first { $0.resourceUUID == nil }
        let currentSchedule = try existing?.toSchedule()

        let cadence: Cadence = try {
            if let data = update.cadence {
                return try JSONDecoder().decode(Cadence.self, from: data)
            }
            return currentSchedule?.cadence ?? .everyHours(6)
        }()

        let schedule = try Schedule(
            cadence: cadence,
            onlyOnACPower: update.onlyOnACPower ?? currentSchedule?.onlyOnACPower ?? false,
            timeZoneIdentifier: currentSchedule?.timeZoneIdentifier
        )

        try catalog.save(
            ScheduleRecord(
                id: existing?.id ?? "schedule-\(serverID.value)",
                serverId: serverID.value,
                schedule: schedule,
                nextFireAt: nil,
                enabled: existing?.enabled ?? true
            )
        )
    }

    private func applyRetention(_ update: ServerSettingsUpdate, serverID: ServerID) throws {
        let fields = [
            update.keepWithinHours, update.keepDaily, update.keepWeekly,
            update.keepMonthly, update.keepYearly,
        ]
        guard fields.contains(where: { $0 != nil }) else { return }

        let current = try catalog.retentionPolicy(forServer: serverID, scope: .filesystem)
        // `RetentionPolicy`'s own initialiser refuses a policy that keeps
        // nothing, so an unusable combination fails here rather than deleting
        // a repository on the next prune.
        let policy = try RetentionPolicy(
            scope: .filesystem,
            keepWithinHours: update.keepWithinHours ?? current.keepWithinHours,
            keepDaily: update.keepDaily ?? current.keepDaily,
            keepWeekly: update.keepWeekly ?? current.keepWeekly,
            keepMonthly: update.keepMonthly ?? current.keepMonthly,
            keepYearly: update.keepYearly ?? current.keepYearly
        )

        let existing = try catalog.retentionPolicies(forServer: serverID)
            .first { $0.scope == .filesystem }
        try catalog.save(
            RetentionPolicyRecord(
                id: existing?.id ?? "retention-\(serverID.value)-filesystem",
                serverId: serverID.value,
                policy: policy
            )
        )
    }

    private func applyPathRules(_ update: ServerSettingsUpdate, serverID: ServerID) throws {
        guard let patterns = update.excludePatterns else { return }
        try catalog.replaceUserExcludes(patterns, forServer: serverID)
    }

    private func applyBandwidthLimit(_ update: ServerSettingsUpdate, serverID: ServerID) throws {
        guard let limit = update.bandwidthLimitKiB,
              var repository = try catalog.repository(forServer: serverID)
        else { return }
        // Zero would mean "no transfer at all" to restic; the settings view
        // refuses it, and this refuses it again rather than trusting the caller.
        repository.bandwidthLimitKiB = limit > 0 ? limit : nil
        try catalog.save(repository)
    }

    private func applyRotation(_ update: ServerSettingsUpdate, serverID: ServerID) throws {
        guard let divisor = update.checkRotationDivisor,
              var repository = try catalog.repository(forServer: serverID)
        else { return }

        repository.checkRotationDivisor = max(1, divisor)
        // A smaller divisor can leave the index past the end of the rotation.
        repository.checkRotationIndex = repository.checkRotationIndex % repository.checkRotationDivisor
        try catalog.save(repository)
    }

    /// The exclude patterns a person added, on top of the profile's defaults.
    func userExcludes(forServer id: ServerID) throws -> [String] {
        try catalog.userExcludes(forServer: id)
    }
}

extension AgentCore {
    /// Reads settings back out, so the settings view starts from what is
    /// actually in force rather than from defaults that would overwrite it.
    func settings(forServer serverID: String) async throws -> ServerSettingsReport {
        let id = try ServerID(validating: serverID)
        guard try catalog.server(id) != nil else {
            throw AgentError.unknownServer(serverID)
        }

        let schedule = try catalog.schedules(forServer: id).first { $0.resourceUUID == nil }
        let resolved = try schedule?.toSchedule()
        let retention = try catalog.retentionPolicy(forServer: id, scope: .filesystem)
        let repository = try catalog.repository(forServer: id)

        return ServerSettingsReport(
            serverID: serverID,
            cadence: resolved.map { try? JSONEncoder().encode($0.cadence) } ?? nil,
            onlyOnACPower: resolved?.onlyOnACPower ?? false,
            keepWithinHours: retention.keepWithinHours,
            keepDaily: retention.keepDaily,
            keepWeekly: retention.keepWeekly,
            keepMonthly: retention.keepMonthly,
            keepYearly: retention.keepYearly,
            excludePatterns: (try? catalog.userExcludes(forServer: id)) ?? [],
            bandwidthLimitKiB: repository?.bandwidthLimitKiB,
            checkRotationDivisor: repository?.checkRotationDivisor ?? 1,
            repositoryPath: repository?.path ?? "",
            coolifyTokenIsSet: await hasSecret(.coolifyToken(id))
        )
    }
}
