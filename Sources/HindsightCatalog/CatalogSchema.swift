import Foundation
import GRDB

/// The catalog's schema, as a sequence of migrations.
///
/// The catalog is an index and a history, never the source of truth for backup
/// data: everything here can be rebuilt from the restic repositories. That is
/// why migrations may drop and recompute derived rows, but never touch a
/// repository.
public enum CatalogSchema {
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-servers") { database in
            try database.create(table: "server") { table in
                table.primaryKey("id", .text)
                table.column("name", .text).notNull()
                table.column("host", .text).notNull()
                table.column("port", .integer).notNull()
                table.column("user", .text).notNull()
                table.column("authentication", .text).notNull()
                table.column("privilege", .text).notNull()
                table.column("platform", .blob)
                table.column("coolifyVersion", .text)
                table.column("createdAt", .datetime).notNull()
                table.column("lastSeenAt", .datetime)
            }

            try database.create(table: "repository") { table in
                table.primaryKey("id", .text)
                table.belongsTo("server", onDelete: .cascade).notNull()
                table.column("path", .text).notNull().unique()
                table.column("createdAt", .datetime).notNull()
                table.column("lastPrunedAt", .datetime)
                table.column("lastCheckedAt", .datetime)
                table.column("checkRotationIndex", .integer).notNull().defaults(to: 0)
                table.column("checkRotationDivisor", .integer).notNull().defaults(to: 4)
            }
        }

        migrator.registerMigration("v1-policies") { database in
            try database.create(table: "schedule") { table in
                table.primaryKey("id", .text)
                table.belongsTo("server", onDelete: .cascade).notNull()
                table.column("resourceUUID", .text)
                table.column("cadence", .blob).notNull()
                table.column("onlyOnACPower", .boolean).notNull().defaults(to: false)
                table.column("timeZoneIdentifier", .text)
                table.column("nextFireAt", .datetime)
                table.column("enabled", .boolean).notNull().defaults(to: true)
            }
            try database.create(
                index: "schedule_on_server_resource",
                on: "schedule",
                columns: ["serverId", "resourceUUID"],
                unique: true
            )

            try database.create(table: "retentionPolicy") { table in
                table.primaryKey("id", .text)
                table.belongsTo("server", onDelete: .cascade).notNull()
                table.column("scope", .text).notNull()
                table.column("keepWithinHours", .integer).notNull()
                table.column("keepDaily", .integer).notNull()
                table.column("keepWeekly", .integer).notNull()
                table.column("keepMonthly", .integer).notNull()
                table.column("keepYearly", .integer).notNull()
            }
            try database.create(
                index: "retentionPolicy_on_server_scope",
                on: "retentionPolicy",
                columns: ["serverId", "scope"],
                unique: true
            )

            try database.create(table: "pathRule") { table in
                table.autoIncrementedPrimaryKey("id")
                table.belongsTo("server", onDelete: .cascade).notNull()
                table.column("kind", .text).notNull()
                table.column("pattern", .text).notNull()
                table.column("source", .text).notNull()
            }
        }

        migrator.registerMigration("v1-snapshots") { database in
            try database.create(table: "snapshot") { table in
                table.primaryKey("resticID", .text)
                table.belongsTo("repository", onDelete: .cascade).notNull()
                table.column("time", .datetime).notNull()
                table.column("hostname", .text).notNull()
                table.column("paths", .blob).notNull()
                table.column("kind", .text).notNull()
                table.column("parentResticID", .text)
                table.column("sizeBytes", .integer)
                table.column("dataAddedBytes", .integer)
                table.column("recordedAt", .datetime).notNull()
            }
            try database.create(index: "snapshot_on_repository_time", on: "snapshot", columns: ["repositoryId", "time"])

            try database.create(table: "snapshotTag") { table in
                table.column("snapshotResticID", .text)
                    .notNull()
                    .references("snapshot", column: "resticID", onDelete: .cascade)
                table.column("tag", .text).notNull()
                table.primaryKey(["snapshotResticID", "tag"])
            }
            // Resource history is a tag query, so it must not be a table scan.
            try database.create(index: "snapshotTag_on_tag", on: "snapshotTag", columns: ["tag"])
        }

        migrator.registerMigration("v1-jobs") { database in
            try database.create(table: "job") { table in
                table.primaryKey("id", .text)
                table.belongsTo("server", onDelete: .cascade)
                table.column("kind", .blob).notNull()
                table.column("resourceUUID", .text)
                table.column("state", .text).notNull()
                table.column("queuedAt", .datetime).notNull()
                table.column("startedAt", .datetime)
                table.column("finishedAt", .datetime)
                table.column("bytesProcessed", .integer)
                table.column("bytesAdded", .integer)
                table.column("filesNew", .integer)
                table.column("filesChanged", .integer)
                table.column("snapshotResticID", .text)
                table.column("errorText", .text)
            }
            try database.create(index: "job_on_state", on: "job", columns: ["state"])
            try database.create(index: "job_on_server_queuedAt", on: "job", columns: ["serverId", "queuedAt"])

            try database.create(table: "jobEvent") { table in
                table.autoIncrementedPrimaryKey("id")
                table.belongsTo("job", onDelete: .cascade).notNull()
                table.column("sequence", .integer).notNull()
                table.column("at", .datetime).notNull()
                table.column("level", .text).notNull()
                table.column("message", .text).notNull()
            }
            try database.create(index: "jobEvent_on_job_sequence", on: "jobEvent", columns: ["jobId", "sequence"])
        }

        migrator.registerMigration("v1-integrity") { database in
            try database.create(table: "integrityCheck") { table in
                table.primaryKey("id", .text)
                table.belongsTo("repository", onDelete: .cascade).notNull()
                table.column("kind", .text).notNull()
                table.column("subsetIndex", .integer)
                table.column("subsetDivisor", .integer)
                table.column("startedAt", .datetime).notNull()
                table.column("finishedAt", .datetime)
                table.column("outcome", .text)
                table.column("errorText", .text)
            }
            try database.create(
                index: "integrityCheck_on_repository_startedAt",
                on: "integrityCheck",
                columns: ["repositoryId", "startedAt"]
            )
        }

        migrator.registerMigration("v1-coolify") { database in
            try database.create(table: "coolifyResource") { table in
                table.primaryKey("uuid", .text)
                table.belongsTo("server", onDelete: .cascade).notNull()
                table.column("kind", .text).notNull()
                table.column("name", .text).notNull()
                table.column("projectName", .text)
                table.column("environmentName", .text)
                table.column("discoverySource", .text).notNull()
                table.column("lastSeenAt", .datetime).notNull()
            }

            try database.create(table: "resourceCapture") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("resourceUUID", .text)
                    .notNull()
                    .references("coolifyResource", column: "uuid", onDelete: .cascade)
                table.column("snapshotResticID", .text)
                    .notNull()
                    .references("snapshot", column: "resticID", onDelete: .cascade)
                table.column("capturedAt", .datetime).notNull()
                table.column("volumes", .blob).notNull()
                table.column("configPaths", .blob).notNull()
                table.column("environmentSource", .text).notNull()
            }
        }

        migrator.registerMigration("v1-restores") { database in
            try database.create(table: "restore") { table in
                table.primaryKey("id", .text)
                table.belongsTo("server", onDelete: .cascade).notNull()
                table.column("sourceSnapshotResticID", .text).notNull()
                table.column("safetySnapshotResticID", .text)
                table.column("scope", .blob).notNull()
                table.column("target", .blob).notNull()
                table.column("mode", .text).notNull()
                table.column("state", .text).notNull()
                table.column("startedAt", .datetime).notNull()
                table.column("finishedAt", .datetime)
                table.column("errorText", .text)
            }
        }

        // Added after v1 shipped, so a new migration rather than an edit to
        // the original: an existing catalog has to keep opening.
        migrator.registerMigration("v2-bandwidth-limit") { database in
            try database.alter(table: "repository") { table in
                table.add(column: "bandwidthLimitKiB", .integer)
            }
        }

        // Adding a column cannot break a reference, so this asks for
        // per-statement checks rather than the whole-database scan GRDB
        // otherwise runs at the end of a migration. That scan fails on rows
        // left behind by an earlier build, and a migration that cannot finish
        // is an agent that cannot start.
        migrator.registerMigration("v3-pause", foreignKeyChecks: .immediate) { database in
            try database.alter(table: "server") { table in
                table.add(column: "pausedAt", .datetime)
            }
        }

        // Rows whose parent is gone — written by a build that did not enforce
        // references, or by a repair run through the sqlite3 command line,
        // which does not enforce them either. Nothing in the app can reach
        // such a row, and leaving one in means every later migration fails its
        // reference check: a catalog that will not open is an agent that will
        // not start.
        migrator.registerMigration("v4-orphaned-rows") { database in
            // Deleting a row cascades to its own children, which can expose
            // more orphans, so this repeats until the check comes back clean.
            for _ in 0 ..< 8 {
                let violations = try Row.fetchAll(database, sql: "PRAGMA foreign_key_check")
                if violations.isEmpty { break }
                for violation in violations {
                    guard let table: String = violation["table"],
                          let rowID: Int64 = violation["rowid"]
                    else { continue }
                    try database.execute(
                        sql: "DELETE FROM \"\(table)\" WHERE rowid = ?",
                        arguments: [rowID]
                    )
                }
            }
        }

        return migrator
    }
}
