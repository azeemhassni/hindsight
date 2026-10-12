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
    /// restic's own explanation of why a snapshot was kept, which is what the
    /// retention engine is checked against.
    public struct Reason: Decodable, Sendable, Hashable {
        public var snapshot: ResticSnapshot
        public var matches: [String]
    }

    public var tags: [String]?
    public var host: String?
    public var paths: [String]?
    public var keep: [ResticSnapshot]?
    public var remove: [ResticSnapshot]?
    public var reasons: [Reason]?
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

/// RFC 3339 timestamps, as restic writes them.
///
/// Parsed by hand rather than with `ISO8601DateFormatter`, which is not
/// `Sendable` and so had to be constructed per timestamp — sometimes twice,
/// when the first shape did not match. Measured on a listing of 26,575
/// entries: 9.1s with the formatters against 1.3s to read the same output
/// without decoding it, and every one of those nodes carries a timestamp.
enum ResticTimestamp {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    /// `2026-10-13T00:36:42.139773478+05:00`, `…Z`, and the same without a
    /// fractional part. Anything else is not a timestamp as far as this is
    /// concerned, which is what the decoder wants to hear.
    static func parse(_ text: String) -> Date? {
        let scalars = Array(text.utf8)
        // The date and time are fixed width: 19 characters before any
        // fraction or offset.
        guard scalars.count >= 20, scalars[4] == UInt8(ascii: "-"), scalars[7] == UInt8(ascii: "-"),
              scalars[10] == UInt8(ascii: "T"), scalars[13] == UInt8(ascii: ":"),
              scalars[16] == UInt8(ascii: ":"),
              let year = number(scalars, 0, 4),
              let month = number(scalars, 5, 2),
              let day = number(scalars, 8, 2),
              let hour = number(scalars, 11, 2),
              let minute = number(scalars, 14, 2),
              let second = number(scalars, 17, 2)
        else { return nil }

        // `Calendar` rolls an out-of-range component over rather than
        // refusing it, so month 13 would quietly become January of the next
        // year. A timestamp that cannot be read is better than one that is
        // wrong by a year.
        guard (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second)
        else { return nil }

        var index = 19
        var fraction: Double = 0
        if index < scalars.count, scalars[index] == UInt8(ascii: ".") {
            index += 1
            var digits = 0
            var scale: Double = 0.1
            while index < scalars.count, let digit = digitValue(scalars[index]) {
                fraction += Double(digit) * scale
                scale /= 10
                index += 1
                digits += 1
            }
            guard digits > 0 else { return nil }
        }

        let offset: Int
        if index < scalars.count, scalars[index] == UInt8(ascii: "Z") {
            offset = 0
            index += 1
        } else if index + 6 <= scalars.count,
                  scalars[index] == UInt8(ascii: "+") || scalars[index] == UInt8(ascii: "-"),
                  scalars[index + 3] == UInt8(ascii: ":"),
                  let offsetHours = number(scalars, index + 1, 2),
                  let offsetMinutes = number(scalars, index + 4, 2) {
            let magnitude = offsetHours * 3600 + offsetMinutes * 60
            offset = scalars[index] == UInt8(ascii: "-") ? -magnitude : magnitude
            index += 6
        } else {
            return nil
        }
        // Trailing rubbish means it was not a timestamp after all.
        guard index == scalars.count else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        guard let base = calendar.date(from: components) else { return nil }
        return base.addingTimeInterval(fraction - Double(offset))
    }

    private static func number(_ scalars: [UInt8], _ start: Int, _ length: Int) -> Int? {
        guard start + length <= scalars.count else { return nil }
        var value = 0
        for index in start..<(start + length) {
            guard let digit = digitValue(scalars[index]) else { return nil }
            value = value * 10 + digit
        }
        return value
    }

    private static func digitValue(_ byte: UInt8) -> Int? {
        guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
        return Int(byte - UInt8(ascii: "0"))
    }
}
