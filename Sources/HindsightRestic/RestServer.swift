import Foundation
import HindsightCore
import HindsightProcess

public enum RestServerError: Error, Hashable, Sendable, CustomStringConvertible {
    case didNotReportItsPort(output: String)
    case exitedEarly(output: String)

    public var description: String {
        switch self {
        case let .didNotReportItsPort(output):
            "rest-server did not report a listening port.\n\(output)"
        case let .exitedEarly(output):
            "rest-server stopped before it was ready.\n\(output)"
        }
    }
}

/// Supervises one rest-server for the duration of a backup session.
///
/// Always append-only and always bound to loopback. The reverse tunnel exposes
/// this port to the server being backed up, so a compromised machine must not
/// be able to delete or rewrite anything it has already sent.
public actor RestServer {
    public struct Configuration: Sendable {
        /// The directory holding one subdirectory per server.
        public var repositoryRoot: URL
        public var credential: RestServerCredential
        public var htpasswdFile: URL
        public var executable: URL

        public init(
            repositoryRoot: URL,
            credential: RestServerCredential,
            htpasswdFile: URL,
            executable: URL
        ) {
            self.repositoryRoot = repositoryRoot
            self.credential = credential
            self.htpasswdFile = htpasswdFile
            self.executable = executable
        }
    }

    private let configuration: Configuration
    private let runner: ProcessRunner
    private var task: Task<Void, Never>?
    private var port: Int?

    public init(configuration: Configuration, runner: ProcessRunner = ProcessRunner()) {
        self.configuration = configuration
        self.runner = runner
    }

    public var listeningPort: Int? { port }

    /// Starts the server and waits until it reports the port it bound.
    ///
    /// The port is chosen by the kernel rather than by Hindsight, so two
    /// sessions can never collide, and rest-server's own startup line is what
    /// tells us which port it got.
    @discardableResult
    public func start(timeout: Duration = .seconds(20)) async throws -> Int {
        if let port { return port }

        try FileManager.default.createDirectory(
            at: configuration.repositoryRoot,
            withIntermediateDirectories: true
        )
        try configuration.credential.write(to: configuration.htpasswdFile)

        let command = Command(
            path: configuration.executable.path,
            arguments: [
                "--listen", "127.0.0.1:0",
                "--path", configuration.repositoryRoot.path,
                "--append-only",
                "--private-repos",
                "--htpasswd-file", configuration.htpasswdFile.path,
            ],
            additionalSecrets: [configuration.credential.password]
        )

        let (portStream, portContinuation) = AsyncStream<Int>.makeStream()
        var transcript: [String] = []
        let transcriptBox = TranscriptBox()

        task = Task { [runner] in
            do {
                for try await event in runner.stream(command) {
                    guard case let .line(_, line) = event else { continue }
                    await transcriptBox.append(line)
                    if let found = Self.parsePort(from: line) {
                        portContinuation.yield(found)
                    }
                }
            } catch {
                await transcriptBox.append("\(error)")
            }
            portContinuation.finish()
        }

        let deadline = Task {
            try await Task.sleep(for: timeout)
            portContinuation.finish()
        }
        defer { deadline.cancel() }

        for await found in portStream {
            port = found
            transcript = await transcriptBox.lines
            _ = transcript
            return found
        }

        let output = await transcriptBox.lines.joined(separator: "\n")
        await stop()
        throw RestServerError.didNotReportItsPort(output: output)
    }

    public func stop() async {
        task?.cancel()
        task = nil
        port = nil
        try? FileManager.default.removeItem(at: configuration.htpasswdFile)
    }

    /// The repository URL the server being backed up should use, given the port
    /// sshd allocated on its side of the tunnel.
    public func repositoryURL(remotePort: Int, serverID: ServerID) -> String {
        "rest:http://\(configuration.credential.urlUserInfo)@127.0.0.1:\(remotePort)/\(serverID.value)/"
    }

    static func parsePort(from line: String) -> Int? {
        // "start server on 127.0.0.1:55393"
        guard line.contains("start server on") else { return nil }
        guard let colon = line.lastIndex(of: ":") else { return nil }
        return Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

private actor TranscriptBox {
    private(set) var lines: [String] = []

    func append(_ line: String) {
        // Bounded: a server that logs forever must not grow this without end.
        if lines.count < 200 { lines.append(line) }
    }
}
