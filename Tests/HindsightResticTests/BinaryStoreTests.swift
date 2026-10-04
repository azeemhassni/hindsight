import Foundation
import HindsightCore
import Testing
@testable import HindsightRestic

private func repositoryRoot(file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private var vendorBinDirectory: URL { repositoryRoot().appendingPathComponent("vendor/bin") }

/// Visible to the browsing suite below as well.
private let vendorBin = repositoryRoot().appendingPathComponent("vendor/bin")

private var hasVendoredBinaries: Bool {
    FileManager.default.fileExists(atPath: vendorBinDirectory.path)
}

@Suite("Pinned binaries")
struct PinnedBinaryTests {
    @Test("pins restic for both Linux architectures and both Mac architectures")
    func pinsEveryPlatform() throws {
        for platform in VendoredPlatform.allCases {
            #expect(throws: Never.self) { try PinnedBinaries.find(.restic, for: platform) }
        }
        #expect(throws: Never.self) { try PinnedBinaries.find(.restServer, for: .darwinARM64) }
        #expect(throws: Never.self) { try PinnedBinaries.find(.restServer, for: .darwinAMD64) }
    }

    @Test("does not pin rest-server for Linux, which never runs there")
    func doesNotPinLinuxRestServer() {
        #expect(throws: BinaryStoreError.noPinnedBinary(tool: "rest-server", platform: "linux_amd64")) {
            try PinnedBinaries.find(.restServer, for: .linuxAMD64)
        }
    }

    @Test("every pinned digest is a real sha-256 and never left as a placeholder")
    func digestsAreRecorded() {
        #expect(!PinnedBinaries.all.isEmpty)
        for binary in PinnedBinaries.all {
            #expect(binary.binarySHA256.count == 64, "\(binary.fileName) has no recorded binary digest")
            #expect(binary.archiveSHA256.count == 64, "\(binary.fileName) has no recorded archive digest")
            let digestsAreHexadecimal = (binary.binarySHA256 + binary.archiveSHA256)
                .allSatisfy(\.isHexDigit)
            #expect(digestsAreHexadecimal, "\(binary.fileName) has a non-hexadecimal digest")
            #expect(binary.binarySHA256 != binary.archiveSHA256)
        }
    }

    @Test("maps a server architecture to the right Linux build")
    func mapsArchitecture() throws {
        try #expect(PinnedBinaries.restic(for: .x86_64).platform == .linuxAMD64)
        try #expect(PinnedBinaries.restic(for: .aarch64).platform == .linuxARM64)
        #expect(VendoredPlatform(linux: .aarch64).isLinux)
        #expect(!VendoredPlatform.host.isLinux)
    }

    @Test("the remote cache path carries the version so an upgrade cannot reuse an old binary")
    func remoteCachePathIsVersioned() throws {
        let binary = try PinnedBinaries.restic(for: .aarch64)
        #expect(binary.remoteCachePath == ".cache/hindsight/restic-\(binary.version)")
        #expect(binary.fileName == "restic-\(binary.version)-linux_arm64")
    }
}

@Suite("Binary store")
struct BinaryStoreTests {
    private func makeStore() throws -> (BinaryStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hindsight-binary-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (BinaryStore(directory: directory), directory)
    }

    private func write(_ contents: String, to url: URL, executable: Bool = true) throws {
        try Data(contents.utf8).write(to: url)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }

