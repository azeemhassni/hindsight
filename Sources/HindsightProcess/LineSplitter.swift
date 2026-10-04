import Foundation

/// Turns arbitrary read chunks into whole lines.
///
/// Breaks on carriage return as well as newline. restic's progress output goes
/// through a pseudo-terminal, where it separates status objects with `\r` to
/// rewrite the line in place; splitting only on `\n` would glue a run of JSON
/// objects into one unparseable blob and lose every progress update.
///
/// Used from a single thread per stream, so it stays a value type.
struct LineSplitter {
    private var buffer = Data()
    private var lastByteWasCarriageReturn = false
    private let maximumLineLength: Int

    private static let newline = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")

    init(maximumLineLength: Int) {
        self.maximumLineLength = maximumLineLength
    }

    mutating func append(_ chunk: Data) -> [String] {
        var lines: [String] = []

        for byte in chunk {
            // A `\n` that completes a `\r\n` pair is one break, not two.
            if byte == Self.newline, lastByteWasCarriageReturn {
                lastByteWasCarriageReturn = false
                continue
            }
            lastByteWasCarriageReturn = byte == Self.carriageReturn

            if byte == Self.newline || byte == Self.carriageReturn {
                lines.append(Self.text(buffer))
                buffer.removeAll(keepingCapacity: true)
                continue
            }

            buffer.append(byte)
            // A process that never emits a line break must not be able to grow
            // this buffer without bound.
            if buffer.count >= maximumLineLength {
                lines.append(Self.text(buffer))
                buffer.removeAll(keepingCapacity: true)
            }
        }

        return lines
    }

    mutating func flush() -> String? {
        guard !buffer.isEmpty else { return nil }
        defer { buffer.removeAll(keepingCapacity: false) }
        return Self.text(buffer)
    }

    /// Lossy on purpose: filenames on Linux are bytes, not UTF-8, and dropping a
    /// line because it names an oddly encoded file would lose real information.
    private static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }
}
