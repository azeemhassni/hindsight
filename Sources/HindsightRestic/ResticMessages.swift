import Foundation
import HindsightCore

/// Decoders for restic's `--json` output.
///
/// Every shape here was captured from restic 0.19.1 rather than recalled.
/// Unknown fields are ignored and new message types decode as `.unknown`, so a
/// restic upgrade degrades progress reporting instead of failing a backup.
public enum ResticMessage: Sendable, Hashable {
    case status(ResticStatus)
    case verboseStatus(ResticVerboseStatus)
    case error(ResticErrorMessage)
    case summary(ResticSummary)
    case unknown(type: String)

    public static func decode(line: String) -> ResticMessage? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // A pseudo-terminal interleaves other output with the JSON stream, so
        // anything that is not an object is skipped rather than treated as an
        // error.
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }

        let decoder = JSONDecoder.restic()
        guard let envelope = try? decoder.decode(MessageEnvelope.self, from: data) else { return nil }

        switch envelope.messageType {
        case "status":
            return (try? decoder.decode(ResticStatus.self, from: data)).map(ResticMessage.status)
        case "verbose_status":
            return (try? decoder.decode(ResticVerboseStatus.self, from: data)).map(ResticMessage.verboseStatus)
        case "error":
            return (try? decoder.decode(ResticErrorMessage.self, from: data)).map(ResticMessage.error)
        case "summary":
            return (try? decoder.decode(ResticSummary.self, from: data)).map(ResticMessage.summary)
        default:
            return .unknown(type: envelope.messageType)
        }
    }

    private struct MessageEnvelope: Decodable {
        let messageType: String

        enum CodingKeys: String, CodingKey {
            case messageType = "message_type"
        }
    }
}

public struct ResticStatus: Decodable, Sendable, Hashable {
    public var percentDone: Double
    public var totalFiles: Int?
    public var filesDone: Int?
    public var totalBytes: Int64?
    public var bytesDone: Int64?
    public var errorCount: Int?
    public var currentFiles: [String]?
    public var secondsElapsed: Int?
    public var secondsRemaining: Int?

    enum CodingKeys: String, CodingKey {
        case percentDone = "percent_done"
        case totalFiles = "total_files"
        case filesDone = "files_done"
        case totalBytes = "total_bytes"
        case bytesDone = "bytes_done"
        case errorCount = "error_count"
        case currentFiles = "current_files"
        case secondsElapsed = "seconds_elapsed"
        case secondsRemaining = "seconds_remaining"
    }
}

public struct ResticVerboseStatus: Decodable, Sendable, Hashable {
    public var action: String
    public var item: String
    public var duration: Double?
    public var dataSize: Int64?
    public var totalFiles: Int?

    enum CodingKeys: String, CodingKey {
        case action
        case item
        case duration
        case dataSize = "data_size"
        case totalFiles = "total_files"
    }
}

public struct ResticErrorMessage: Decodable, Sendable, Hashable {
    public struct Payload: Decodable, Sendable, Hashable {
        public var message: String
    }

    public var error: Payload
    public var during: String?
    public var item: String?
}

public struct ResticSummary: Decodable, Sendable, Hashable {
    public var filesNew: Int
    public var filesChanged: Int
    public var filesUnmodified: Int
    public var dirsNew: Int
    public var dirsChanged: Int
    public var dirsUnmodified: Int
    public var dataAdded: Int64
    public var dataAddedPacked: Int64?
    public var totalFilesProcessed: Int
    public var totalBytesProcessed: Int64
    public var totalDuration: Double?
    public var snapshotID: String?
    public var backupStart: Date?
    public var backupEnd: Date?

    enum CodingKeys: String, CodingKey {
        case filesNew = "files_new"
        case filesChanged = "files_changed"
        case filesUnmodified = "files_unmodified"
        case dirsNew = "dirs_new"
        case dirsChanged = "dirs_changed"
        case dirsUnmodified = "dirs_unmodified"
        case dataAdded = "data_added"
        case dataAddedPacked = "data_added_packed"
        case totalFilesProcessed = "total_files_processed"
        case totalBytesProcessed = "total_bytes_processed"
        case totalDuration = "total_duration"
        case snapshotID = "snapshot_id"
        case backupStart = "backup_start"
        case backupEnd = "backup_end"
    }
}

