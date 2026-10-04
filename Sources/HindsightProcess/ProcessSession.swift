import Foundation

/// The one place where Foundation's non-`Sendable` process API is confined.
///
/// `Process` and `FileHandle` are not `Sendable`, and the reads here must block
/// on dedicated Dispatch threads rather than the cooperative pool, which has a
/// bounded thread count. Every stored property is established before `launch()`
/// and never reassigned; after launch, each handle is read from exactly one
/// thread, and `terminate()`/`waitForExit()` are the only cross-thread calls —
/// both of which Foundation supports concurrently with a read.
final class ProcessSession: @unchecked Sendable {
    private let process = Process()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let inputPipe = Pipe()
    private let inputData: Data?

    init(command: Command) {
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.environment = command.environment.resolved()
        process.currentDirectoryURL = command.workingDirectory
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        switch command.standardInput {
        case .none:
            inputData = nil
            process.standardInput = FileHandle.nullDevice
        case let .data(data):
            inputData = data
            process.standardInput = inputPipe
        }
    }

    func launch() throws -> Int32 {
        try process.run()
        return process.processIdentifier
    }

    func handle(for stream: ProcessStream) -> FileHandle {
        switch stream {
        case .standardOutput: outputPipe.fileHandleForReading
        case .standardError: errorPipe.fileHandleForReading
        }
    }

    /// Writes and closes stdin. Runs on its own thread because a payload larger
    /// than the pipe buffer would otherwise deadlock against a child that is
    /// waiting for us to read its output.
    func writeStandardInput() {
        guard let inputData else { return }
        let handle = inputPipe.fileHandleForWriting
        defer { try? handle.close() }
        do {
            try handle.write(contentsOf: inputData)
        } catch {
            // A child that exits before consuming its input gives EPIPE. That is
            // the child's story to tell through its exit status, not an error here.
        }
    }

    func waitForExit(startedAt start: ContinuousClock.Instant) -> ProcessExit {
        process.waitUntilExit()
        let signal = process.terminationReason == .uncaughtSignal ? process.terminationStatus : nil
        return ProcessExit(
            terminationStatus: process.terminationStatus,
            uncaughtSignal: signal,
            duration: ContinuousClock.now - start
        )
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    func kill() {
        guard process.isRunning else { return }
        Foundation.kill(process.processIdentifier, SIGKILL)
    }
}
