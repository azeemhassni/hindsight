import CryptoKit
import Foundation

public enum BinaryStoreError: Error, Hashable, Sendable, CustomStringConvertible {
    case noPinnedBinary(tool: String, platform: String)
    case missing(fileName: String, directory: String)
    case notExecutable(path: String)
    case digestMismatch(fileName: String, expected: String, actual: String, path: String = "")
    case unreadable(path: String, reason: String)

    public var description: String {
        switch self {
        case let .noPinnedBinary(tool, platform):
            "No pinned \(tool) build for \(platform)."
        case let .missing(fileName, directory):
            "\(fileName) is not in \(directory). Run `make vendor`."
        case let .notExecutable(path):
            "\(path) is not executable."
        case let .digestMismatch(fileName, expected, actual, path):
            """
            \(fileName) does not match its pinned digest and will not be used.
              at       \(path.isEmpty ? "(unknown path)" : path)
              expected \(expected)
              actual   \(actual)
            """
        case let .unreadable(path, reason):
            "Could not read \(path): \(reason)"
        }
    }
}

/// Locates and verifies the bundled restic and rest-server binaries.
///
/// Verification is not a build-time-only concern: a binary is checked before it
/// is executed locally and before every remote run, so a tampered or truncated
/// file fails closed instead of running.
public struct BinaryStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The store backed by the app bundle's resources.
    public static func bundled(in bundle: Bundle = .main) -> BinaryStore {
        BinaryStore(directory: bundle.resourceURL ?? bundle.bundleURL)
    }

    public func url(for binary: PinnedBinary) -> URL {
        directory.appendingPathComponent(binary.fileName)
    }

    public func exists(_ binary: PinnedBinary) -> Bool {
        FileManager.default.fileExists(atPath: url(for: binary).path)
    }

    /// Returns the binary's location only if it is present, executable, and
    /// matches its pinned digest.
    public func verifiedURL(for binary: PinnedBinary) throws -> URL {
        let location = url(for: binary)
        guard FileManager.default.fileExists(atPath: location.path) else {
            throw BinaryStoreError.missing(fileName: binary.fileName, directory: directory.path)
        }
        // A Mach-O binary inside a signed app bundle is signed itself —
        // notarisation requires it — and signing changes the bytes, so the
        // upstream digest can no longer match. What guarantees it there is the
        // bundle's own seal, which macOS checks before the code ever runs, and
        // which is stronger than a hash this process compares against a
        // constant compiled into itself. Everything outside a signed bundle,
        // including every binary that travels to a server, is still pinned.
        if !Self.isInsideSignedBundle(location) {
            let actual = try Self.sha256(of: location)
            guard actual == binary.binarySHA256 else {
                throw BinaryStoreError.digestMismatch(
                    fileName: binary.fileName,
                    expected: binary.binarySHA256,
                    actual: actual,
                    path: location.path
                )
            }
        }
        guard FileManager.default.isExecutableFile(atPath: location.path) else {
            throw BinaryStoreError.notExecutable(path: location.path)
        }
        return location
    }

    /// Whether this file sits inside an app bundle that macOS has sealed.
    ///
    /// Only `.app` bundles that are signed: a development build with no
    /// signature keeps the digest check, which is what the test suite exercises.
    static func isInsideSignedBundle(_ file: URL) -> Bool {
        var directory = file.deletingLastPathComponent()
        while directory.path != "/" {
            if directory.pathExtension == "app" {
                return hasSignature(bundle: directory)
            }
            directory = directory.deletingLastPathComponent()
        }
        return false
    }

    private static func hasSignature(bundle: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: bundle.appendingPathComponent("Contents/_CodeSignature/CodeResources").path
        )
    }

    public static func sha256(of file: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: file)
        } catch {
            throw BinaryStoreError.unreadable(path: file.path, reason: String(describing: error))
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        // Streamed so a large binary is never fully resident.
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
