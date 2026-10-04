import Foundation
import HindsightCore

public struct RemoteCommand: Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    /// Delivered over stdin and exported inside the remote shell, never placed
    /// in `argv`, where `ps` would show it to every user on the server.
    public var secretEnvironment: [String: Secret]
    public var requiresRoot: Bool
    /// Prefix argv such as `nice -n 19 ionice -c3`, decided from probed facts
    /// so a server without `ionice` is not sent a command it cannot run.
    public var priorityPrefix: [String]
    public var standardInput: Data?

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        secretEnvironment: [String: Secret] = [:],
        requiresRoot: Bool = false,
        priorityPrefix: [String] = [],
        standardInput: Data? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.secretEnvironment = secretEnvironment
        self.requiresRoot = requiresRoot
        self.priorityPrefix = priorityPrefix
        self.standardInput = standardInput
    }

    /// A shell script rather than a plain command list because ssh has no argv
    /// and because secrets must arrive over stdin. `exec` keeps the process
    /// tree shallow so a signal reaches the real command.
    public static func script(for command: RemoteCommand) throws -> String {
        var lines: [String] = []

        for key in command.secretEnvironment.keys.sorted() {
            guard let secret = command.secretEnvironment[key] else { continue }
            guard !secret.value.contains("\n"), !secret.value.contains("\r") else {
                throw RemoteCommandError.secretContainsNewline(label: secret.label)
            }
            let variable = "__hs_\(key)"
            lines.append("IFS= read -r \(variable) || exit 97")
            lines.append("\(key)=\"$\(variable)\"; export \(key); unset \(variable)")
        }

        for key in command.environment.keys.sorted() {
            guard let value = command.environment[key] else { continue }
            lines.append("\(key)=\(ShellQuoting.quote(value)); export \(key)")
        }

        let argv = command.priorityPrefix + [command.executable] + command.arguments
        lines.append("exec \(ShellQuoting.quote(argv))")
        return lines.joined(separator: "\n")
    }

    /// Secret values, newline-terminated, in the order the script reads them,
    /// followed by any payload the command expects on stdin.
    public func standardInputPayload() -> Data {
        var data = Data()
        for key in secretEnvironment.keys.sorted() {
            guard let secret = secretEnvironment[key] else { continue }
            data.append(Data((secret.value + "\n").utf8))
        }
        if let standardInput {
            data.append(standardInput)
        }
        return data
    }

    public var secrets: [Secret] { Array(secretEnvironment.values) }
}

public enum RemoteCommandError: Error, Hashable, Sendable, CustomStringConvertible {
    case secretContainsNewline(label: String)

    public var description: String {
        switch self {
        case let .secretContainsNewline(label):
            "The secret \(label) contains a newline and cannot be sent to a remote shell."
        }
    }
}
