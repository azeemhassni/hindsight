import Foundation
import HindsightCore

public struct ProcessRunner: Sendable {
    public static let defaultMaximumLineLength = 1 << 20
    public static let defaultMaximumCapturedBytes = 4 << 20

    public var maximumLineLength: Int
    public var terminationGracePeriod: Duration

    public init(
        maximumLineLength: Int = ProcessRunner.defaultMaximumLineLength,
        terminationGracePeriod: Duration = .seconds(5)
    ) {
        self.maximumLineLength = maximumLineLength
        self.terminationGracePeriod = terminationGracePeriod
    }

    /// Streams the command's output as redacted lines, ending in `.exited`.
    ///
    /// Cancelling the consuming task terminates the child: SIGTERM first, then
    /// SIGKILL after the grace period.
    public func stream(_ command: Command) -> AsyncThrowingStream<ProcessEvent, any Error> {
        let maximumLineLength = maximumLineLength
        let grace = terminationGracePeriod

        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            do {
                try command.validate()
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let redactor = command.redactor
            let description = command.redactedDescription
            let session = ProcessSession(command: command)
            let start = ContinuousClock.now

            let pid: Int32
            do {
                pid = try session.launch()
            } catch {
                continuation.finish(
                    throwing: ProcessError.launchFailed(
                        command: description,
                        reason: redactor.redact(String(describing: error))
                    )
                )
                return
            }

            continuation.yield(.started(pid: pid))

            let queue = DispatchQueue(
                label: "dev.hindsight.process.\(pid)",
                attributes: .concurrent
            )
            let readers = DispatchGroup()

            queue.async { session.writeStandardInput() }

            for stream in ProcessStream.allCases {
                queue.async(group: readers) {
                    Self.pump(
                        session: session,
                        stream: stream,
                        redactor: redactor,
                        maximumLineLength: maximumLineLength,
                        continuation: continuation
                    )
                }
            }

            // Both pipes are at end of file here, so the child has closed them
            // and `waitUntilExit` returns promptly. Waiting for the readers
            // first is what guarantees every line precedes `.exited`.
            readers.notify(queue: queue) {
                continuation.yield(.exited(session.waitForExit(startedAt: start)))
                continuation.finish()
            }

            continuation.onTermination = { reason in
                guard case .cancelled = reason else { return }
                session.terminate()
                queue.asyncAfter(deadline: .now() + grace.timeInterval) { session.kill() }
            }
        }
    }

    /// Runs to completion and collects output.
    ///
    /// `allowedExitCodes` exists because several commands Hindsight runs report
    /// a legitimate answer through a non-zero status, `test -f` among them.
    @discardableResult
    public func run(
        _ command: Command,
        allowedExitCodes: Set<Int32> = [0],
        maximumCapturedBytes: Int = ProcessRunner.defaultMaximumCapturedBytes
    ) async throws -> ProcessResult {
        var captured: [ProcessStream: String] = [.standardOutput: "", .standardError: ""]
        var capturedBytes = 0
        var wasTruncated = false
        var exit: ProcessExit?

        for try await event in stream(command) {
            switch event {
            case .started:
                continue
            case let .line(stream, line):
                guard capturedBytes < maximumCapturedBytes else {
                    wasTruncated = true
                    continue
                }
                capturedBytes += line.utf8.count + 1
                captured[stream, default: ""] += captured[stream, default: ""].isEmpty ? line : "\n" + line
            case let .exited(status):
                exit = status
            }
        }

        let standardError = captured[.standardError] ?? ""

        guard let exit else {
            if Task.isCancelled {
                throw ProcessError.cancelled(command: command.redactedDescription)
            }
            throw ProcessError.launchFailed(
                command: command.redactedDescription,
                reason: "the process ended without reporting an exit status"
            )
        }

        guard exit.uncaughtSignal == nil, allowedExitCodes.contains(exit.terminationStatus) else {
            throw ProcessError.exitedWithFailure(
                command: command.redactedDescription,
                exit: exit,
                standardError: standardError
            )
        }

        return ProcessResult(
            exit: exit,
            standardOutput: captured[.standardOutput] ?? "",
            standardError: standardError,
            outputWasTruncated: wasTruncated
        )
    }

    private static func pump(
        session: ProcessSession,
        stream: ProcessStream,
        redactor: SecretRedactor,
        maximumLineLength: Int,
        continuation: AsyncThrowingStream<ProcessEvent, any Error>.Continuation
    ) {
        let handle = session.handle(for: stream)
        var splitter = LineSplitter(maximumLineLength: maximumLineLength)

        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            for line in splitter.append(chunk) {
                continuation.yield(.line(stream, redactor.redact(line)))
            }
        }

        if let trailing = splitter.flush() {
            continuation.yield(.line(stream, redactor.redact(trailing)))
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
