import Foundation
import HindsightCore
import HindsightProcess
import HindsightRestic
import HindsightSchedule
import HindsightTestSupport
import Testing
@testable import HindsightEngine

@Suite("Integrity", .timeLimit(.minutes(10)), .serialized)
struct IntegrityTests {
    static var resticAvailable: Bool {
        (try? BinaryStore(directory: TestEnvironment.vendorBinDirectory())
            .verifiedURL(for: try PinnedBinaries.hostRestic)) != nil
    }

    /// A repository with enough packs that a read-data subset is a real subset.
    static func makeRepository(packCount: Int = 24) async throws -> (ResticClient, URL) {
        let root = try TestEnvironment.temporaryRepositoryRoot()
        let repository = root.appendingPathComponent("integrity")
        let password = Secret(label: "repo", value: "integrity-test")
        let executable = try BinaryStore(directory: TestEnvironment.vendorBinDirectory())
            .verifiedURL(for: try PinnedBinaries.hostRestic)

        let client = ResticClient(
            executable: executable,
            location: .local(repository),
            password: password
        )
        _ = try await client.initializeIfNeeded()

        let runner = ProcessRunner()
        for index in 0..<packCount {
            // Incompressible and distinct, so each backup produces new packs.
            var payload = Data(count: 1_200_000)
            payload.withUnsafeMutableBytes { buffer in
                guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
                for offset in 0..<buffer.count {
                    base[offset] = UInt8truncating(index &* 7 &+ offset &* 31)
                }
            }
            try await runner.run(
                Command(
                    path: executable.path,
                    // One filename for all of them: restic groups snapshots by
                    // host and paths, and a policy applies per group.
                    arguments: ["backup", "--stdin", "--stdin-filename", "blob.bin"],
                    environment: Environment(
                        values: ["RESTIC_REPOSITORY": repository.path],
                        secretValues: ["RESTIC_PASSWORD": password]
                    ),
                    standardInput: .data(payload)
                )
            )
        }
        return (client, repository)
    }

