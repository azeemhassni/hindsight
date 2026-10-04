import Foundation
import HindsightCore

/// The environment a child process receives.
///
/// Nothing is inherited by default beyond a small allowlist: inheriting the
/// user's environment wholesale would leak unrelated credentials into every ssh
/// and restic invocation, and would make runs depend on how the app was started.
public struct Environment: Sendable {
    public static let defaultInheritedKeys: Set<String> = ["PATH", "HOME", "TMPDIR", "LANG"]

    public var values: [String: String]
    /// Secret values travel here rather than in `arguments`, because `argv` is
    /// world-readable through `ps` while `/proc/<pid>/environ` is not.
    public var secretValues: [String: Secret]
    public var inheritedKeys: Set<String>

    public init(
        values: [String: String] = [:],
        secretValues: [String: Secret] = [:],
        inheritedKeys: Set<String> = Environment.defaultInheritedKeys
    ) {
        self.values = values
        self.secretValues = secretValues
        self.inheritedKeys = inheritedKeys
    }

    func resolved(parent: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var resolved = parent.filter { inheritedKeys.contains($0.key) }
        resolved.merge(values) { _, new in new }
        for (key, secret) in secretValues {
            resolved[key] = secret.value
        }
        return resolved
    }
}

public struct Command: Sendable {
    public enum StandardInput: Sendable {
        case none
        case data(Data)
    }

    /// Stored as a string, not a `URL`: `URL(fileURLWithPath:)` silently
    /// resolves a relative path against the current directory, and Hindsight
    /// must never resolve an executable through the environment or the working
    /// directory — it runs binaries it has verified at known paths.
    public var executablePath: String
    public var arguments: [String]
    public var environment: Environment
    public var workingDirectory: URL?
    public var standardInput: StandardInput
    /// Secrets that appear in output but not in the environment — a password a
    /// remote tool echoes back, for instance.
    public var additionalSecrets: [Secret]

    public init(
        path: String,
        arguments: [String] = [],
        environment: Environment = Environment(),
        workingDirectory: URL? = nil,
        standardInput: StandardInput = .none,
        additionalSecrets: [Secret] = []
    ) {
        self.executablePath = path
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.standardInput = standardInput
        self.additionalSecrets = additionalSecrets
    }

    public init(
        executable: URL,
        arguments: [String] = [],
        environment: Environment = Environment(),
        workingDirectory: URL? = nil,
        standardInput: StandardInput = .none,
        additionalSecrets: [Secret] = []
    ) {
        self.init(
            path: executable.path,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            standardInput: standardInput,
            additionalSecrets: additionalSecrets
        )
    }

    public var secrets: [Secret] {
        Array(environment.secretValues.values) + additionalSecrets
    }

    public var redactor: SecretRedactor { SecretRedactor(secrets) }

    /// A description safe to log: the executable and arguments with secrets
    /// redacted. Environment values are never included.
    public var redactedDescription: String {
        let joined = ([executablePath] + arguments)
            .map { $0.contains(" ") ? "\"\($0)\"" : $0 }
            .joined(separator: " ")
        return redactor.redact(joined)
    }

    var executableURL: URL { URL(fileURLWithPath: executablePath) }

    func validate() throws {
        guard executablePath.hasPrefix("/") else {
            throw ProcessError.executablePathNotAbsolute(executablePath)
        }
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw ProcessError.executableMissing(executablePath)
        }
        if let workingDirectory, !FileManager.default.fileExists(atPath: workingDirectory.path) {
            throw ProcessError.workingDirectoryMissing(workingDirectory.path)
        }
    }
}
