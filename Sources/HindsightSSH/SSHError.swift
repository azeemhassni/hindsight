import Foundation
import HindsightCore

public enum SSHError: Error, Hashable, Sendable, CustomStringConvertible {
    case hostNotPermittedInThisBuild(String)
    case hostKeyChanged(host: String, details: String)
    case hostKeyNotTrusted(host: String)
    case hostKeyScanFailed(host: String, details: String)
    case noHostKeyOfSupportedType(host: String)
    case connectionFailed(host: String, details: String)
    case authenticationFailed(host: String, details: String)
    case sudoUnavailable(host: String, details: String)
    case reverseForwardNotAllocated(host: String, details: String)
    case controlDirectoryUnsafe(path: String, reason: String)
    case controlPathTooLong(path: String, limit: Int)
    case unexpectedProbeOutput(command: String, output: String)
    case remoteFileVerificationFailed(path: String, expected: String, actual: String)

    public var description: String {
        switch self {
        case let .hostNotPermittedInThisBuild(host):
            """
            Refusing to connect to \(host): this build only talks to local test \
            targets. Set HINDSIGHT_SSH_ALLOW_HOSTS to override deliberately.
            """
        case let .hostKeyChanged(host, details):
            """
            The host key for \(host) has changed. Hindsight will not connect \
            until this is resolved, because a changed key can mean the \
            connection is being intercepted.
            \(details)
            """
        case let .hostKeyNotTrusted(host):
            "The host key for \(host) has not been confirmed yet."
        case let .hostKeyScanFailed(host, details):
            "Could not read a host key from \(host): \(details)"
        case let .noHostKeyOfSupportedType(host):
            "\(host) offered no host key of a supported type."
        case let .connectionFailed(host, details):
            "Could not connect to \(host): \(details)"
        case let .authenticationFailed(host, details):
            "\(host) rejected the key: \(details)"
        case let .sudoUnavailable(host, details):
            "Passwordless sudo is not available on \(host): \(details)"
        case let .reverseForwardNotAllocated(host, details):
            "\(host) did not allocate a reverse port: \(details)"
        case let .controlDirectoryUnsafe(path, reason):
            "Refusing to use the connection-sharing directory \(path): \(reason)"
        case let .controlPathTooLong(path, limit):
            "The connection-sharing socket path is \(path.utf8.count) bytes; the limit is \(limit)."
        case let .unexpectedProbeOutput(command, output):
            "Unexpected output from \(command): \(output)"
        case let .remoteFileVerificationFailed(path, expected, actual):
            """
            \(path) on the server does not match its pinned digest.
              expected \(expected)
              actual   \(actual)
            """
        }
    }
}
