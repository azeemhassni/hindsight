import Foundation
import HindsightCore
import HindsightKeychain
import HindsightRestic
import HindsightUI

/// Reads a repository on the Mac, off the main thread.
///
/// Everything here is slow or blocking by nature: a Keychain read can put a
/// system dialog on screen, verifying the bundled restic hashes twenty
/// megabytes, and listing a directory runs a process. Doing any of it on the
/// main actor freezes the window — which is exactly what happened before this
/// type existed, and looked like the window vanishing.
struct RepositoryAccess: Sendable {
    let serverID: ServerID
    let repositoryPath: String

    enum Failure: Error, CustomStringConvertible {
        case noResticBinary(String)
        case noPassword(String)

        var description: String {
            switch self {
            case let .noResticBinary(reason):
                "The bundled copy of restic could not be used: \(reason)"
            case let .noPassword(reason):
                """
                The repository password could not be read from the Keychain \
                (\(reason)). Hindsight and its agent have to be signed with the \
                same team for that to work.
                """
            }
        }
    }

    /// Built on a background thread, so the Keychain read never blocks the UI.
    private func client() async throws -> ResticClient {
        try await Task.detached(priority: .userInitiated) { [serverID, repositoryPath] in
            let executable: URL
            do {
                executable = try BinaryStore.bundled()
                    .verifiedURL(for: try PinnedBinaries.hostRestic)
            } catch {
                throw Failure.noResticBinary("\(error)")
            }

            let password: Secret
            do {
                password = try Keychain().read(.repositoryPassword(serverID))
            } catch {
                throw Failure.noPassword("\(error)")
            }

            return ResticClient(
                executable: executable,
                location: .local(URL(fileURLWithPath: repositoryPath)),
                password: password
            )
        }.value
    }

    /// Lists one directory of a snapshot.
    func children(
        ofSnapshot snapshot: SnapshotID,
        path: String
    ) async throws -> [SnapshotTreeNode] {
        let client = try await client()
        let nodes = try await client.children(ofSnapshot: snapshot, path: path)
        return nodes.map { node in
            SnapshotTreeNode(
                path: node.path,
                name: node.name,
                isDirectory: node.isDirectory,
                sizeBytes: node.size,
                modifiedAt: node.mtime,
                permissions: node.permissions,
                // Left unloaded so the browser asks for a directory only when
                // somebody opens it.
                children: node.isDirectory ? nil : []
            )
        }
    }

    /// Extracts one file to a temporary directory, for Quick Look.
    func extract(snapshot: SnapshotID, path: String) async throws -> URL {
        let client = try await client()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Hindsight-preview/\(UUID().uuidString)")
        return try await client.extractFile(
            snapshot: snapshot,
            path: path,
            toDirectory: directory
        )
    }

    /// How much disk the repository is using.
    static func sizeInBytes(ofRepositoryAt path: String) async -> Int64? {
        await Task.detached(priority: .utility) {
            DirectorySize.bytes(at: URL(fileURLWithPath: path))
        }.value
    }
}
