import Foundation
import HindsightCore
import Testing
@testable import HindsightProcess

@Suite("Process cancellation")
struct ProcessCancellationTests {
    private actor PIDRecorder {
        private(set) var pid: Int32?
        func record(_ pid: Int32) { self.pid = pid }
    }

    @Test("cancelling the consumer kills the child", .timeLimit(.minutes(1)))
    func cancellationKillsChild() async throws {
        let runner = ProcessRunner(terminationGracePeriod: .milliseconds(200))
        let recorder = PIDRecorder()

        let task = Task {
            for try await event in runner.stream(Command(path: "/bin/sleep", arguments: ["120"])) {
                if case let .started(pid) = event {
                    await recorder.record(pid)
                }
            }
        }

        var pid: Int32?
        for _ in 0..<100 {
            if let found = await recorder.pid { pid = found; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let childPID = try #require(pid, "the child never reported its pid")

        let start = ContinuousClock.now
        task.cancel()
        _ = await task.result
        let elapsed = ContinuousClock.now - start

        // The command would have run for two minutes.
        #expect(elapsed < .seconds(10))

        var stillAlive = true
        for _ in 0..<100 where stillAlive {
            if kill(childPID, 0) != 0 && errno == ESRCH { stillAlive = false; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!stillAlive, "pid \(childPID) survived cancellation")
    }

    @Test("run() reports cancellation as a cancelled error", .timeLimit(.minutes(1)))
    func runReportsCancellation() async throws {
        let runner = ProcessRunner(terminationGracePeriod: .milliseconds(200))
        let task = Task {
            try await runner.run(Command(path: "/bin/sleep", arguments: ["120"]))
        }

        try await Task.sleep(for: .milliseconds(250))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch let error as ProcessError {
            guard case .cancelled = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        } catch is CancellationError {
            // Also acceptable: the task was cancelled before the process started.
        }
    }
}

@Suite("Process timeouts")
struct ProcessTimeoutTests {
    @Test("stops a command that overruns its timeout", .timeLimit(.minutes(1)))
    func stopsOverrunningCommand() async throws {
        let runner = ProcessRunner(terminationGracePeriod: .milliseconds(200))
        let start = ContinuousClock.now

        do {
            _ = try await runner.run(
                Command(path: "/bin/sleep", arguments: ["120"]),
                timeout: .milliseconds(500)
            )
            Issue.record("expected a timeout")
        } catch let error as ProcessError {
            guard case let .timedOut(_, after) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(after == .milliseconds(500))
            #expect("\(error)".contains("did not finish"))
        }

        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test("leaves a command that finishes in time alone")
    func allowsFastCommand() async throws {
        let result = try await ProcessRunner().run(
            Command(path: "/bin/echo", arguments: ["quick"]),
            timeout: .seconds(30)
        )
        #expect(result.standardOutput == "quick")
    }
}
