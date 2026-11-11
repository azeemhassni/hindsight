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

        for try await event in runner.stream(
            Command(path: "/bin/sh", arguments: ["-c", "echo first; sleep 2; echo second"])
        ) {
            if case let .line(.standardOutput, line) = event {
                arrivals[line] = ContinuousClock.now
            }
        }

        let first = try #require(arrivals["first"])
        let second = try #require(arrivals["second"])
        // The gap is the whole proof: buffered output would land as one piece,
        // and no gap between the two lines would survive that.
        //
        // How long the process took to start is the machine's business, not
        // this code's, and asserting on it made the test fail on a loaded CI
        // runner that needed 0.67s to get `/bin/sh` going — by which time the
        // child had written both lines into the pipe and they arrived
        // together. The sleep is long enough that the gap outlasts any
        // plausible start-up delay.
        #expect(second - first > .seconds(1))
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

/// What a failure reads like.
///
/// A remote restic call is an ssh invocation wrapping a shell script wrapping
/// restic. Leading with that put three hundred characters in front of the one
/// line saying what went wrong, and a restore sheet showed the command twice
/// and the reason not at all.
@Suite("Failure messages")
struct ProcessErrorMessageTests {
    private let exit = ProcessExit(terminationStatus: 1, uncaughtSignal: nil, duration: .seconds(1))

    @Test("the reason comes before the command")
    func reasonLeads() {
        let error = ProcessError.exitedWithFailure(
            command: "ssh restic",
            exit: exit,
            standardError: "Fatal: unable to open repository at /nowhere"
        )
        let text = "\(error)"
        #expect(text.hasPrefix("Fatal: unable to open repository"))
        #expect(text.contains("ssh restic exited with status 1"))
    }

    @Test("a failure with nothing on stderr still says what ran")
    func withoutStandardError() {
        let error = ProcessError.exitedWithFailure(
            command: "ssh restic",
            exit: exit,
            standardError: "   \n "
        )
        #expect("\(error)" == "ssh restic exited with status 1.")
    }

    /// The long form is what made the message unreadable.
    @Test("a wrapped command is named by what it was doing")
    func shortDescriptionNamesTheOperation() {
        let command = Command(
            path: "/usr/bin/ssh",
            arguments: [
                "-F", "/Users/me/Library/Application Support/Hindsight/ssh/config",
                "hs-137-184-108-44", "--", "/bin/sh", "-c",
                "IFS= read -r __hs_RESTIC_PASSWORD || exit 97; export RESTIC_PASSWORD; restic restore …",
            ]
        )
        // Recognisable, and short enough to read.
        #expect(command.shortDescription == "ssh hs-137-184-108-44")
        #expect(command.shortDescription.count < 40)
        // Nothing from the script, which is where the secrets and the noise are.
        #expect(!command.shortDescription.contains("RESTIC_PASSWORD"))
    }
}
