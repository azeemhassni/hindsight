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
            let session = ProcessSession(command: command, maximumLineLength: maximumLineLength)

            let pid: Int32
            do {
                pid = try session.start(
                    onLine: { stream, line in
                        continuation.yield(.line(stream, redactor.redact(line)))
                    },
                    onExit: { status in
                        continuation.yield(.exited(status))
                        continuation.finish()
                    }
                )
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

            continuation.onTermination = { reason in
                guard case .cancelled = reason else { return }
                session.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + grace.timeInterval) {
                    session.kill()
                }
            }
        }
    }

    /// Runs to completion and collects output.
    ///
    /// `allowedExitCodes` exists because several commands Hindsight runs report
    /// a legitimate answer through a non-zero status, `test -f` among them.
    ///
    /// `timeout` matters more than it looks: a wedged ssh control socket, or a
    /// remote command that never returns, would otherwise hang a scheduled job
    /// forever with nothing in the log to explain it.
    @discardableResult
    public func run(
        _ command: Command,
        allowedExitCodes: Set<Int32> = [0],
        maximumCapturedBytes: Int = ProcessRunner.defaultMaximumCapturedBytes,
        timeout: Duration? = nil
    ) async throws -> ProcessResult {
        guard let timeout else {
            return try await collect(
                command,
                allowedExitCodes: allowedExitCodes,
                maximumCapturedBytes: maximumCapturedBytes
            )
        }

        do {
            return try await withThrowingTaskGroup(of: ProcessResult.self) { group in
                group.addTask {
                    try await self.collect(
                        command,
                        allowedExitCodes: allowedExitCodes,
                        maximumCapturedBytes: maximumCapturedBytes
                    )
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw ProcessError.timedOut(command: command.redactedDescription, after: timeout)
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch let error as ProcessError {
            throw error
        }
    }

    @discardableResult
    private func collect(
        _ command: Command,
        allowedExitCodes: Set<Int32>,
        maximumCapturedBytes: Int
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

}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
