import Foundation
import HindsightCore
import HindsightProcess

/// Where a second copy of a repository is kept.
///
/// A repository on one disk is one disk away from no backups at all, which is
/// the failure the recovery kit warns about but cannot fix.
public enum SecondCopyTarget: Sendable, Hashable {
    /// Another disk on this Mac, or a mounted volume.
    case localPath(URL)
    /// S3-compatible object storage, including Backblaze B2's S3 endpoint.
    case s3(bucket: String, prefix: String?, endpoint: String?)
    case backblazeB2(bucket: String, prefix: String?)
    /// Another rest-server, for someone who already runs one elsewhere.
    case restServer(url: String)

    public var resticRepository: String {
        switch self {
        case let .localPath(url):
            url.path
        case let .s3(bucket, prefix, endpoint):
            "s3:\(endpoint ?? "s3.amazonaws.com")/\(bucket)\(prefix.map { "/\($0)" } ?? "")"
        case let .backblazeB2(bucket, prefix):
            "b2:\(bucket)\(prefix.map { ":\($0)" } ?? "")"
        case let .restServer(url):
            url.hasPrefix("rest:") ? url : "rest:\(url)"
        }
    }

    public var describedForUI: String {
        switch self {
        case let .localPath(url): url.path
        case let .s3(bucket, _, _): "S3 bucket \(bucket)"
        case let .backblazeB2(bucket, _): "Backblaze B2 bucket \(bucket)"
        case .restServer: "another restic server"
        }
    }

    /// Whether this target needs credentials beyond the repository password.
    public var needsCredentials: Bool {
        switch self {
        case .localPath: false
        case .s3, .backblazeB2, .restServer: true
        }
    }

    /// The environment variables each backend reads its credentials from.
    public var credentialVariables: [String] {
        switch self {
        case .localPath: []
        case .s3: ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"]
        case .backblazeB2: ["B2_ACCOUNT_ID", "B2_ACCOUNT_KEY"]
        case .restServer: []
        }
    }
}

public struct SecondCopyOutcome: Sendable, Hashable {
    public var snapshotsCopied: Int
    public var duration: Duration
    public var destination: String
}

public enum SecondCopyError: Error, Hashable, Sendable, CustomStringConvertible {
    case destinationNotInitialised(String)
    case copyFailed(details: String)
    case missingCredentials(variables: [String])

    public var description: String {
        switch self {
        case let .destinationNotInitialised(destination):
            "There is no restic repository at \(destination) yet."
        case let .copyFailed(details):
            "Copying to the second location failed: \(details)"
        case let .missingCredentials(variables):
            """
            The second copy needs credentials that are not in the Keychain: \
            \(variables.joined(separator: ", ")).
            """
        }
    }
}

/// Copies snapshots into a second repository.
///
/// Runs entirely on the Mac. Credentials for the second copy never reach a
/// server, which is the point: a compromised machine can add to its own
/// repository, but it cannot touch the copy that outlives it.
public struct SecondCopy: Sendable {
    public let executable: URL
    public let runner: ProcessRunner
    public let locks: RepositoryLockManager

    public init(
        executable: URL,
        runner: ProcessRunner = ProcessRunner(),
        locks: RepositoryLockManager = .shared
    ) {
        self.executable = executable
        self.runner = runner
        self.locks = locks
    }

    func environment(
        source: URL,
        sourcePassword: Secret,
        target: SecondCopyTarget,
        targetPassword: Secret,
        credentials: [String: Secret]
    ) throws -> Environment {
        let missing = target.credentialVariables.filter { credentials[$0] == nil }
        guard missing.isEmpty else {
            throw SecondCopyError.missingCredentials(variables: missing)
        }

        var secrets = credentials
        secrets["RESTIC_FROM_PASSWORD"] = sourcePassword
        secrets["RESTIC_PASSWORD"] = targetPassword

        return Environment(
            values: [
                "RESTIC_FROM_REPOSITORY": source.path,
                "RESTIC_REPOSITORY": target.resticRepository,
            ],
            secretValues: secrets
        )
    }

    /// Creates the destination repository if it does not exist.
    ///
    /// The copy keeps its own password, so losing the Mac does not hand over
    /// the second copy along with the first.
    @discardableResult
    public func initialiseIfNeeded(
        source: URL,
        sourcePassword: Secret,
        target: SecondCopyTarget,
        targetPassword: Secret,
        credentials: [String: Secret] = [:]
    ) async throws -> Bool {
        let environment = try environment(
            source: source,
            sourcePassword: sourcePassword,
            target: target,
            targetPassword: targetPassword,
            credentials: credentials
        )

        let existing = try await runner.run(
            Command(path: executable.path, arguments: ["cat", "config"], environment: environment),
            allowedExitCodes: Set((0...255).map(Int32.init))
        )
        if existing.exit.terminationStatus == 0 { return false }

        do {
            // `--copy-chunker-params` makes deduplication work across the two
            // repositories; without it the copy re-chunks everything and grows
            // far larger than the original.
            try await runner.run(
                Command(
                    path: executable.path,
                    arguments: ["init", "--from-repo", source.path, "--copy-chunker-params"],
                    environment: environment
                ),
                timeout: .seconds(300)
            )
        } catch {
            throw SecondCopyError.copyFailed(details: "\(error)")
        }
        return true
    }

    public func copy(
        source: URL,
        sourcePassword: Secret,
        target: SecondCopyTarget,
        targetPassword: Secret,
        credentials: [String: Secret] = [:],
        timeout: Duration = .seconds(21600)
    ) async throws -> SecondCopyOutcome {
        let environment = try environment(
            source: source,
            sourcePassword: sourcePassword,
            target: target,
            targetPassword: targetPassword,
            credentials: credentials
        )

        return try await locks.withLock(repositoryPath: source.path) {
            let started = ContinuousClock.now
            let result: ProcessResult
            do {
                result = try await runner.run(
                    Command(
                        path: executable.path,
                        arguments: ["copy", "--from-repo", source.path],
                        environment: environment
                    ),
                    timeout: timeout
                )
            } catch {
                throw SecondCopyError.copyFailed(details: "\(error)")
            }

            // restic reports each snapshot it copies; counting them is more
            // honest than reporting success with no idea what moved.
            let copied = result.standardOutputLines.filter {
                $0.contains("copy started") || $0.contains("snapshot") && $0.contains("saved")
            }.count

            return SecondCopyOutcome(
                snapshotsCopied: copied,
                duration: ContinuousClock.now - started,
                destination: target.describedForUI
            )
        }
    }
}
