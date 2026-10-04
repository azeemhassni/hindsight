import Foundation
import HindsightCore
import HindsightProcess

public struct SSHClient: Sendable {
    public struct Tools: Sendable, Hashable {
        public var ssh: String
        public var keyscan: String
        public var keygen: String

        public init(
            ssh: String = "/usr/bin/ssh",
            keyscan: String = "/usr/bin/ssh-keyscan",
            keygen: String = "/usr/bin/ssh-keygen"
        ) {
            self.ssh = ssh
            self.keyscan = keyscan
            self.keygen = keygen
        }
    }

    public let paths: SSHPaths
    public let policy: NetworkPolicy
    public let tools: Tools
    public let runner: ProcessRunner
    /// Control-socket operations talk to a local master and should answer
    /// immediately. A bound is still required: a wedged master makes them hang
    /// forever, which would silently stall a scheduled backup.
    public let controlOperationTimeout: Duration

    public init(
        paths: SSHPaths,
        policy: NetworkPolicy = .fromEnvironment(),
        tools: Tools = Tools(),
        runner: ProcessRunner = ProcessRunner(),
        controlOperationTimeout: Duration = .seconds(20)
    ) {
        self.paths = paths
        self.policy = policy
        self.tools = tools
        self.runner = runner
        self.controlOperationTimeout = controlOperationTimeout
    }

    // MARK: Host keys

    /// Fetches the host keys a server offers, for the first-connect confirmation.
    public func scanHostKeys(host: String, port: Int) async throws -> [HostKey] {
        try policy.check(host: host)

        let result: ProcessResult
        do {
            result = try await runner.run(
                Command(
                    path: tools.keyscan,
                    arguments: ["-T", "10", "-p", String(port), "-t", "ed25519,ecdsa,rsa", host]
                )
            )
        } catch let error as ProcessError {
            throw SSHError.hostKeyScanFailed(host: host, details: "\(error)")
        }

        var keys: [HostKey] = []
        for line in result.standardOutputLines {
            guard let key = HostKey.parse(keyscanLine: line) else { continue }
            keys.append(key.withFingerprint(try await fingerprint(of: key)))
        }

        guard !keys.isEmpty else {
            throw SSHError.hostKeyScanFailed(
                host: host,
                details: result.standardError.isEmpty ? "no keys returned" : result.standardError
            )
        }
        return keys.sorted { $0.preferenceRank < $1.preferenceRank }
    }

    func fingerprint(of key: HostKey) async throws -> String {
        let result = try await runner.run(
            Command(
                path: tools.keygen,
                arguments: ["-l", "-f", "-"],
                standardInput: .data(Data((key.knownHostsLine + "\n").utf8))
            )
        )
        guard let fingerprint = HostKey.parseFingerprint(result.standardOutput) else {
            throw SSHError.hostKeyScanFailed(host: key.host, details: "could not fingerprint the key")
        }
        return fingerprint
    }

    /// Records a host key as trusted. Called only after a person has confirmed
    /// the fingerprint.
    public func trust(_ key: HostKey, for destination: SSHDestination) throws {
        try paths.prepare()
        let entry = HostKey(
            host: destination.knownHostsHost,
            keyType: key.keyType,
            base64Key: key.base64Key,
            fingerprint: key.fingerprint
        )
        let line = entry.knownHostsLine + "\n"

        let existing = (try? String(contentsOf: paths.knownHostsFile, encoding: .utf8)) ?? ""
        guard !existing.contains(entry.knownHostsLine) else { return }
        try Data((existing + line).utf8).write(to: paths.knownHostsFile, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: paths.knownHostsFile.path
        )
    }

