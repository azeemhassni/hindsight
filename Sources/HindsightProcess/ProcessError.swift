import Foundation

/// Every string stored here is already redacted; these values reach logs, the
/// catalog, and the UI unchanged.
public enum ProcessError: Error, Hashable, Sendable, CustomStringConvertible {
    case executablePathNotAbsolute(String)
    case executableMissing(String)
    case workingDirectoryMissing(String)
    case launchFailed(command: String, reason: String)
    case exitedWithFailure(command: String, exit: ProcessExit, standardError: String)
    case cancelled(command: String)
    case timedOut(command: String, after: Duration)

    public var description: String {
        switch self {
        case let .executablePathNotAbsolute(path):
            "Executable path \(path.debugDescription) must be absolute."
        case let .executableMissing(path):
            "No executable at \(path.debugDescription)."
        case let .workingDirectoryMissing(path):
            "No directory at \(path.debugDescription)."
        case let .launchFailed(command, reason):
            "Could not start \(command): \(reason)"
        case let .exitedWithFailure(command, exit, standardError):
            if let signal = exit.uncaughtSignal {
                "\(command) was killed by signal \(signal).\(Self.suffix(standardError))"
            } else {
                "\(command) exited with status \(exit.terminationStatus).\(Self.suffix(standardError))"
            }
        case let .cancelled(command):
            "\(command) was cancelled."
        case let .timedOut(command, after):
            "\(command) did not finish within \(after) and was stopped."
        }
    }

    private static func suffix(_ standardError: String) -> String {
        let trimmed = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : "\n\(trimmed)"
    }
}
