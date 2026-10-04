import Foundation
import HindsightCoolify
import HindsightCore
import HindsightProcess
import HindsightRestic
import HindsightSSH

extension BackupEngine {
    /// Backs up one Coolify resource: its configuration directory, its volumes
    /// and, for a database, a logical dump beside them.
    ///
    /// It repeats the preparation a whole-server backup does — the repository
    /// lock, the local rest-server, the reverse tunnel — because the two differ
    /// in what they ask restic to read, not in how they reach the repository.
    public func backUp(
        resource: CoolifyResource,
        plan: BackupPlan,
        emit: @Sendable @escaping (BackupEvent) -> Void = { _ in }
    ) async throws -> CoolifyResourceOutcome {
        emit(.phase(.connecting))
        let facts = try await client.probeFacts(on: plan.destination)

        emit(.phase(.verifyingBinary))
        let binary = try PinnedBinaries.restic(for: facts.platform.architecture)
        let installer = RemoteBinaryInstaller(client: client, store: binaryStore)
        let remoteRestic = try await installer.ensureInstalled(binary, on: plan.destination, facts: facts)

        return try await locks.withLock(repositoryPath: plan.repositoryURL.path) {
            let local = ResticClient(
                executable: try binaryStore.verifiedURL(for: try PinnedBinaries.hostRestic),
                location: .local(plan.repositoryURL),
                password: plan.repositoryPassword,
                runner: runner
            )
            if try await local.initializeIfNeeded() {
                emit(.message("Created a new repository at \(plan.repositoryURL.path)."))
            }

            emit(.phase(.startingServer))
            let credential = RestServerCredential.generate(username: plan.server.id.value)
            let server = RestServer(
                configuration: RestServer.Configuration(
                    repositoryRoot: plan.repositoryRoot,
                    credential: credential,
                    htpasswdFile: plan.repositoryRoot
                        .appendingPathComponent(".hindsight-htpasswd-\(UUID().uuidString)"),
                    executable: try binaryStore.verifiedURL(for: try PinnedBinaries.hostRestServer)
                ),
                runner: runner
            )
            try? await local.unlock(removeAll: true)
            let localPort = try await server.start()

            emit(.phase(.openingTunnel))
            let outcome: CoolifyResourceOutcome
            do {
                outcome = try await client.withReverseForward(
                    toLocalPort: localPort,
                    on: plan.destination
                ) { remotePort in
                    let repositoryURL = await server.repositoryURL(
                        remotePort: remotePort,
                        serverID: plan.server.id
                    )
                    let repositorySecret = Secret(
                        label: "rest-repository/\(plan.server.id.value)",
                        value: repositoryURL
                    )
                    emit(.phase(.backingUp))
                    return await CoolifyResourceBackup(client: client).backUp(
                        resource,
                        remoteResticPath: remoteRestic,
                        repositorySecret: repositorySecret,
                        repositoryPassword: plan.repositoryPassword,
                        on: plan.destination,
                        facts: facts,
                        databaseCredentials: plan.databaseCredentials,
                        bandwidthLimitKiB: plan.profile.bandwidthLimitKiBPerSecond
                    )
                }
            } catch {
                await server.stop()
                throw error
            }
            await server.stop()

            emit(.phase(.recording))
            for path in outcome.capturedPaths {
                emit(.message("captured \(path)"))
            }
            for dump in outcome.dumps where !dump.succeeded {
                emit(.warning("Could not dump \(dump.target.displayName): \(dump.failure ?? "unknown reason")"))
            }
            if let failure = outcome.failure {
                emit(.warning(failure))
            }
            return outcome
        }
    }
}
