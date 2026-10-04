import Foundation
import HindsightCore

/// Gate on every operation that writes to a server.
///
/// There is no "unchecked" case on purpose: a caller must name the authority it
/// is acting under. Tests can only construct `.localTestTargetOnly`, which
/// demands both a local address and the marker file, so a test can never write
/// to a real host even if it is handed real credentials.
public enum DestructiveOperationPolicy: Sendable, Hashable {
    /// The person typed the server's hostname into the confirmation field.
    case userConfirmedHostname(String)
    /// The target is a throwaway local test machine.
    case localTestTargetOnly

    public func authorize(
        _ destination: SSHDestination,
        facts: RemoteFacts
    ) throws {
        switch self {
        case let .userConfirmedHostname(typed):
            let normalise = { (value: String) in
                value.trimmingCharacters(in: .whitespaces).lowercased()
            }
            guard normalise(typed) == normalise(destination.host) else {
                throw DestructiveOperationError.hostnameConfirmationMismatch(
                    typed: typed,
                    expected: destination.host
                )
            }
        case .localTestTargetOnly:
            guard NetworkPolicy.isLocalTestAddress(destination.host) else {
                throw DestructiveOperationError.targetIsNotLocal(destination.host)
            }
            guard facts.hasTestMarker else {
                throw DestructiveOperationError.testMarkerMissing(
                    host: destination.host,
                    path: Self.testMarkerPath
                )
            }
        }
    }

    public static let testMarkerPath = "/etc/hindsight-test-target"
}

public enum DestructiveOperationError: Error, Hashable, Sendable, CustomStringConvertible {
    case hostnameConfirmationMismatch(typed: String, expected: String)
    case targetIsNotLocal(String)
    case testMarkerMissing(host: String, path: String)

    public var description: String {
        switch self {
        case let .hostnameConfirmationMismatch(typed, expected):
            "\(typed.debugDescription) does not match the server's hostname \(expected.debugDescription)."
        case let .targetIsNotLocal(host):
            """
            Refusing a destructive operation against \(host): tests may only \
            write to a local Docker or virtual machine target.
            """
        case let .testMarkerMissing(host, path):
            """
            Refusing a destructive operation against \(host): \(path) is not \
            present, so this is not a machine marked as a throwaway test target.
            """
        }
    }
}
