import Foundation
import HindsightProtocol
import Testing
@testable import HindsightUI

/// The window used to sit on stale data until something unrelated made it
/// redraw: the agent's `catalogChanged` event did nothing at all, and a job
/// finishing never re-read the status that holds health, the last backup time
/// and the counts.
@MainActor
@Suite("Reacting to the agent")
struct ReactivityTests {
    private func model(counting requests: Counter) -> AppModel {
        let model = AppModel()
        model.send = { request in
            if case .status = request { requests.bump() }
            return .status(AgentStatus(version: "test", servers: [], runningJobs: []))
        }
        return model
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// The debounce is 300ms, so anything waiting on it needs longer.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(700))
    }

    @Test("a catalog change asks the agent for fresh state")
    func catalogChangeRefreshes() async {
        let requests = Counter()
        let model = model(counting: requests)

        model.apply(.catalogChanged)
        await settle()

        #expect(requests.count == 1)
        #expect(model.catalogRevision == 1)
    }

    @Test("a burst of changes costs one request, not one each")
    func coalescesABurst() async {
        let requests = Counter()
        let model = model(counting: requests)

        // What a backup with eleven database dumps looks like.
        for _ in 0..<11 { model.apply(.catalogChanged) }
        await settle()

        #expect(requests.count == 1)
    }

    @Test("a later change still gets its own refresh")
    func refreshesAgainAfterTheWindow() async {
        let requests = Counter()
        let model = model(counting: requests)

        model.apply(.catalogChanged)
        await settle()
        model.apply(.catalogChanged)
        await settle()

        #expect(requests.count == 2)
        #expect(model.catalogRevision == 2)
    }

    @Test("a finished job refreshes and marks the repository as changed")
    func finishedJobRefreshes() async {
        let requests = Counter()
        let model = model(counting: requests)

        model.apply(.jobFinished(id: "job-1", serverID: "web-01", succeeded: true, message: nil))
        await settle()

        #expect(requests.count == 1)
        // The size walk is expensive, so it keys off this rather than off
        // every refresh.
        #expect(model.repositoryContentsChanged == 1)
    }

    @Test("progress reports do not each cause a round trip")
    func progressDoesNotRefresh() async {
        let requests = Counter()
        let model = model(counting: requests)
        model.status = AgentStatus(version: "test", servers: [], runningJobs: [])

        for index in 0..<50 {
            model.apply(.jobProgress(RunningJob(
                id: "job-1",
                serverID: "web-01",
                kind: "backup",
                startedAt: Date(),
                percentDone: Double(index) / 50
            )))
        }
        await settle()

        // Progress is already in the event; asking the agent again for each
        // one would be fifty round trips during every backup.
        #expect(requests.count == 0)
        #expect(model.runningJobs.count == 1)
        #expect(model.runningJobs.first?.percentDone == 49.0 / 50)
    }
}
