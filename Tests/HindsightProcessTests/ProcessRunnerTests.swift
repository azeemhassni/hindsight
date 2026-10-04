import Foundation
import HindsightCore
import Testing
@testable import HindsightProcess

@Suite("Process runner")
struct ProcessRunnerTests {
    let runner = ProcessRunner()

    @Test("captures stdout, stderr, and the exit status")
    func capturesOutput() async throws {
        let result = try await runner.run(
            Command(path: "/bin/sh", arguments: ["-c", "echo out; echo err 1>&2"])
        )
        #expect(result.standardOutput == "out")
        #expect(result.standardError == "err")
        #expect(result.exit.isSuccess)
        #expect(!result.outputWasTruncated)
    }

    @Test("streams lines as they are produced rather than buffering to completion")
    func streamsIncrementally() async throws {
        var arrivals: [String: ContinuousClock.Instant] = [:]
        let start = ContinuousClock.now

        for try await event in runner.stream(
            Command(path: "/bin/sh", arguments: ["-c", "echo first; sleep 0.5; echo second"])
        ) {
            if case let .line(.standardOutput, line) = event {
                arrivals[line] = ContinuousClock.now
            }
        }

        let first = try #require(arrivals["first"])
        let second = try #require(arrivals["second"])
        // If output were buffered until exit, both lines would land together.
        #expect(second - first > .milliseconds(300))
        #expect(first - start < .milliseconds(300))
    }

    @Test("emits a trailing line that has no newline")
    func flushesPartialLine() async throws {
        let result = try await runner.run(Command(path: "/usr/bin/printf", arguments: ["no-newline"]))
        #expect(result.standardOutput == "no-newline")
    }

    @Test("writes standard input without deadlocking on a large payload")
    func writesStandardInput() async throws {
        let payload = String(repeating: "x", count: 512 * 1024) + "\n"
        let result = try await runner.run(
            Command(path: "/bin/cat", standardInput: .data(Data(payload.utf8)))
        )
        #expect(result.standardOutput.count == payload.count - 1)
    }

    @Test("reports a non-zero exit as a failure")
    func reportsFailure() async throws {
        await #expect(throws: ProcessError.self) {
            try await runner.run(Command(path: "/bin/sh", arguments: ["-c", "echo boom 1>&2; exit 3"]))
        }

        do {
            _ = try await runner.run(Command(path: "/bin/sh", arguments: ["-c", "echo boom 1>&2; exit 3"]))
            Issue.record("expected a failure")
        } catch let error as ProcessError {
            guard case let .exitedWithFailure(_, exit, standardError) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(exit.terminationStatus == 3)
            #expect(standardError == "boom")
            #expect("\(error)".contains("status 3"))
        }
    }

    @Test("accepts a non-zero status when the caller allows it")
    func allowsExpectedNonZeroStatus() async throws {
        let result = try await runner.run(
            Command(path: "/bin/sh", arguments: ["-c", "exit 7"]),
            allowedExitCodes: [0, 7]
        )
        #expect(result.exit.terminationStatus == 7)
    }

    @Test("reports a command killed by a signal")
    func reportsSignal() async throws {
        do {
            _ = try await runner.run(Command(path: "/bin/sh", arguments: ["-c", "kill -TERM $$"]))
            Issue.record("expected a failure")
        } catch let error as ProcessError {
            guard case let .exitedWithFailure(_, exit, _) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(exit.uncaughtSignal == SIGTERM)
            #expect(!exit.isSuccess)
        }
    }

    @Test("refuses an executable that is not an absolute path")
    func refusesRelativeExecutable() async throws {
        await #expect(throws: ProcessError.executablePathNotAbsolute("sh")) {
            try await runner.run(Command(path: "sh"))
        }
    }

    @Test("refuses a missing executable before launching anything")
    func refusesMissingExecutable() async throws {
        await #expect(throws: ProcessError.executableMissing("/nonexistent/hindsight-tool")) {
            try await runner.run(Command(path: "/nonexistent/hindsight-tool"))
        }
    }

    @Test("truncates captured output beyond the cap but still reports the exit")
    func truncatesHugeOutput() async throws {
        let result = try await runner.run(
            Command(path: "/bin/sh", arguments: ["-c", "for i in $(seq 1 2000); do echo 0123456789; done"]),
            maximumCapturedBytes: 1024
        )
        #expect(result.outputWasTruncated)
        #expect(result.standardOutput.utf8.count <= 1024 + 32)
        #expect(result.exit.isSuccess)
    }
}

@Suite("Line splitting")
struct LineSplittingTests {
    @Test("splits on carriage returns, which is how a terminal rewrites a line")
    func splitsOnCarriageReturn() async throws {
        // restic separates progress updates with \r when it writes to a
        // terminal, so a splitter that only knows \n reports no progress at all.
        let result = try await ProcessRunner().run(
            Command(path: "/usr/bin/printf", arguments: ["a\rb\rc\n"])
        )
        #expect(result.standardOutputLines == ["a", "b", "c"])
    }

    @Test("treats CRLF as one break rather than two")
    func treatsCRLFAsOneBreak() async throws {
        let result = try await ProcessRunner().run(
            Command(path: "/usr/bin/printf", arguments: ["one\r\ntwo\r\n"])
        )
        #expect(result.standardOutputLines == ["one", "two"])
    }

    @Test("keeps a line that has no break at all")
    func keepsUnterminatedLine() async throws {
        let result = try await ProcessRunner().run(
            Command(path: "/usr/bin/printf", arguments: ["trailing"])
        )
        #expect(result.standardOutput == "trailing")
    }
}
