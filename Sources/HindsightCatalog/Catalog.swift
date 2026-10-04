import Foundation
import GRDB
import HindsightCore

public enum CatalogError: Error, Hashable, Sendable, CustomStringConvertible {
    case schemaIsNewerThanThisBuild(found: [String], known: [String])
    case notFound(entity: String, id: String)

    public var description: String {
        switch self {
        case let .schemaIsNewerThanThisBuild(found, known):
            """
            This catalog was written by a newer version of Hindsight and will \
            not be opened, because guessing at an unknown schema risks the \
            backup history. Found migrations: \(found.joined(separator: ", ")). \
            This build knows: \(known.joined(separator: ", ")).
            """
        case let .notFound(entity, id):
            "No \(entity) with id \(id)."
        }
    }
}

/// The catalog database.
///
/// The agent opens one writable catalog and is the only writer. The app opens
/// a read-only one; WAL means its reads never block the agent's writes.
public struct Catalog: Sendable {
    public let database: any DatabaseWriter

    public init(database: any DatabaseWriter) {
        self.database = database
    }

    public static func configuration(readOnly: Bool = false) -> Configuration {
        var configuration = Configuration()
        configuration.readonly = readOnly
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA journal_mode = WAL")
            // A writer that gives up immediately would turn a routine overlap
            // with a reader into a failed backup.
            try database.execute(sql: "PRAGMA busy_timeout = 5000")
        }
        return configuration
    }

    /// Opens the writable catalog and brings it to the current schema.
    public static func open(at url: URL) throws -> Catalog {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let pool = try DatabasePool(path: url.path, configuration: configuration())
        let catalog = Catalog(database: pool)
        try catalog.migrate()
        return catalog
    }

    public static func inMemory() throws -> Catalog {
        let queue = try DatabaseQueue(configuration: configuration())
        let catalog = Catalog(database: queue)
        try catalog.migrate()
        return catalog
    }

    public func migrate() throws {
        let migrator = CatalogSchema.migrator
        try database.write { database in
            let applied = try migrator.appliedIdentifiers(database)
                .subtracting(migrator.migrations)
            // A catalog written by a newer build may have columns this one does
            // not understand. Refuse rather than write into a schema we cannot
            // reason about.
            guard applied.isEmpty else {
                throw CatalogError.schemaIsNewerThanThisBuild(
                    found: applied.sorted(),
                    known: migrator.migrations
                )
            }
        }
        try migrator.migrate(database)
    }

    public func read<T: Sendable>(_ body: @Sendable (Database) throws -> T) throws -> T {
        try database.read(body)
    }

    public func write<T: Sendable>(_ body: @Sendable (Database) throws -> T) throws -> T {
        try database.write(body)
    }
}

/// A read-only view for the UI.
public struct CatalogReader: Sendable {
    public let database: any DatabaseReader

    public init(database: any DatabaseReader) {
        self.database = database
    }

    public static func open(at url: URL) throws -> CatalogReader {
        let pool = try DatabasePool(path: url.path, configuration: Catalog.configuration(readOnly: true))
        return CatalogReader(database: pool)
    }

    public func read<T: Sendable>(_ body: @Sendable (Database) throws -> T) throws -> T {
        try database.read(body)
    }
}
