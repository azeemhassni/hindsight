import Foundation
import GRDB
import HindsightCore

extension Catalog {
    // MARK: Servers

    public func save(_ server: Server) throws {
        try write { database in
            var record = ServerRecord(server: server)
            if let existing = try ServerRecord.fetchOne(database, key: server.id.value) {
                record.createdAt = existing.createdAt
                record.lastSeenAt = existing.lastSeenAt
            }
            try record.save(database)
        }
    }

    public func markSeen(_ id: ServerID, at date: Date = Date()) throws {
        try write { database in
            try database.execute(
                sql: "UPDATE server SET lastSeenAt = ? WHERE id = ?",
                arguments: [date, id.value]
            )
        }
    }

    public func server(_ id: ServerID) throws -> Server? {
        try read { try ServerRecord.fetchOne($0, key: id.value) }?.toServer()
    }

    public func servers() throws -> [Server] {
        try read { database in
            try ServerRecord.order(Column("name")).fetchAll(database)
        }
        .map { try $0.toServer() }
    }

    public func deleteServer(_ id: ServerID) throws {
        _ = try write { try ServerRecord.deleteOne($0, key: id.value) }
    }

    // MARK: Repositories

    public func save(_ repository: RepositoryRecord) throws {
        try write { try repository.save($0) }
    }

    public func repository(forServer id: ServerID) throws -> RepositoryRecord? {
        try read { database in
            try RepositoryRecord
                .filter(Column("serverId") == id.value)
                .fetchOne(database)
        }
    }

    public func repository(_ id: String) throws -> RepositoryRecord? {
        try read { try RepositoryRecord.fetchOne($0, key: id) }
    }

    public func repositories() throws -> [RepositoryRecord] {
        try read { try RepositoryRecord.fetchAll($0) }
    }

    // MARK: Policies

    public func save(_ schedule: ScheduleRecord) throws {
        try write { try schedule.save($0) }
    }

    public func schedules(forServer id: ServerID) throws -> [ScheduleRecord] {
        try read { database in
            try ScheduleRecord.filter(Column("serverId") == id.value).fetchAll(database)
        }
    }

    public func enabledSchedules() throws -> [ScheduleRecord] {
        try read { database in
            try ScheduleRecord.filter(Column("enabled") == true).fetchAll(database)
        }
    }

    public func save(_ policy: RetentionPolicyRecord) throws {
        try write { try policy.save($0) }
    }

    public func retentionPolicies(forServer id: ServerID) throws -> [RetentionPolicyRecord] {
        try read { database in
            try RetentionPolicyRecord.filter(Column("serverId") == id.value).fetchAll(database)
        }
    }

    /// Falls back to the documented defaults so a server always has a policy,
    /// and a missing row can never be read as "keep nothing".
    public func retentionPolicy(
        forServer id: ServerID,
        scope: RetentionPolicy.Scope
    ) throws -> RetentionPolicy {
        let record = try read { database in
            try RetentionPolicyRecord
                .filter(Column("serverId") == id.value && Column("scope") == scope.rawValue)
                .fetchOne(database)
        }
        if let record { return try record.toPolicy() }
        return scope == .filesystem ? .filesystemDefault : .databaseDumpsDefault
    }

    // MARK: Snapshots

    public func record(_ snapshot: Snapshot, inRepository repositoryId: String) throws {
        try write { database in
            try SnapshotRecord(snapshot: snapshot, repositoryId: repositoryId).save(database)
            try database.execute(
                sql: "DELETE FROM snapshotTag WHERE snapshotResticID = ?",
                arguments: [snapshot.id.value]
            )
            for tag in snapshot.tags.sorted() {
                try SnapshotTagRecord(snapshotResticID: snapshot.id.value, tag: tag).insert(database)
            }
        }
    }

    public func record(_ snapshots: [Snapshot], inRepository repositoryId: String) throws {
        try write { database in
            for snapshot in snapshots {
                try SnapshotRecord(snapshot: snapshot, repositoryId: repositoryId).save(database)
                try database.execute(
                    sql: "DELETE FROM snapshotTag WHERE snapshotResticID = ?",
                    arguments: [snapshot.id.value]
                )
                for tag in snapshot.tags.sorted() {
                    try SnapshotTagRecord(snapshotResticID: snapshot.id.value, tag: tag).insert(database)
                }
            }
        }
    }

    public func snapshots(inRepository repositoryId: String, limit: Int? = nil) throws -> [Snapshot] {
        try read { database in
            var request = SnapshotRecord
                .filter(Column("repositoryId") == repositoryId)
                .order(Column("time").desc)
            if let limit { request = request.limit(limit) }
            let records = try request.fetchAll(database)
            return try Self.attachTags(to: records, database: database)
        }
    }

