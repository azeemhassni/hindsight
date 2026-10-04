import Foundation
import HindsightRestic

/// Puts the pinned restic binary on a server and keeps it honest.
///
/// The digest is checked before every run, not only after an upload: a cached
/// binary that has been replaced must fail closed rather than execute.
public struct RemoteBinaryInstaller: Sendable {
    public let client: SSHClient
    public let store: BinaryStore

    public init(client: SSHClient, store: BinaryStore) {
        self.client = client
        self.store = store
    }

    public func remotePath(for binary: PinnedBinary, facts: RemoteFacts) -> String {
        "\(facts.homeDirectory)/\(binary.remoteCachePath)"
    }

    @discardableResult
    public func ensureInstalled(
        _ binary: PinnedBinary,
        on destination: SSHDestination,
        facts: RemoteFacts
    ) async throws -> String {
        let path = remotePath(for: binary, facts: facts)

        if let existing = try await client.remoteDigest(of: path, on: destination),
           existing == binary.binarySHA256 {
            return path
        }

        let local = try store.verifiedURL(for: binary)
        let contents = try Data(contentsOf: local)
        try await client.upload(contents, to: path, mode: "700", on: destination)

        guard let uploaded = try await client.remoteDigest(of: path, on: destination) else {
            throw SSHError.remoteFileVerificationFailed(
                path: path,
                expected: binary.binarySHA256,
                actual: "(missing after upload)"
            )
        }
        guard uploaded == binary.binarySHA256 else {
            throw SSHError.remoteFileVerificationFailed(
                path: path,
                expected: binary.binarySHA256,
                actual: uploaded
            )
        }
        return path
    }

    /// Verifies an already-installed binary, for the preflight of every run.
    public func verifyInstalled(
        _ binary: PinnedBinary,
        on destination: SSHDestination,
        facts: RemoteFacts
    ) async throws -> String {
        let path = remotePath(for: binary, facts: facts)
        let digest = try await client.remoteDigest(of: path, on: destination)
        guard let digest else {
            throw SSHError.remoteFileVerificationFailed(
                path: path,
                expected: binary.binarySHA256,
                actual: "(not present)"
            )
        }
        guard digest == binary.binarySHA256 else {
            throw SSHError.remoteFileVerificationFailed(
                path: path,
                expected: binary.binarySHA256,
                actual: digest
            )
        }
        return path
    }
}
