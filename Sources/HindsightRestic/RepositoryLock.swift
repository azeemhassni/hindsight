import Foundation

public enum RepositoryLockError: Error, Hashable, Sendable, CustomStringConvertible {
    case busy(path: String)
    case couldNotOpen(path: String, reason: String)

    public var description: String {
        switch self {
        case let .busy(path):
            "Another Hindsight operation is using the repository at \(path)."
        case let .couldNotOpen(path, reason):
            "Could not take the repository lock at \(path): \(reason)"
        }
    }
}

/// Serialises every operation against one repository.
///
/// Two layers, because there are two ways to collide: an actor for jobs inside
/// one process, and `flock` for the app and the agent, which are separate
/// processes that can both be running.
public actor RepositoryLockManager {
    public static let shared = RepositoryLockManager()

    private var inProcess: [String: Int] = [:]
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    public func withLock<T: Sendable>(
        repositoryPath: String,
        waitForOtherProcesses: Bool = true,
        _ body: () async throws -> T
    ) async throws -> T {
        await acquireInProcess(repositoryPath)
        defer { releaseInProcess(repositoryPath) }

        let file = try FileLock(
            path: URL(fileURLWithPath: repositoryPath).appendingPathComponent(".hindsight.lock").path
        )
        try file.lock(blocking: waitForOtherProcesses)
        defer { file.unlock() }

        return try await body()
    }

    private func acquireInProcess(_ path: String) async {
        while inProcess[path] != nil {
            await withCheckedContinuation { continuation in
                waiters[path, default: []].append(continuation)
            }
        }
        inProcess[path] = 1
    }

    private func releaseInProcess(_ path: String) {
        inProcess[path] = nil
        guard var queue = waiters[path], !queue.isEmpty else { return }
        let next = queue.removeFirst()
        waiters[path] = queue.isEmpty ? nil : queue
        next.resume()
    }
}

/// A `flock` on a file inside the repository directory.
public final class FileLock: @unchecked Sendable {
    private let descriptor: Int32
    public let path: String

    public init(path: String) throws {
        self.path = path
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else {
            throw RepositoryLockError.couldNotOpen(path: path, reason: String(cString: strerror(errno)))
        }
    }

    deinit {
        close(descriptor)
    }

    public func lock(blocking: Bool) throws {
        let operation = blocking ? LOCK_EX : (LOCK_EX | LOCK_NB)
        while flock(descriptor, operation) != 0 {
            if errno == EINTR { continue }
            if errno == EWOULDBLOCK { throw RepositoryLockError.busy(path: path) }
            throw RepositoryLockError.couldNotOpen(path: path, reason: String(cString: strerror(errno)))
        }
    }

    public func unlock() {
        _ = flock(descriptor, LOCK_UN)
    }
}