    public func trustedKeyLines(for destination: SSHDestination) throws -> [String] {
        let contents = (try? String(contentsOf: paths.knownHostsFile, encoding: .utf8)) ?? ""
        let prefix = destination.knownHostsHost + " "
        return contents
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix(prefix) }
    }

    public func isTrusted(_ destination: SSHDestination) throws -> Bool {
        try !trustedKeyLines(for: destination).isEmpty
    }

    /// Forgets a host key. Used when a user deliberately re-confirms a server
    /// that was rebuilt; never called automatically.
    public func forgetHostKeys(for destination: SSHDestination) throws {
        let contents = (try? String(contentsOf: paths.knownHostsFile, encoding: .utf8)) ?? ""
        let prefix = destination.knownHostsHost + " "
        let kept = contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.hasPrefix(prefix) }
        let rendered = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
        try Data(rendered.utf8).write(to: paths.knownHostsFile, options: .atomic)
    }

    // MARK: Running commands

    public func stream(
        _ command: RemoteCommand,
        on destination: SSHDestination,
        extraSSHArguments: [String] = []
    ) throws -> AsyncThrowingStream<ProcessEvent, any Error> {
        try policy.check(host: destination.host)
        let local = try localCommand(for: command, on: destination, extraSSHArguments: extraSSHArguments)
        return runner.stream(local)
    }

    @discardableResult
    public func run(
        _ command: RemoteCommand,
        on destination: SSHDestination,
        allowedExitCodes: Set<Int32> = [0],
        extraSSHArguments: [String] = [],
        timeout: Duration? = nil
    ) async throws -> ProcessResult {
        try policy.check(host: destination.host)
        let local = try localCommand(for: command, on: destination, extraSSHArguments: extraSSHArguments)
        do {
            return try await runner.run(local, allowedExitCodes: allowedExitCodes, timeout: timeout)
        } catch let error as ProcessError {
            throw Self.interpret(error, host: destination.host)
        }
    }

    func localCommand(
        for command: RemoteCommand,
        on destination: SSHDestination,
        extraSSHArguments: [String] = []
    ) throws -> Command {
        let script = try RemoteCommand.script(for: command)
        var remoteArguments = ["/bin/sh", "-c", script]
        if command.requiresRoot, destination.privilege == .sudo {
            remoteArguments = ["sudo", "-n"] + remoteArguments
        }

        var arguments = ["-F", paths.configFile.path]
        arguments += extraSSHArguments
        arguments.append(destination.configAlias)
        arguments.append("--")
        // ssh concatenates these with spaces for the remote login shell, so the
        // whole script is one quoted word by the time it is parsed there.
        arguments += remoteArguments.map(ShellQuoting.quote)

        return Command(
            path: tools.ssh,
            arguments: arguments,
            standardInput: .data(command.standardInputPayload()),
            additionalSecrets: command.secrets
        )
    }

    /// Turns ssh's exit status and stderr into something a person can act on.
    static func interpret(_ error: ProcessError, host: String) -> any Error {
        guard case let .exitedWithFailure(_, exit, standardError) = error else { return error }

        let text = standardError.lowercased()
        if text.contains("remote host identification has changed")
            || text.contains("host key verification failed") {
            return SSHError.hostKeyChanged(host: host, details: standardError)
        }
        if text.contains("permission denied")
            || text.contains("too many authentication failures")
            || text.contains("no such identity") {
            return SSHError.authenticationFailed(host: host, details: standardError)
        }
        if text.contains("sudo:") || text.contains("a password is required") {
            return SSHError.sudoUnavailable(host: host, details: standardError)
        }
        // 255 is ssh's own failure code; anything else came from the remote command.
        if exit.terminationStatus == 255 {
            return SSHError.connectionFailed(host: host, details: standardError)
        }
        return error
    }

    // MARK: Facts

    public func probeFacts(on destination: SSHDestination) async throws -> RemoteFacts {
        let result = try await run(
            RemoteCommand(executable: "/bin/sh", arguments: ["-c", RemoteFactsProbe.script]),
            on: destination
        )
        return try RemoteFactsProbe.parse(result.standardOutput)
    }

    // MARK: Files

    /// Writes a file on the server without ever naming its contents in argv.
    public func upload(
        _ data: Data,
        to remotePath: String,
        mode: String = "600",
        on destination: SSHDestination,
        requiresRoot: Bool = false
    ) async throws {
        let quoted = ShellQuoting.quote(remotePath)
        let temporary = ShellQuoting.quote(remotePath + ".hindsight-partial")
        let directory = ShellQuoting.quote((remotePath as NSString).deletingLastPathComponent)
        let script = """
        mkdir -p \(directory)
        cat > \(temporary)
        chmod \(ShellQuoting.quote(mode)) \(temporary)
        mv -f \(temporary) \(quoted)
        """
        try await run(
            RemoteCommand(
                executable: "/bin/sh",
                arguments: ["-c", script],
                requiresRoot: requiresRoot,
                standardInput: data
            ),
            on: destination
        )
    }

    public func remoteDigest(
        of remotePath: String,
        on destination: SSHDestination,
        requiresRoot: Bool = false
    ) async throws -> String? {
        let script = """
        if [ ! -f \(ShellQuoting.quote(remotePath)) ]; then exit 10; fi
        if command -v sha256sum >/dev/null 2>&1; then
          sha256sum \(ShellQuoting.quote(remotePath)) | cut -d' ' -f1
        else
          openssl dgst -sha256 -r \(ShellQuoting.quote(remotePath)) | cut -d' ' -f1
        fi
        """
        let result = try await run(
            RemoteCommand(executable: "/bin/sh", arguments: ["-c", script], requiresRoot: requiresRoot),
            on: destination,
            allowedExitCodes: [0, 10]
        )
        guard result.exit.terminationStatus == 0 else { return nil }
        let digest = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return digest.isEmpty ? nil : digest
    }

    // MARK: Connection sharing and reverse forwards

    /// Opens the shared connection if it is not already up.
    public func openControlMaster(on destination: SSHDestination) async throws {
        try policy.check(host: destination.host)
        if await controlMasterIsRunning(on: destination) { return }
        try removeStaleControlSocket(for: destination)
        try await run(
            RemoteCommand(executable: "/bin/true"),
            on: destination,
            timeout: controlOperationTimeout
        )
    }

    public func controlMasterIsRunning(on destination: SSHDestination) async -> Bool {
        let command = Command(
            path: tools.ssh,
            arguments: ["-F", paths.configFile.path, "-O", "check", destination.configAlias]
        )
        return (try? await runner.run(command, timeout: controlOperationTimeout)) != nil
    }

    /// Removes a socket whose master is gone.
    ///
    /// A master killed without cleanup leaves the socket behind, and ssh can
    /// block indefinitely trying to use it. Since this only runs after a check
    /// has already failed, the socket is known to be dead.
    public func removeStaleControlSocket(for destination: SSHDestination) throws {
        let path = try paths.controlPath(forToken: destination.controlToken)
        guard FileManager.default.fileExists(atPath: path) else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    public func closeControlMaster(on destination: SSHDestination) async {
        let command = Command(
            path: tools.ssh,
            arguments: ["-F", paths.configFile.path, "-O", "exit", destination.configAlias]
        )
        _ = try? await runner.run(command, timeout: controlOperationTimeout)
        try? removeStaleControlSocket(for: destination)
    }

    /// Asks the server for a reverse forward to `localPort` and returns the port
    /// it allocated.
    ///
    /// The remote port is chosen by sshd rather than by Hindsight: a fixed port
    /// would collide with whatever else the server happens to run.
    public func openReverseForward(
        toLocalPort localPort: Int,
        on destination: SSHDestination
    ) async throws -> Int {
        try await openControlMaster(on: destination)

        let specification = "0:127.0.0.1:\(localPort)"
        let result: ProcessResult
        do {
            result = try await runner.run(
                Command(
                    path: tools.ssh,
                    arguments: [
                        "-F", paths.configFile.path,
                        "-O", "forward",
                        "-R", specification,
                        destination.configAlias,
                    ]
                ),
                timeout: controlOperationTimeout
            )
        } catch let error as ProcessError {
            throw SSHError.reverseForwardNotAllocated(host: destination.host, details: "\(error)")
        }

        let combined = result.standardOutput + "\n" + result.standardError
        guard let port = Self.parseAllocatedPort(combined) else {
            throw SSHError.reverseForwardNotAllocated(
                host: destination.host,
                details: combined.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return port
    }

    public func closeReverseForward(
        remotePort: Int,
        toLocalPort localPort: Int,
        on destination: SSHDestination
    ) async {
        let command = Command(
            path: tools.ssh,
            arguments: [
                "-F", paths.configFile.path,
                "-O", "cancel",
                "-R", "\(remotePort):127.0.0.1:\(localPort)",
                destination.configAlias,
            ]
        )
        _ = try? await runner.run(command, timeout: controlOperationTimeout)
    }

    /// Runs `body` with a reverse forward in place, tearing it down even if the
    /// body throws.
    public func withReverseForward<T: Sendable>(
        toLocalPort localPort: Int,
        on destination: SSHDestination,
        _ body: @Sendable (Int) async throws -> T
    ) async throws -> T {
        let remotePort = try await openReverseForward(toLocalPort: localPort, on: destination)
        do {
            let value = try await body(remotePort)
            await closeReverseForward(remotePort: remotePort, toLocalPort: localPort, on: destination)
            return value
        } catch {
            await closeReverseForward(remotePort: remotePort, toLocalPort: localPort, on: destination)
            throw error
        }
    }

    static func parseAllocatedPort(_ output: String) -> Int? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let port = Int(trimmed), (1...65535).contains(port) { return port }
            // "Allocated port 54321 for remote forward to 127.0.0.1:8000"
            if trimmed.lowercased().hasPrefix("allocated port") {
                let fields = trimmed.split(separator: " ")
                if fields.count > 2, let port = Int(fields[2]) { return port }
            }
        }
        return nil
    }
}
