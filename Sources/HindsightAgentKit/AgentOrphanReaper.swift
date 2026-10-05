import Foundation
import HindsightProcess

/// Clears up after an agent that was killed rather than asked to stop.
///
/// rest-server runs as a child process. A SIGKILL — a crash, a launchd
/// restart, a `pkill` — leaves it alive and reparented to launchd, still
/// serving a repository over a loopback port, and still holding the htpasswd
/// file it was started with. The agent is the only thing that ever starts one,
/// so at startup any that exist belong to a run that is already over.
enum OrphanedServers {
    @discardableResult
    static func reap(
        binaryDirectory: URL,
        repositoryPaths: [String],
        runner: ProcessRunner = ProcessRunner(),
        fileManager: FileManager = .default
    ) async -> Int {
        await terminate(binaryDirectory: binaryDirectory, runner: runner)
        return removeCredentialFiles(near: repositoryPaths, fileManager: fileManager)
    }

    private static func terminate(binaryDirectory: URL, runner: ProcessRunner) async {
        // pkill rather than a process listing: matching our own binary
        // directory cannot hit another program, and nothing else on the Mac
        // runs this copy of rest-server.
        _ = try? await runner.run(
            Command(
                path: "/usr/bin/pkill",
                arguments: ["-f", binaryDirectory.appendingPathComponent("rest-server-").path]
            ),
            // 1 means nothing matched, which is the usual case.
            allowedExitCodes: [0, 1],
            timeout: .seconds(10)
        )
    }

    /// The htpasswd files hold a bcrypt hash of a repository's access
    /// password, so a leftover is a credential sitting on disk for no reason.
    private static func removeCredentialFiles(
        near repositoryPaths: [String],
        fileManager: FileManager
    ) -> Int {
        var removed = 0
        let roots = Set(repositoryPaths.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })
        for root in roots {
            guard let names = try? fileManager.contentsOfDirectory(atPath: root) else { continue }
            for name in names where name.hasPrefix(".hindsight-htpasswd-") {
                let file = URL(fileURLWithPath: root).appendingPathComponent(name)
                if (try? fileManager.removeItem(at: file)) != nil { removed += 1 }
            }
        }
        return removed
    }
}