    /// Tagged history is a tag query, which is why the tag column is indexed.
    public func snapshots(taggedWith tag: SnapshotTag) throws -> [Snapshot] {
        try read { database in
            let records = try SnapshotRecord
                .filter(
                    sql: """
                    resticID IN (SELECT snapshotResticID FROM snapshotTag WHERE tag = ?)
                    """,
                    arguments: [tag.rawValue]
                )
                .order(Column("time").desc)
                .fetchAll(database)
            return try Self.attachTags(to: records, database: database)
        }
    }

    public func snapshot(_ id: SnapshotID) throws -> Snapshot? {
        try read { database in
            guard let record = try SnapshotRecord.fetchOne(database, key: id.value) else { return nil }
            return try Self.attachTags(to: [record], database: database).first
        }
    }

    /// Removes snapshots that are no longer in the repository, which is how the
    /// catalog stays truthful after a prune.
    public func retainOnly(
        resticIDs: Set<String>,
        inRepository repositoryId: String
    ) throws -> Int {
        try write { database in
            let existing = try String.fetchAll(
                database,
                sql: "SELECT resticID FROM snapshot WHERE repositoryId = ?",
                arguments: [repositoryId]
            )
            let removed = Set(existing).subtracting(resticIDs)
            for id in removed {
                try database.execute(sql: "DELETE FROM snapshot WHERE resticID = ?", arguments: [id])
            }
            return removed.count
        }
    }

    private static func attachTags(
        to records: [SnapshotRecord],
        database: Database
    ) throws -> [Snapshot] {
        guard !records.isEmpty else { return [] }
        let ids = records.map(\.resticID)
        let tagRows = try SnapshotTagRecord
            .filter(ids.contains(Column("snapshotResticID")))
            .fetchAll(database)
        var tagsByID: [String: Set<String>] = [:]
        for row in tagRows {
            tagsByID[row.snapshotResticID, default: []].insert(row.tag)
        }
        return records.map { $0.toSnapshot(tags: tagsByID[$0.resticID] ?? []) }
    }

    /// Every snapshot for a server, for the timeline.
    public func snapshots(forServer id: ServerID, limit: Int? = nil) throws -> [Snapshot] {
        guard let repository = try repository(forServer: id) else { return [] }
        return try snapshots(inRepository: repository.id, limit: limit)
    }

    // MARK: Jobs

    public func save(_ job: JobRecord) throws {
        try write { try job.save($0) }
    }

    public func job(_ id: JobID) throws -> JobRecord? {
        try read { try JobRecord.fetchOne($0, key: id.value) }
    }

    public func jobs(forServer id: ServerID, limit: Int = 50) throws -> [JobRecord] {
        try read { database in
            try JobRecord
                .filter(Column("serverId") == id.value)
                .order(Column("queuedAt").desc)
                .limit(limit)
                .fetchAll(database)
        }
    }

    public func activeJobs() throws -> [JobRecord] {
        let terminal = JobState.allCases.filter(\.isTerminal).map(\.rawValue)
        return try read { database in
            try JobRecord
                .filter(!terminal.contains(Column("state")))
                .order(Column("queuedAt"))
                .fetchAll(database)
        }
    }

    @discardableResult
    public func append(
        _ message: String,
        level: JobEventLevel = .info,
        to jobID: JobID,
        at date: Date = Date()
    ) throws -> Int {
        try write { database in
            let next = try Int.fetchOne(
                database,
                sql: "SELECT COALESCE(MAX(sequence), 0) + 1 FROM jobEvent WHERE jobId = ?",
                arguments: [jobID.value]
            ) ?? 1
            var record = JobEventRecord(
                jobId: jobID.value,
                sequence: next,
                at: date,
                level: level,
                message: message
            )
            try record.insert(database)
            return next
        }
    }

    public func events(for jobID: JobID, limit: Int = 1000) throws -> [JobEventRecord] {
        try read { database in
            try JobEventRecord
                .filter(Column("jobId") == jobID.value)
                .order(Column("sequence"))
                .limit(limit)
                .fetchAll(database)
        }
    }

    /// Keeps the newest events for a job and drops the rest.
    ///
    /// A noisy or looping job would otherwise grow the catalog without bound,
    /// and the oldest lines are the least useful once a job has failed.
    @discardableResult
    public func trimEvents(for jobID: JobID, keeping limit: Int) throws -> Int {
        try write { database in
            try database.execute(
                sql: """
                DELETE FROM jobEvent
                WHERE jobId = ?
                  AND sequence <= (
                    SELECT COALESCE(MAX(sequence), 0) - ? FROM jobEvent WHERE jobId = ?
                  )
                """,
                arguments: [jobID.value, limit, jobID.value]
            )
            return database.changesCount
        }
    }

    // MARK: Integrity

