import Foundation
import HindsightCore
import HindsightProcess

public enum ResticError: Error, Hashable, Sendable, CustomStringConvertible {
    case repositoryAlreadyExists(path: String)
    case repositoryNotInitialized(path: String)
    case commandFailed(operation: String, details: String)
    case unexpectedOutput(operation: String, output: String)

    public var description: String {
        switch self {
        case let .repositoryAlreadyExists(path):
            "A restic repository already exists at \(path)."
        case let .repositoryNotInitialized(path):
            "There is no restic repository at \(path)."
        case let .commandFailed(operation, details):
            "restic \(operation) failed: \(details)"
        case let .unexpectedOutput(operation, output):
            "Could not read the output of restic \(operation): \(output)"
        }
    }
}

/// Where a repository lives, from the point of view of whoever is talking to it.
public enum ResticLocation: Sendable, Hashable {
    /// On the Mac's own filesystem. Everything destructive uses this: prune and
    /// forget are impossible through an append-only server, by design.
    case local(URL)
    /// Over the reverse tunnel, from the server being backed up.
    case rest(String)

    public var value: String {
        switch self {
        case let .local(url): url.path
        case let .rest(url): url
        }
    }
}

/// Runs restic on the Mac.
///
/// Only local operations live here. Anything that runs on a server goes through
/// the SSH layer, and anything destructive runs locally by design.
public struct ResticClient: Sendable {
    public let executable: URL
    public let location: ResticLocation
    public let password: Secret
    public let cacheDirectory: URL?
    public let runner: ProcessRunner

    public init(
        executable: URL,
        location: ResticLocation,
        password: Secret,
        cacheDirectory: URL? = nil,
        runner: ProcessRunner = ProcessRunner()
    ) {
        self.executable = executable
        self.location = location
        self.password = password
        self.cacheDirectory = cacheDirectory
        self.runner = runner
    }

    func command(_ arguments: [String], standardInput: Command.StandardInput = .none) -> Command {
        var values: [String: String] = ["RESTIC_REPOSITORY": location.value]
        if let cacheDirectory { values["RESTIC_CACHE_DIR"] = cacheDirectory.path }
        return Command(
            path: executable.path,
            arguments: arguments,
            environment: Environment(
                values: values,
                secretValues: ["RESTIC_PASSWORD": password]
            ),
            standardInput: standardInput
        )
    }

    @discardableResult
    func run(
        _ arguments: [String],
        operation: String,
        allowedExitCodes: Set<Int32> = [0],
        timeout: Duration? = nil
    ) async throws -> ProcessResult {
        do {
            return try await runner.run(
                command(arguments),
                allowedExitCodes: allowedExitCodes,
                timeout: timeout
            )
        } catch let error as ProcessError {
            throw ResticError.commandFailed(operation: operation, details: "\(error)")
        }
    }

    // MARK: Repository lifecycle

    public func repositoryExists() async throws -> Bool {
        let result = try await runner.run(
            command(["cat", "config"]),
            allowedExitCodes: Set((0...255).map(Int32.init))
        )
        return result.exit.terminationStatus == 0
    }

    public func initializeRepository() async throws {
        if try await repositoryExists() {
            throw ResticError.repositoryAlreadyExists(path: location.value)
        }
        try await run(["init", "--repository-version", "2"], operation: "init")
    }

    /// Initialises only if needed, which is what a backup preflight wants.
    @discardableResult
    public func initializeIfNeeded() async throws -> Bool {
        if try await repositoryExists() { return false }
        try await run(["init", "--repository-version", "2"], operation: "init")
        return true
    }

    // MARK: Reading

    public func snapshots(tag: SnapshotTag? = nil) async throws -> [ResticSnapshot] {
        var arguments = ["snapshots", "--json"]
        if let tag { arguments += ["--tag", tag.rawValue] }
        let result = try await run(arguments, operation: "snapshots")
        guard let data = result.standardOutput.data(using: .utf8), !data.isEmpty else { return [] }
        do {
            return try JSONDecoder.restic().decode([ResticSnapshot].self, from: data)
        } catch {
            throw ResticError.unexpectedOutput(operation: "snapshots", output: result.standardOutput)
        }
    }

    /// Lists a snapshot's contents.
    ///
    /// The first line of `ls --json` describes the snapshot and the rest are
    /// nodes, so the snapshot header is skipped by looking for a name.
    public func list(
        snapshot: SnapshotID,
        path: String? = nil,
        recursive: Bool = true
    ) async throws -> [ResticNode] {
        var arguments = ["ls", "--json"]
        if recursive { arguments.append("--recursive") }
        arguments.append(snapshot.value)
        if let path { arguments.append(path) }

        let result = try await run(arguments, operation: "ls")
        let decoder = JSONDecoder.restic()
        return result.standardOutputLines.compactMap { line in
            guard let data = line.data(using: .utf8), line.hasPrefix("{") else { return nil }
            return try? decoder.decode(ResticNode.self, from: data)
        }
    }

    public func stats() async throws -> ResticStats {
        let result = try await run(["stats", "--mode", "raw-data", "--json"], operation: "stats")
        guard let data = result.standardOutput.data(using: .utf8),
              let stats = try? JSONDecoder.restic().decode(ResticStats.self, from: data)
        else {
            throw ResticError.unexpectedOutput(operation: "stats", output: result.standardOutput)
        }
        return stats
    }

    // MARK: Maintenance

    /// Clears locks left behind by an interrupted run.
    ///
    /// Needed in normal operation: append-only mode deliberately allows a
    /// server to delete lock files, so a hostile or crashed one can leave them.
    public func unlock(removeAll: Bool = false) async throws {
        var arguments = ["unlock"]
        if removeAll { arguments.append("--remove-all") }
        try await run(arguments, operation: "unlock")
    }

    public func check(
        readDataSubset: String? = nil,
        timeout: Duration? = nil
    ) async throws -> ResticCheckSummary {
        var arguments = ["check", "--json"]
        if let readDataSubset { arguments += ["--read-data-subset", readDataSubset] }

        // A damaged repository makes check exit non-zero, and that output is
        // exactly what the caller needs to see.
        let result = try await runner.run(
            command(arguments),
            allowedExitCodes: Set((0...255).map(Int32.init)),
            timeout: timeout
        )

        for line in result.standardOutputLines.reversed() {
            guard let data = line.data(using: .utf8),
                  let summary = try? JSONDecoder.restic().decode(ResticCheckSummary.self, from: data)
            else { continue }
            return summary
        }

        throw ResticError.unexpectedOutput(
            operation: "check",
            output: result.standardOutput + result.standardError
        )
    }
}

public struct ResticNode: Decodable, Sendable, Hashable {
    public var name: String
    public var type: String
    public var path: String
    public var size: Int64?
    public var mode: Int?
    public var permissions: String?
    public var uid: Int?
    public var gid: Int?
    public var mtime: Date?

    public var isDirectory: Bool { type == "dir" }
    public var isFile: Bool { type == "file" }
    public var isSymlink: Bool { type == "symlink" }
}

public struct ResticStats: Decodable, Sendable, Hashable {
    public var totalSize: Int64
    public var totalFileCount: Int?
    public var totalBlobCount: Int?
    public var snapshotsCount: Int?

    enum CodingKeys: String, CodingKey {
        case totalSize = "total_size"
        case totalFileCount = "total_file_count"
        case totalBlobCount = "total_blob_count"
        case snapshotsCount = "snapshots_count"
    }
}
