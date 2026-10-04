import Foundation

/// Identifiers that are validated at construction because they are used as
/// filesystem path components, rest-server usernames, and ssh config aliases.
/// An unvalidated identifier there would be a path-traversal or
/// credential-confusion bug rather than a cosmetic problem.
public protocol TypedIdentifier: Hashable, Sendable, Codable, CustomStringConvertible {
    var value: String { get }
    init(unchecked value: String)
}

extension TypedIdentifier {
    public var description: String { value }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self.init(unchecked: raw)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct ServerID: TypedIdentifier {
    public static let allowedCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
    public static let maximumLength = 36

    public let value: String

    public init(unchecked value: String) {
        self.value = value
    }

    public init(validating raw: String) throws {
        guard !raw.isEmpty else { throw ValidationError.emptyServerID }
        guard raw.count <= Self.maximumLength else {
            throw ValidationError.serverIDTooLong(raw.count, maximum: Self.maximumLength)
        }
        guard raw.allSatisfy(Self.allowedCharacters.contains) else {
            throw ValidationError.serverIDHasDisallowedCharacters(raw)
        }
        guard raw.first != "-", raw.last != "-" else {
            throw ValidationError.serverIDHasDisallowedCharacters(raw)
        }
        self.value = raw
    }

    public static func generate() -> ServerID {
        ServerID(unchecked: UUID().uuidString.lowercased())
    }
}

public struct SnapshotID: TypedIdentifier {
    public static let fullLength = 64
    public static let shortLength = 8

    public let value: String

    public init(unchecked value: String) {
        self.value = value
    }

    public init(validating raw: String) throws {
        let lowered = raw.lowercased()
        guard !lowered.isEmpty else { throw ValidationError.emptySnapshotID }
        guard lowered.count <= Self.fullLength else {
            throw ValidationError.snapshotIDNotHexadecimal(raw)
        }
        guard lowered.allSatisfy(\.isHexDigit) else {
            throw ValidationError.snapshotIDNotHexadecimal(raw)
        }
        self.value = lowered
    }

    /// restic abbreviates ids to 8 characters in its own output and accepts the
    /// abbreviation as a command argument.
    public var short: String { String(value.prefix(Self.shortLength)) }
}

public struct JobID: TypedIdentifier {
    public let value: String

    public init(unchecked value: String) {
        self.value = value
    }

    public static func generate() -> JobID {
        JobID(unchecked: UUID().uuidString.lowercased())
    }
}
