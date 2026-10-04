import Foundation

/// The one place where Foundation's non-`Sendable` process API is confined.
///
/// Reads are event-driven rather than blocking. An earlier version parked a
/// thread per stream per process, which deadlocks once enough processes run at
/// once: the blocked threads exhaust the pool, so the reads that would release
/// them never get scheduled. A background agent runs many processes, so the
/// reads must not own threads at all.
final class ProcessSession: @unchecked Sendable {
    private let process = Process()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let inputPipe = Pipe()
    private let inputData: Data?
    private let maximumLineLength: Int

    /// Serialises every piece of mutable state below. Read sources and the
    /// termination handler all fire on `queue`, so the state is only touched
    /// from one place; the lock covers the launch path and `terminate`.
    private let lock = NSLock()
    private let queue: DispatchQueue

    private var sources: [any DispatchSourceRead] = []
    private var splitters: [ProcessStream: LineSplitter] = [:]
    private var openStreams = 0
    private var exitStatus: ProcessExit?
    private var reportedExit = false
    private var onLine: (@Sendable (ProcessStream, String) -> Void)?
    private var onExit: (@Sendable (ProcessExit) -> Void)?
    private var standardInputClosed = false

    init(command: Command, maximumLineLength: Int) {
        self.maximumLineLength = maximumLineLength
        queue = DispatchQueue(label: "dev.hindsight.process")

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

    func start(
        onLine: @escaping @Sendable (ProcessStream, String) -> Void,
        onExit: @escaping @Sendable (ProcessExit) -> Void
    ) throws -> Int32 {
        lock.lock()
        self.onLine = onLine
        self.onExit = onExit
        for stream in ProcessStream.allCases {
            splitters[stream] = LineSplitter(maximumLineLength: maximumLineLength)
        }
        openStreams = ProcessStream.allCases.count
        lock.unlock()

        let start = ContinuousClock.now
        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            let signal = finished.terminationReason == .uncaughtSignal
                ? finished.terminationStatus
                : nil
            let status = ProcessExit(
                terminationStatus: finished.terminationStatus,
                uncaughtSignal: signal,
                duration: ContinuousClock.now - start
            )
            self.queue.async { self.recordExit(status) }
        }

        try process.run()

        for stream in ProcessStream.allCases {
            startReading(stream)
        }
        writeStandardInput()

        return process.processIdentifier
    }

    private func handle(for stream: ProcessStream) -> FileHandle {
        switch stream {
        case .standardOutput: outputPipe.fileHandleForReading
        case .standardError: errorPipe.fileHandleForReading
        }
    }

    private func startReading(_ stream: ProcessStream) {
        let descriptor = handle(for: stream).fileDescriptor
        // Non-blocking so the handler can drain whatever is ready and return,
        // instead of parking the queue's thread.
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drain(stream, descriptor: descriptor)
        }
        source.setCancelHandler { [weak self] in
            self?.finishStream(stream)
        }
        lock.lock()
        sources.append(source)
        lock.unlock()
        source.resume()
    }

    private func drain(_ stream: ProcessStream, descriptor: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                let chunk = Data(buffer[0..<count])
                for line in splitters[stream]?.append(chunk) ?? [] {
                    onLine?(stream, line)
                }
                continue
            }
            if count == 0 {
                cancelSource(for: stream, descriptor: descriptor)
                return
            }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            if errno == EINTR { continue }
            cancelSource(for: stream, descriptor: descriptor)
            return
        }
    }

    private func cancelSource(for stream: ProcessStream, descriptor: Int32) {
        lock.lock()
        let matching = sources.filter { $0.handle == descriptor }
        lock.unlock()
        if matching.isEmpty {
            finishStream(stream)
        } else {
            matching.forEach { $0.cancel() }
        }
    }

    private func finishStream(_ stream: ProcessStream) {
        queue.async {
            if let trailing = self.splitters[stream]?.flush() {
                self.onLine?(stream, trailing)
            }
            self.splitters[stream] = nil
            self.openStreams -= 1
            self.reportExitIfReady()
        }
    }

    private func recordExit(_ status: ProcessExit) {
        exitStatus = status
        reportExitIfReady()
    }

    /// The exit event is held back until both streams are at end of file, so a
    /// consumer never sees `.exited` before the output that preceded it.
    private func reportExitIfReady() {
        guard !reportedExit, openStreams == 0, let exitStatus else { return }
        reportedExit = true
        onExit?(exitStatus)
        onLine = nil
        onExit = nil
    }

    private func writeStandardInput() {
        guard let inputData else { return }
        let descriptor = inputPipe.fileHandleForWriting.fileDescriptor
        // Written asynchronously because a payload larger than the pipe buffer
        // would otherwise deadlock against a child waiting for us to read.
        DispatchIO.write(
            toFileDescriptor: descriptor,
            data: inputData.withUnsafeBytes { DispatchData(bytes: $0) },
            runningHandlerOn: queue
        ) { [weak self] _, _ in
            // A child that exits before reading its input gives EPIPE; that is
            // the child's story to tell through its exit status.
            self?.closeStandardInput()
        }
    }

    /// Closed through the `FileHandle` rather than `close(2)`.
    ///
    /// Closing the raw descriptor leaves the handle believing it still owns it,
    /// so deallocation closes it a second time — by which point the number has
    /// often been reused by another thread, which then loses its descriptor.
    private func closeStandardInput() {
        lock.lock()
        defer { lock.unlock() }
        guard !standardInputClosed else { return }
        standardInputClosed = true
        try? inputPipe.fileHandleForWriting.close()
    }

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        guard process.isRunning else { return }
        process.terminate()
    }

    func kill() {
        lock.lock()
        defer { lock.unlock() }
        guard process.isRunning else { return }
        Foundation.kill(process.processIdentifier, SIGKILL)
    }
}