    /// restic stores packs read-only, so bit rot has to be simulated by
    /// temporarily making the file writable — which is exactly what a failing
    /// disk would not need to do.
    static func corrupt(_ pack: URL, at offset: UInt64, with byte: UInt8, count: Int) throws {
        let original = try FileManager.default.attributesOfItem(atPath: pack.path)[.posixPermissions]
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pack.path)
        let handle = try FileHandle(forUpdating: pack)
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: Data(repeating: byte, count: count))
        try handle.close()
        if let original {
            try FileManager.default.setAttributes([.posixPermissions: original], ofItemAtPath: pack.path)
        }
    }

    static func packFiles(in repository: URL) throws -> [URL] {
        let dataDirectory = repository.appendingPathComponent("data")
        var packs: [URL] = []
        for prefix in try FileManager.default.contentsOfDirectory(atPath: dataDirectory.path).sorted() {
            let directory = dataDirectory.appendingPathComponent(prefix)
            for file in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() {
                packs.append(directory.appendingPathComponent(file))
            }
        }
        return packs
    }

    @Test("a healthy repository passes both a structural and a full data check", .enabled(if: resticAvailable))
    func healthyRepositoryPasses() async throws {
        let (client, path) = try await Self.makeRepository(packCount: 6)
        let engine = MaintenanceEngine(locks: RepositoryLockManager())

        let structural = try await engine.runIntegrityCheck(
            on: client,
            repositoryPath: path.path,
            rotation: IntegrityRotation(),
            readData: false
        )
        #expect(structural.isHealthy)
        #expect(structural.kind == .structure)

        let full = try await client.check(readDataSubset: "1/1")
        #expect(full.isHealthy)
    }

    @Test("a corrupted pack is caught by reading the data", .enabled(if: resticAvailable))
    func corruptionIsDetected() async throws {
        let (client, path) = try await Self.makeRepository(packCount: 8)

        #expect(try await client.check().isHealthy)

        // Flip bytes in the middle of one pack: the file keeps its name, its
        // size, and its place in the index, so only reading it reveals the rot.
        let packs = try Self.packFiles(in: path)
        try Self.corrupt(packs[0], at: 64, with: 0xFF, count: 512)

        let readAll = try await client.check(readDataSubset: "1/1")
        #expect(!readAll.isHealthy, "reading every pack must notice a damaged one")
        #expect(readAll.numErrors > 0 || !(readAll.brokenPacks?.isEmpty ?? true))
    }

    @Test("the rotation reaches every pack, so rot anywhere is found", .enabled(if: resticAvailable))
    func rotationCoversTheWholeRepository() async throws {
        let (client, path) = try await Self.makeRepository(packCount: 12)
        let packs = try Self.packFiles(in: path)
        #expect(packs.count >= 4, "need several packs for a subset to mean anything")

        // Damage a pack in the middle of the set, so no single subset is
        // guaranteed to be the one that finds it.
        try Self.corrupt(packs[packs.count / 2], at: 96, with: 0xAB, count: 256)

        var rotation = IntegrityRotation(divisor: 4)
        var detections = 0
        var subsets: [String] = []
        for _ in 0..<rotation.divisor {
            subsets.append(rotation.subsetArgument)
            let summary = try await client.check(readDataSubset: rotation.subsetArgument)
            if !summary.isHealthy { detections += 1 }
            rotation = rotation.advanced()
        }

        #expect(subsets == ["1/4", "2/4", "3/4", "4/4"])
        #expect(detections >= 1, "a full rotation must find a damaged pack")
        // And the rotation returns to where it started, so it keeps cycling.
        #expect(rotation.index == 0)
    }

    @Test("the rotation advances and wraps")
    func rotationAdvances() {
        var rotation = IntegrityRotation(divisor: 3)
        #expect(rotation.subsetArgument == "1/3")
        #expect(rotation.describeProgress() == "part 1 of 3")
        #expect(!rotation.completesFullPassAfterThisRun)

        rotation = rotation.advanced()
        #expect(rotation.subsetArgument == "2/3")
        rotation = rotation.advanced()
        #expect(rotation.subsetArgument == "3/3")
        #expect(rotation.completesFullPassAfterThisRun)
        rotation = rotation.advanced()
        #expect(rotation.subsetArgument == "1/3")
        #expect(rotation.index == 0)

        // A nonsensical divisor cannot produce a nonsensical subset.
        #expect(IntegrityRotation(divisor: 0).subsetArgument == "1/1")
    }

    @Test("forget and prune shrink the repository and leave it healthy", .enabled(if: resticAvailable))
    func forgetAndPruneWorks() async throws {
        let (client, path) = try await Self.makeRepository(packCount: 10)
        let engine = MaintenanceEngine(locks: RepositoryLockManager())

        let before = try await client.snapshots()
        #expect(before.count == 10)
        let sizeBefore = try await client.stats().totalSize

        let policy = try RetentionPolicy(
            scope: .filesystem,
            keepWithinHours: 0,
            keepDaily: 1,
            keepWeekly: 0,
            keepMonthly: 0,
            keepYearly: 0
        )
        let preview = try await engine.preview(policy: policy, on: client)
        #expect(!preview.remove.isEmpty)

        let outcome = try await engine.forgetAndPrune(
            policy: policy,
            on: client,
            repositoryPath: path.path
        )

        #expect(outcome.pruned)
        #expect(outcome.checkAfterPrune?.isHealthy == true)
        #expect(Set(outcome.removed.map(\.id.value)) == preview.removeIDs)

        let after = try await client.snapshots()
        #expect(after.count < before.count)
        #expect(try await client.stats().totalSize < sizeBefore)
        #expect(try await client.check(readDataSubset: "1/1").isHealthy)
    }

    @Test("refuses to prune when the volume is nearly full")
    func refusesToPruneWithoutHeadroom() throws {
        // A prune that runs out of space part way through is the one failure
        // that can damage a repository, so the margin is checked before it
        // starts rather than hoped for.
        let engine = MaintenanceEngine(
            locks: RepositoryLockManager(),
            pruneFreeSpaceMargin: Int64.max / 2
        )
        #expect(throws: MaintenanceError.self) {
            try engine.ensureEnoughSpaceToPrune(at: NSTemporaryDirectory())
        }
    }
}

private func UInt8truncating(_ value: Int) -> UInt8 {
    UInt8(truncatingIfNeeded: value)
}