/// One entry of `restic snapshots --json`.
public struct ResticSnapshot: Decodable, Sendable, Hashable {
    public var id: String
    public var shortID: String?
    public var time: Date
    public var parent: String?
    public var tree: String?
    public var paths: [String]
    public var hostname: String?
    public var username: String?
    public var tags: [String]?
    public var programVersion: String?
    public var summary: ResticSummary?

    enum CodingKeys: String, CodingKey {
        case id
        case shortID = "short_id"
        case time
        case parent
        case tree
        case paths
        case hostname
        case username
        case tags
        case programVersion = "program_version"
        case summary
    }

    public func toSnapshot(kind: SnapshotKind? = nil) -> Snapshot {
        let tagSet = Set(tags ?? [])
        return Snapshot(
            id: SnapshotID(unchecked: id),
            time: time,
            hostname: hostname ?? "",
            paths: paths,
            tags: tagSet,
            kind: kind ?? Self.inferKind(from: tagSet),
            parent: parent.map { SnapshotID(unchecked: $0) },
            sizeBytes: summary?.totalBytesProcessed,
            dataAddedBytes: summary?.dataAdded
        )
    }

    /// The tag namespaces Hindsight writes are what distinguish a filesystem
    /// backup from a database dump or a pre-restore safety snapshot.
    static func inferKind(from tags: Set<String>) -> SnapshotKind {
        if tags.contains(.safety) { return .safety }
        if tags.contains(where: { $0.hasPrefix("db:") }) { return .databaseDump }
        if tags.contains(.profile("metadata")) { return .metadata }
        return .filesystem
    }
}

public struct ResticCheckSummary: Decodable, Sendable, Hashable {
    public var numErrors: Int
    public var brokenPacks: [String]?
    public var suggestRepairIndex: Bool?
    public var suggestPrune: Bool?

    enum CodingKeys: String, CodingKey {
        case numErrors = "num_errors"
        case brokenPacks = "broken_packs"
        case suggestRepairIndex = "suggest_repair_index"
        case suggestPrune = "suggest_prune"
    }

    public var isHealthy: Bool { numErrors == 0 && (brokenPacks?.isEmpty ?? true) }
}

/// One group of `restic forget --json`.
public struct ResticForgetGroup: Decodable, Sendable, Hashable {
    public var tags: [String]?
    public var host: String?
    public var paths: [String]?
    public var keep: [ResticSnapshot]?
    public var remove: [ResticSnapshot]?
}

public enum ResticDiffMessage: Sendable, Hashable {
    case change(path: String, modifier: String)
    case statistics(ResticDiffStatistics)

    public static func decode(line: String) -> ResticDiffMessage? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder.restic()
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else { return nil }
        switch envelope.messageType {
        case "change":
            guard let change = try? decoder.decode(Change.self, from: data) else { return nil }
            return .change(path: change.path, modifier: change.modifier)
        case "statistics":
            return (try? decoder.decode(ResticDiffStatistics.self, from: data)).map(ResticDiffMessage.statistics)
        default:
            return nil
        }
    }

    private struct Envelope: Decodable {
        let messageType: String
        enum CodingKeys: String, CodingKey { case messageType = "message_type" }
    }

    private struct Change: Decodable {
        let path: String
        let modifier: String
    }
}

public struct ResticDiffStatistics: Decodable, Sendable, Hashable {
    public struct Side: Decodable, Sendable, Hashable {
        public var files: Int
        public var dirs: Int
        public var others: Int?
        public var bytes: Int64
    }

    public var sourceSnapshot: String?
    public var targetSnapshot: String?
    public var changedFiles: Int
    public var added: Side
    public var removed: Side

    enum CodingKeys: String, CodingKey {
        case sourceSnapshot = "source_snapshot"
        case targetSnapshot = "target_snapshot"
        case changedFiles = "changed_files"
        case added
        case removed
    }
}

extension JSONDecoder {
    /// restic emits RFC 3339 timestamps, with fractional seconds in most places
    /// and without them in a few.
    public static func restic() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = ResticTimestamp.parse(text) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "not an RFC 3339 timestamp: \(text)"
                    )
                )
            }
            return date
        }
        return decoder
    }
}

/// Formatters are not `Sendable`, and these decoders run on many threads, so
/// each parse builds its own rather than sharing one.
enum ResticTimestamp {
    static func parse(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
