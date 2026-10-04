public enum ProcessStream: String, Hashable, Sendable, CaseIterable {
    case standardOutput
    case standardError
}

public struct ProcessExit: Hashable, Sendable {
    public let terminationStatus: Int32
    public let uncaughtSignal: Int32?
    public let duration: Duration

    public init(terminationStatus: Int32, uncaughtSignal: Int32?, duration: Duration) {
        self.terminationStatus = terminationStatus
        self.uncaughtSignal = uncaughtSignal
        self.duration = duration
    }

    public var isSuccess: Bool { terminationStatus == 0 && uncaughtSignal == nil }
}

public enum ProcessEvent: Sendable {
    case started(pid: Int32)
    /// One complete line, already redacted.
    ///
    /// Events are lines rather than byte chunks so that redaction is sound: a
    /// secret split across two reads would survive chunk-wise redaction.
    case line(ProcessStream, String)
    case exited(ProcessExit)
}

public struct ProcessResult: Sendable {
    public let exit: ProcessExit
    public let standardOutput: String
    public let standardError: String
    public let outputWasTruncated: Bool

    public init(
        exit: ProcessExit,
        standardOutput: String,
        standardError: String,
        outputWasTruncated: Bool
    ) {
        self.exit = exit
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.outputWasTruncated = outputWasTruncated
    }

    public var standardOutputLines: [String] {
        standardOutput.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}
