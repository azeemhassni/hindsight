import Foundation
import HindsightCore
import HindsightProcess
import HindsightTestSupport
import Testing
@testable import HindsightRestic

@Suite("Second copy", .timeLimit(.minutes(10)), .serialized)
struct SecondCopyTests {
    static var resticAvailable: Bool {
        (try? BinaryStore(directory: TestEnvironment.vendorBinDirectory())
            .verifiedURL(for: try PinnedBinaries.hostRestic)) != nil
    }

    @Test("builds the repository string each backend expects")
    func buildsRepositoryStrings() {
        #expect(SecondCopyTarget.localPath(URL(fileURLWithPath: "/Volumes/Spare/repo"))
            .resticRepository == "/Volumes/Spare/repo")
        #expect(SecondCopyTarget.s3(bucket: "backups", prefix: "web", endpoint: nil)
            .resticRepository == "s3:s3.amazonaws.com/backups/web")
        #expect(SecondCopyTarget.s3(bucket: "backups", prefix: nil, endpoint: "minio.local:9000")
            .resticRepository == "s3:minio.local:9000/backups")
        #expect(SecondCopyTarget.backblazeB2(bucket: "backups", prefix: "web")
            .resticRepository == "b2:backups:web")
        #expect(SecondCopyTarget.restServer(url: "http://nas.local:8000/web")
            .resticRepository == "rest:http://nas.local:8000/web")
        // An already-prefixed URL is not prefixed twice.
        #expect(SecondCopyTarget.restServer(url: "rest:http://nas.local:8000/web")
            .resticRepository == "rest:http://nas.local:8000/web")
    }

    @Test("knows which backends need credentials, and which variables")
    func describesCredentials() {
        #expect(!SecondCopyTarget.localPath(URL(fileURLWithPath: "/tmp")).needsCredentials)
        #expect(SecondCopyTarget.s3(bucket: "b", prefix: nil, endpoint: nil).needsCredentials)
        #expect(SecondCopyTarget.s3(bucket: "b", prefix: nil, endpoint: nil).credentialVariables
            == ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"])
        #expect(SecondCopyTarget.backblazeB2(bucket: "b", prefix: nil).credentialVariables
            == ["B2_ACCOUNT_ID", "B2_ACCOUNT_KEY"])
    }

    @Test("refuses to start without the credentials it needs")
    func refusesWithoutCredentials() throws {
        let copy = SecondCopy(executable: URL(fileURLWithPath: "/usr/bin/true"))
        #expect(throws: SecondCopyError.missingCredentials(
            variables: ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"]
        )) {
            _ = try copy.environment(
                source: URL(fileURLWithPath: "/tmp/source"),
                sourcePassword: Secret(label: "a", value: "a"),
                target: .s3(bucket: "b", prefix: nil, endpoint: nil),
                targetPassword: Secret(label: "b", value: "b"),
                credentials: [:]
            )
        }
    }

    @Test("keeps every credential out of the command line")
    func keepsCredentialsOutOfArgv() throws {
        let copy = SecondCopy(executable: URL(fileURLWithPath: "/usr/bin/true"))
        let environment = try copy.environment(
            source: URL(fileURLWithPath: "/tmp/source"),
            sourcePassword: Secret(label: "source", value: "source-password"),
            target: .s3(bucket: "b", prefix: nil, endpoint: nil),
            targetPassword: Secret(label: "target", value: "target-password"),
            credentials: [
                "AWS_ACCESS_KEY_ID": Secret(label: "id", value: "AKIAEXAMPLE"),
                "AWS_SECRET_ACCESS_KEY": Secret(label: "key", value: "supersecret"),
            ]
        )

        // Credentials belong in the environment, which `ps` cannot read.
        #expect(environment.secretValues.keys.sorted() == [
            "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY",
            "RESTIC_FROM_PASSWORD", "RESTIC_PASSWORD",
        ])
        let command = Command(
            path: "/usr/bin/true",
            arguments: ["copy", "--from-repo", "/tmp/source"],
            environment: environment
        )
        for secret in ["source-password", "target-password", "AKIAEXAMPLE", "supersecret"] {
            #expect(!command.redactedDescription.contains(secret))
        }
    }

    @Test("copies a repository so stock restic can restore from the copy", .enabled(if: resticAvailable))
    func copiesToASecondRepository() async throws {
        let executable = try BinaryStore(directory: TestEnvironment.vendorBinDirectory())
            .verifiedURL(for: try PinnedBinaries.hostRestic)
        let root = try TestEnvironment.temporaryRepositoryRoot()
        let source = root.appendingPathComponent("primary")
        let destination = root.appendingPathComponent("second")

        let sourcePassword = Secret(label: "source", value: "primary-password")
        // The copy gets its own password: losing the Mac should not hand over
        // the second copy along with the first.
        let targetPassword = Secret(label: "target", value: "second-password")

        let primary = ResticClient(executable: executable, location: .local(source), password: sourcePassword)
        _ = try await primary.initializeIfNeeded()

        let runner = ProcessRunner()
        for index in 0..<3 {
            try await runner.run(
                Command(
                    path: executable.path,
                    arguments: ["backup", "--stdin", "--stdin-filename", "payload.txt", "--tag", "hindsight"],
                    environment: Environment(
                        values: ["RESTIC_REPOSITORY": source.path],
                        secretValues: ["RESTIC_PASSWORD": sourcePassword]
                    ),
                    standardInput: .data(Data("snapshot-\(index)\n".utf8))
                )
            )
        }

        let copy = SecondCopy(executable: executable, locks: RepositoryLockManager())
        let created = try await copy.initialiseIfNeeded(
            source: source,
            sourcePassword: sourcePassword,
            target: .localPath(destination),
            targetPassword: targetPassword
        )
        #expect(created)

        let outcome = try await copy.copy(
            source: source,
            sourcePassword: sourcePassword,
            target: .localPath(destination),
            targetPassword: targetPassword
        )
        #expect(outcome.destination == destination.path)

        // The copy must stand on its own: every snapshot present, readable
        // with its own password, and structurally sound.
        let secondary = ResticClient(
            executable: executable,
            location: .local(destination),
            password: targetPassword
        )
        let copied = try await secondary.snapshots()
        #expect(copied.count == 3)
        #expect(try await secondary.check().isHealthy)

        // And the source password must not open the copy.
        let wrongPassword = ResticClient(
            executable: executable,
            location: .local(destination),
            password: sourcePassword
        )
        #expect(try await !wrongPassword.repositoryExists())
    }

    @Test("a second copy of the same snapshots adds almost nothing", .enabled(if: resticAvailable))
    func secondCopyIsIncremental() async throws {
        let executable = try BinaryStore(directory: TestEnvironment.vendorBinDirectory())
            .verifiedURL(for: try PinnedBinaries.hostRestic)
        let root = try TestEnvironment.temporaryRepositoryRoot()
        let source = root.appendingPathComponent("primary")
        let destination = root.appendingPathComponent("second")
        let sourcePassword = Secret(label: "source", value: "primary-password")
        let targetPassword = Secret(label: "target", value: "second-password")

        let primary = ResticClient(executable: executable, location: .local(source), password: sourcePassword)
        _ = try await primary.initializeIfNeeded()

        var payload = Data(count: 4_000_000)
        payload.withUnsafeMutableBytes { buffer in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for offset in 0..<buffer.count { base[offset] = UInt8(truncatingIfNeeded: offset * 31) }
        }
        try await ProcessRunner().run(
            Command(
                path: executable.path,
                arguments: ["backup", "--stdin", "--stdin-filename", "payload.bin"],
                environment: Environment(
                    values: ["RESTIC_REPOSITORY": source.path],
                    secretValues: ["RESTIC_PASSWORD": sourcePassword]
                ),
                standardInput: .data(payload)
            )
        )

        let copy = SecondCopy(executable: executable, locks: RepositoryLockManager())
        try await copy.initialiseIfNeeded(
            source: source,
            sourcePassword: sourcePassword,
            target: .localPath(destination),
            targetPassword: targetPassword
        )
        try await copy.copy(
            source: source,
            sourcePassword: sourcePassword,
            target: .localPath(destination),
            targetPassword: targetPassword
        )

        let secondary = ResticClient(
            executable: executable,
            location: .local(destination),
            password: targetPassword
        )
        let sizeAfterFirst = try await secondary.stats().totalSize

        // Copying again must be a no-op, not a second set of packs. This is
        // what --copy-chunker-params buys at init time.
        try await copy.copy(
            source: source,
            sourcePassword: sourcePassword,
            target: .localPath(destination),
            targetPassword: targetPassword
        )
        #expect(try await secondary.stats().totalSize == sizeAfterFirst)
        #expect(try await secondary.snapshots().count == 1)
    }
}
