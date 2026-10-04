import Foundation

/// A single-shot TCP listener on 127.0.0.1, used to prove a reverse forward
/// actually carries traffic.
public final class LocalTestListener: @unchecked Sendable {
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "dev.hindsight.test.listener")
    public let port: Int

    public init(responding response: String) throws {
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw ListenerError.couldNotCreateSocket }

        var reuse: Int32 = 1
        setsockopt(fileDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fileDescriptor, 4) == 0 else {
            close(fileDescriptor)
            throw ListenerError.couldNotBind
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fileDescriptor, $0, &length)
            }
        }
        guard named == 0 else {
            close(fileDescriptor)
            throw ListenerError.couldNotBind
        }
        descriptor = fileDescriptor
        port = Int(UInt16(bigEndian: assigned.sin_port))

        let socketDescriptor = fileDescriptor
        let payload = Data((response + "\n").utf8)
        queue.async {
            while true {
                let client = accept(socketDescriptor, nil, nil)
                if client < 0 { return }
                var buffer = [UInt8](repeating: 0, count: 256)
                _ = read(client, &buffer, buffer.count)
                payload.withUnsafeBytes { bytes in
                    _ = write(client, bytes.baseAddress, bytes.count)
                }
                close(client)
            }
        }
    }

    public func stop() {
        close(descriptor)
    }

    public enum ListenerError: Error {
        case couldNotCreateSocket
        case couldNotBind
    }
}