    public func save(_ check: IntegrityCheckRecord) throws {
        try write { try check.save($0) }
    }

    public func latestCheck(forRepository repositoryId: String) throws -> IntegrityCheckRecord? {
        try read { database in
            try IntegrityCheckRecord
                .filter(Column("repositoryId") == repositoryId)
                .order(Column("startedAt").desc)
                .fetchOne(database)
        }
    }

    public func checks(forRepository repositoryId: String, limit: Int = 50) throws -> [IntegrityCheckRecord] {
        try read { database in
            try IntegrityCheckRecord
                .filter(Column("repositoryId") == repositoryId)
                .order(Column("startedAt").desc)
                .limit(limit)
                .fetchAll(database)
        }
    }
}

/// The read-only queries the app needs.
///
/// Separate from `Catalog` so the app physically cannot write: the agent is the
/// only writer, and two processes writing one SQLite file is a bug waiting for
/// a bad moment.
extension CatalogReader {
    public func servers() throws -> [Server] {
        try read { database in
            try ServerRecord.order(Column("name")).fetchAll(database)
        }
        .map { try $0.toServer() }
    }

    public func repository(forServer id: ServerID) throws -> RepositoryRecord? {
        try read { database in
            try RepositoryRecord.filter(Column("serverId") == id.value).fetchOne(database)
        }
    }

    public func snapshots(forServer id: ServerID, limit: Int? = nil) throws -> [Snapshot] {
        guard let repository = try repository(forServer: id) else { return [] }
        return try read { database in
            var request = SnapshotRecord
                .filter(Column("repositoryId") == repository.id)
                .order(Column("time").desc)
            if let limit { request = request.limit(limit) }
            let records = try request.fetchAll(database)
            let ids = records.map(\.resticID)
            let tagRows = try SnapshotTagRecord
                .filter(ids.contains(Column("snapshotResticID")))
                .fetchAll(database)
            var tagsByID: [String: Set<String>] = [:]
            for row in tagRows {
                tagsByID[row.snapshotResticID, default: []].insert(row.tag)
            }
            return records.map { $0.toSnapshot(tags: tagsByID[$0.resticID] ?? []) }
        }
    }

    public func jobs(forServer id: ServerID, limit: Int = 50) throws -> [JobRecord] {
        try read { database in
            try JobRecord
                .filter(Column("serverId") == id.value)
                .order(Column("queuedAt").desc)
                .limit(limit)
                .fetchAll(database)
        }
    }

    public func events(for jobID: JobID, limit: Int = 1000) throws -> [JobEventRecord] {
        try read { database in
            try JobEventRecord
                .filter(Column("jobId") == jobID.value)
                .order(Column("sequence"))
                .limit(limit)
                .fetchAll(database)
        }
    }

    public func latestCheck(forRepository repositoryId: String) throws -> IntegrityCheckRecord? {
        try read { database in
            try IntegrityCheckRecord
                .filter(Column("repositoryId") == repositoryId)
                .order(Column("startedAt").desc)
                .fetchOne(database)
        }
    }
}

extension Catalog {
    /// Replaces the exclude patterns a person added, leaving the profile's own
    /// defaults alone — those live in code, not in the catalog, so that a
    /// Hindsight upgrade can improve them.
    public func replaceUserExcludes(_ patterns: [String], forServer id: ServerID) throws {
        try write { database in
            try database.execute(
                sql: "DELETE FROM pathRule WHERE serverId = ? AND source = 'user' AND kind = 'exclude'",
                arguments: [id.value]
            )
            for pattern in patterns where !pattern.trimmingCharacters(in: .whitespaces).isEmpty {
                try database.execute(
                    sql: """
                    INSERT INTO pathRule (serverId, kind, pattern, source)
                    VALUES (?, 'exclude', ?, 'user')
                    """,
                    arguments: [id.value, pattern]
                )
            }
        }
    }

    public func userExcludes(forServer id: ServerID) throws -> [String] {
        try read { database in
            try String.fetchAll(
                database,
                sql: """
                SELECT pattern FROM pathRule
                WHERE serverId = ? AND source = 'user' AND kind = 'exclude'
                ORDER BY id
                """,
                arguments: [id.value]
            )
        }
    }
}

extension Catalog {
    /// Pauses or resumes a server's scheduled backups.
    ///
    /// Stored on the server rather than by disabling its schedules, so resuming
    /// restores exactly the schedule that was there — and so the interface can
    /// say "paused" rather than "no schedule", which is a different thing and
    /// looks like a mistake.
    @discardableResult
    public func setPaused(
        _ paused: Bool,
        forServer id: ServerID,
        at date: Date = Date()
    ) throws -> Bool {
        guard var found = try server(id) else { return false }
        found.pausedAt = paused ? (found.pausedAt ?? date) : nil
        try save(found)
        return true
    }
}
