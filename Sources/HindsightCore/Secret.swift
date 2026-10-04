/// A value that must never reach a log, the catalog, a command line, or the UI.
///
/// Deliberately not `Codable`: persisting a secret is always a mistake, and the
/// compiler is a better guard against that than a review comment. Secrets live
/// in the Keychain and travel in process environments only.
public struct Secret: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    public var description: String { "<secret:\(label)>" }
    public var debugDescription: String { description }
}

public struct SecretRedactor: Sendable {
    private let ordered: [Secret]

    public init(_ secrets: [Secret] = []) {
        // Longest value first: when one secret contains another as a substring,
        // redacting the shorter one first would leave the remainder of the
        // longer one in the output.
        ordered = secrets
            .filter { !$0.value.isEmpty }
            .sorted { $0.value.count > $1.value.count }
    }

    public var isEmpty: Bool { ordered.isEmpty }

    public func adding(_ secrets: [Secret]) -> SecretRedactor {
        SecretRedactor(ordered + secrets)
    }

    public func redact(_ text: String) -> String {
        guard !ordered.isEmpty else { return text }
        var result = text
        for secret in ordered {
            guard result.contains(secret.value) else { continue }
            result = result.replacingOccurrences(of: secret.value, with: secret.description)
        }
        return result
    }
}
