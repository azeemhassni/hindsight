import Foundation
import HindsightCore

public struct QueuedJob: Sendable, Hashable, Identifiable {
    public var id: JobID
    public var serverID: ServerID
    public var kind: JobKind
    /// Jobs that name the same repository never run at the same time.
    public var repositoryPath: String
    public var queuedAt: Date

    public init(
        id: JobID = .generate(),
        serverID: ServerID,
        kind: JobKind,
        repositoryPath: String,
        queuedAt: Date = Date()
    ) {
        self.id = id
        self.serverID = serverID
        self.kind = kind
        self.repositoryPath = repositoryPath
        self.queuedAt = queuedAt
    }
}

public enum JobQueueEvent: Sendable {
    case queued(QueuedJob)
    /// Another job holds the repository; this one is waiting rather than lost.
    case waiting(QueuedJob, behind: JobID)
    case started(QueuedJob)
    case finished(QueuedJob, state: JobState, error: String?)
}

/// Runs jobs, one at a time per repository.
///
/// A queue rather than a lock at the call site, so the UI can always say what
/// is running, what is waiting, and why — rather than showing a job that
/// silently blocks somewhere inside the engine.
public actor JobQueue {
    public typealias Work = @Sendable (QueuedJob) async throws -> Void

    private var running: [String: JobID] = [:]
    /// Which server each running job belongs to, so everything for one server
    /// can be stopped without reaching into the catalog.
    private var jobServerIDs: [JobID: ServerID] = [:]
    private var pending: [String: [QueuedJob]] = [:]
    private var tasks: [JobID: Task<Void, Never>] = [:]
    private var observers: [UUID: @Sendable (JobQueueEvent) -> Void] = [:]
    private let work: Work

    public init(work: @escaping Work) {
        self.work = work
    }

    @discardableResult
    public func observe(_ observer: @escaping @Sendable (JobQueueEvent) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    public var runningJobIDs: [JobID] { Array(running.values) }

    public func pendingCount(forRepository path: String) -> Int {
        pending[path]?.count ?? 0
    }

    public func isRunning(repository path: String) -> Bool {
        running[path] != nil
    }

    /// Adds a job. Returns immediately; the work happens in the background.
    public func enqueue(_ job: QueuedJob) {
        emit(.queued(job))
        if let current = running[job.repositoryPath] {
            pending[job.repositoryPath, default: []].append(job)
            emit(.waiting(job, behind: current))
            return
        }
        start(job)
    }

    /// Waits for everything to finish. Used by tests and by a clean shutdown.
    public func drain() async {
        while !tasks.isEmpty {
            let current = tasks.values.map { $0 }
            for task in current { _ = await task.value }
        }
    }

    public func cancelAll() {
        for task in tasks.values { task.cancel() }
        pending.removeAll()
    }

    /// Stops one job, running or queued.
    ///
    /// Cancelling the task is what reaches the work: the process layer kills
    /// the ssh it is waiting on, so a backup stops within moments rather than
    /// when the server finishes whatever it was doing.
    @discardableResult
    public func cancel(jobID: JobID) -> Bool {
        if let task = tasks[jobID] {
            task.cancel()
            return true
        }
        for (path, queue) in pending {
            guard queue.contains(where: { $0.id == jobID }) else { continue }
            pending[path] = queue.filter { $0.id != jobID }
            return true
        }
        return false
    }

    /// Stops everything for one server: what is running, and what is waiting.
    @discardableResult
    public func cancelAll(forServer serverID: ServerID) -> Int {
        var stopped = 0
        for (path, queue) in pending {
            let keep = queue.filter { $0.serverID != serverID }
            stopped += queue.count - keep.count
            pending[path] = keep
        }
        for (id, task) in tasks where jobServerIDs[id] == serverID {
            task.cancel()
            stopped += 1
        }
        return stopped
    }

    private func start(_ job: QueuedJob) {
        running[job.repositoryPath] = job.id
        jobServerIDs[job.id] = job.serverID
        emit(.started(job))

        tasks[job.id] = Task { [work] in
            var state = JobState.succeeded
            var message: String?
            do {
                try await work(job)
            } catch is CancellationError {
                state = .cancelled
            } catch {
                state = .failed
                message = "\(error)"
            }
            await self.finish(job, state: state, error: message)
        }
    }

    private func finish(_ job: QueuedJob, state: JobState, error: String?) {
        tasks[job.id] = nil
        jobServerIDs[job.id] = nil
        running[job.repositoryPath] = nil
        emit(.finished(job, state: state, error: error))

        guard var queue = pending[job.repositoryPath], !queue.isEmpty else { return }
        let next = queue.removeFirst()
        pending[job.repositoryPath] = queue.isEmpty ? nil : queue
        start(next)
    }

    private func emit(_ event: JobQueueEvent) {
        for observer in observers.values { observer(event) }
    }
}