    @Test("computes a known sha-256")
    func computesKnownDigest() throws {
        let (_, directory) = try makeStore()
        let file = directory.appendingPathComponent("payload")
        try write("abc", to: file, executable: false)
        try #expect(
            BinaryStore.sha256(of: file)
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    @Test("accepts a binary whose digest matches")
    func acceptsMatchingDigest() throws {
        let (store, directory) = try makeStore()
        let binary = PinnedBinary(
            tool: .restic,
            version: "0.0.1",
            platform: .linuxARM64,
            archiveName: "x.bz2",
            archiveSHA256: String(repeating: "0", count: 64),
            binarySHA256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        try write("abc", to: directory.appendingPathComponent(binary.fileName))
        try #expect(store.verifiedURL(for: binary).lastPathComponent == binary.fileName)
    }

    @Test("refuses a binary whose digest does not match")
    func refusesMismatchedDigest() throws {
        let (store, directory) = try makeStore()
        let expected = String(repeating: "a", count: 64)
        let binary = PinnedBinary(
            tool: .restic,
            version: "0.0.1",
            platform: .linuxARM64,
            archiveName: "x.bz2",
            archiveSHA256: String(repeating: "0", count: 64),
            binarySHA256: expected
        )
        try write("tampered", to: directory.appendingPathComponent(binary.fileName))

        do {
            _ = try store.verifiedURL(for: binary)
            Issue.record("expected a digest mismatch")
        } catch let error as BinaryStoreError {
            guard case let .digestMismatch(fileName, reportedExpected, actual) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(fileName == binary.fileName)
            #expect(reportedExpected == expected)
            #expect(actual != expected)
            #expect("\(error)".contains("will not be used"))
        }
    }

    @Test("reports a missing binary with the directory it looked in")
    func reportsMissingBinary() throws {
        let (store, _) = try makeStore()
        let binary = try PinnedBinaries.restic(for: .aarch64)
        #expect(!store.exists(binary))
        do {
            _ = try store.verifiedURL(for: binary)
            Issue.record("expected a missing-binary error")
        } catch let error as BinaryStoreError {
            guard case let .missing(fileName, directory) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(fileName == binary.fileName)
            #expect(directory == store.directory.path)
            #expect("\(error)".contains("make vendor"))
        }
    }

    @Test("refuses a binary that is present and correct but not executable")
    func refusesNonExecutable() throws {
        let (store, directory) = try makeStore()
        let binary = PinnedBinary(
            tool: .restic,
            version: "0.0.1",
            platform: .linuxARM64,
            archiveName: "x.bz2",
            archiveSHA256: String(repeating: "0", count: 64),
            binarySHA256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        let file = directory.appendingPathComponent(binary.fileName)
        try write("abc", to: file, executable: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(throws: BinaryStoreError.notExecutable(path: file.path)) {
            try store.verifiedURL(for: binary)
        }
    }

    @Test("verifies the real vendored binaries", .enabled(if: hasVendoredBinaries))
    func verifiesVendoredBinaries() throws {
        let store = BinaryStore(directory: vendorBinDirectory)
        for binary in PinnedBinaries.all {
            #expect(throws: Never.self, "\(binary.fileName) failed verification") {
                try store.verifiedURL(for: binary)
            }
        }
    }
}

@Suite("Snapshot browsing", .timeLimit(.minutes(5)), .serialized)
struct SnapshotBrowsingTests {
    static var resticAvailable: Bool {
        (try? BinaryStore(directory: vendorBin)
            .verifiedURL(for: try PinnedBinaries.hostRestic)) != nil
    }

    /// A repository with a small tree, so the browser's one-level listing can
    /// be checked against something real.
    static func makeRepository() async throws -> (ResticClient, SnapshotID) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hindsight-browse-\(UUID().uuidString)")
        let data = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(
            at: data.appendingPathComponent("nested/deeper"),
            withIntermediateDirectories: true
        )
        try Data("one\n".utf8).write(to: data.appendingPathComponent("one.txt"))
        try Data("two\n".utf8).write(to: data.appendingPathComponent("two.txt"))
        try Data("leaf\n".utf8).write(to: data.appendingPathComponent("nested/leaf.txt"))
        try Data("deep\n".utf8).write(to: data.appendingPathComponent("nested/deeper/deep.txt"))

        let password = Secret(label: "repo", value: "browse-test")
        let client = ResticClient(
            executable: try BinaryStore(directory: vendorBin)
                .verifiedURL(for: try PinnedBinaries.hostRestic),
            location: .local(root.appendingPathComponent("repo")),
            password: password
        )
        _ = try await client.initializeIfNeeded()
        try await client.run(["backup", data.path], operation: "backup")

        let snapshot = try #require(try await client.snapshots().first)
        return (client, SnapshotID(unchecked: snapshot.id))
    }

    @Test("lists one directory at a time, not the whole tree", .enabled(if: resticAvailable))
    func listsOneLevel() async throws {
        let (client, snapshot) = try await Self.makeRepository()

        // Walk down from the root, which is what the browser does as folders
        // are opened.
        var path = "/"
        var guard_ = 0
        while guard_ < 10 {
            let children = try await client.children(ofSnapshot: snapshot, path: path)
            guard let next = children.first(where: \.isDirectory), children.count == 1 else { break }
            path = next.path
            guard_ += 1
        }

        let children = try await client.children(ofSnapshot: snapshot, path: path)
        #expect(children.map(\.name).sorted() == ["nested", "one.txt", "two.txt"])
        // Directories first.
        #expect(children.first?.isDirectory == true)
        // And nothing from deeper in the tree.
        #expect(!children.contains { $0.name == "leaf.txt" })

        let nested = try #require(children.first { $0.name == "nested" })
        let grandchildren = try await client.children(ofSnapshot: snapshot, path: nested.path)
        #expect(grandchildren.map(\.name).sorted() == ["deeper", "leaf.txt"])
    }

    @Test("writes a single file out of a snapshot", .enabled(if: resticAvailable))
    func dumpsOneFile() async throws {
        let (client, snapshot) = try await Self.makeRepository()
        let nodes = try await client.list(snapshot: snapshot)
        let file = try #require(nodes.first { $0.name == "one.txt" })

        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hindsight-dump-\(UUID().uuidString)")
        try await client.dumpFile(snapshot: snapshot, path: file.path, to: destination)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "one")
    }
}
