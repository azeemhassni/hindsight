import Foundation

/// Turns arbitrary read chunks into whole lines.
///
/// Used from a single thread per stream, so it stays a value type.
struct LineSplitter {
    private var buffer = Data()
    private let maximumLineLength: Int

    init(maximumLineLength: Int) {
        self.maximumLineLength = maximumLineLength
    }

    mutating func append(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(Self.text(buffer[buffer.startIndex..<newline]))
            buffer = buffer[buffer.index(after: newline)...]
        }
        // A process that never emits a newline must not be able to grow this
        // buffer without bound.
        if buffer.count > maximumLineLength {
            lines.append(Self.text(buffer))
            buffer = Data()
        }
        return lines
    }

    mutating func flush() -> String? {
        guard !buffer.isEmpty else { return nil }
        defer { buffer = Data() }
        return Self.text(buffer)
    }

    /// Lossy on purpose: filenames on Linux are bytes, not UTF-8, and dropping a
    /// line because it names an oddly encoded file would lose real information.
    private static func text(_ data: some DataProtocol) -> String {
        var line = String(decoding: Data(data), as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        return line
    }
}
