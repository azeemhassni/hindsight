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
            guard case let .digestMismatch(fileName, reportedExpected, actual, path) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(fileName == binary.fileName)
            #expect(reportedExpected == expected)
            #expect(actual != expected)
            // The path is in the message because the same file name can live
            // in a vendor directory, an app bundle and a cache.
            #expect(path.hasSuffix(binary.fileName))
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
        // Bytes that are not valid UTF-8, for the extraction test: a file that
        // survives a round trip through a `String` proves nothing.
        try Data([0xFF, 0xD8, 0xFF, 0x00, 0x01, 0x80, 0xFE])
            .write(to: data.appendingPathComponent("binary.bin"))

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
        #expect(children.map(\.name).sorted() == ["binary.bin", "nested", "one.txt", "two.txt"])
        // Directories first.
        #expect(children.first?.isDirectory == true)
        // And nothing from deeper in the tree.
        #expect(!children.contains { $0.name == "leaf.txt" })

        let nested = try #require(children.first { $0.name == "nested" })
        let grandchildren = try await client.children(ofSnapshot: snapshot, path: nested.path)
        #expect(grandchildren.map(\.name).sorted() == ["deeper", "leaf.txt"])
    }

    /// Measured against restic 0.19.1: `ls` with no path walks the entire
    /// snapshot and `--recursive` makes no difference to that, so a root
    /// listing that passed no path read every file on the server to show a
    /// handful of rows. Asserted on the arguments because the two produce the
    /// same answer — one is just enormously slower.
    @Test("names the directory it lists, so the root is not a whole-tree read")
    func rootListingNamesThePath() {
        let snapshot = SnapshotID(unchecked: "abc123")
        let root = ResticClient.listArguments(snapshot: snapshot, paths: ["/"], recursive: false)
        #expect(root == ["ls", "--json", "abc123", "/"])

        let several = ResticClient.listArguments(
            snapshot: snapshot,
            paths: ["/etc", "/srv"],
            recursive: false
        )
        // One invocation for both, which is what restic charges the same price
        // for: the cost is the index load, not the listing.
        #expect(several == ["ls", "--json", "abc123", "/etc", "/srv"])

        let whole = ResticClient.listArguments(snapshot: snapshot, paths: [], recursive: true)
        #expect(whole == ["ls", "--json", "--recursive", "abc123"])
    }

    @Test("lists several directories in one restic run", .enabled(if: resticAvailable))
    func listsSeveralDirectoriesAtOnce() async throws {
        let (client, snapshot) = try await Self.makeRepository()

        // Find the data root inside the snapshot, then its nested folder.
        var root = "/"
        var dataRoot = "/"
        while true {
            let children = try await client.children(ofSnapshot: snapshot, path: root)
            guard children.count == 1, let only = children.first, only.isDirectory else { break }
            dataRoot = only.path
            root = only.path
        }
        let nested = dataRoot + "/nested"

        let groups = try await client.children(ofSnapshot: snapshot, paths: [dataRoot, nested])
        #expect(groups[dataRoot]?.map(\.name).sorted() == ["binary.bin", "nested", "one.txt", "two.txt"])
        #expect(groups[nested]?.map(\.name).sorted() == ["deeper", "leaf.txt"])
        // Only what was asked for: restic also reports the ancestors of each
        // path, and an ancestor's entry holds only the child that led to it.
        #expect(Set(groups.keys) == [dataRoot, nested])
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

    @Test("extracts a file byte for byte, including bytes that are not text", .enabled(if: resticAvailable))
    func extractsOneFileExactly() async throws {
        let (client, snapshot) = try await Self.makeRepository()
        let nodes = try await client.list(snapshot: snapshot)
        let file = try #require(nodes.first { $0.name == "binary.bin" })

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hindsight-extract-\(UUID().uuidString)")
        let written = try await client.extractFile(
            snapshot: snapshot,
            path: file.path,
            toDirectory: directory
        )

        // restic rebuilds the path inside the target directory.
        #expect(written.path.hasPrefix(directory.path))
        #expect(written.lastPathComponent == "binary.bin")
        #expect(try Data(contentsOf: written) == Data([0xFF, 0xD8, 0xFF, 0x00, 0x01, 0x80, 0xFE]))
    }

    @Test("says so rather than inventing a file when the path is not in the snapshot", .enabled(if: resticAvailable))
    func refusesAMissingPath() async throws {
        let (client, snapshot) = try await Self.makeRepository()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hindsight-extract-\(UUID().uuidString)")
        await #expect(throws: (any Error).self) {
            try await client.extractFile(
                snapshot: snapshot,
                path: "/no/such/path",
                toDirectory: directory
            )
        }
    }
}

/// What guarantees a bundled binary, now that it is signed.
///
/// Notarisation requires every Mach-O inside the app to carry its own
/// signature, and signing rewrites the file — so the digest published upstream
/// can no longer match the copy that ships. Inside a sealed bundle macOS checks
/// the signature before the code runs, which is a stronger guarantee than a
/// hash compared against a constant compiled into the same binary doing the
/// comparing. Everywhere else the pin stands, and that includes every binary
/// that travels to a server.
@Suite("Verifying a binary that lives in a signed bundle")
struct BundledBinaryVerificationTests {
    private func binary(digest: String) -> PinnedBinary {
        PinnedBinary(
            tool: .restic,
            version: "0.0.1",
            platform: .darwinARM64,
            archiveName: "x.bz2",
            archiveSHA256: String(repeating: "0", count: 64),
            binarySHA256: digest
        )
    }

    private func makeBundle(signed: Bool) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hindsight-bundle-\(UUID().uuidString)")
        let resources = root.appendingPathComponent("Hindsight.app/Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        if signed {
            let seal = root.appendingPathComponent("Hindsight.app/Contents/_CodeSignature")
            try FileManager.default.createDirectory(at: seal, withIntermediateDirectories: true)
            try Data("<plist/>".utf8).write(to: seal.appendingPathComponent("CodeResources"))
        }
        return resources
    }

    private func write(_ contents: String, named name: String, in directory: URL) throws {
        let file = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    }

    @Test("accepts a signed bundle's own binary, whose bytes signing has changed")
    func acceptsSignedBundleBinary() throws {
        let resources = try makeBundle(signed: true)
        let pinned = binary(digest: String(repeating: "a", count: 64))
        try write("signed, so no longer the upstream bytes", named: pinned.fileName, in: resources)

        let store = BinaryStore(directory: resources)
        #expect(throws: Never.self) { try store.verifiedURL(for: pinned) }
    }

    @Test("still pins a binary in an app bundle that carries no signature")
    func pinsUnsignedBundleBinary() throws {
        let resources = try makeBundle(signed: false)
        let pinned = binary(digest: String(repeating: "a", count: 64))
        try write("tampered", named: pinned.fileName, in: resources)

        let store = BinaryStore(directory: resources)
        #expect(throws: BinaryStoreError.self) { try store.verifiedURL(for: pinned) }
    }

    /// The case that matters most: a binary outside any bundle is the one that
    /// gets copied to a server, and it is pinned whatever else changes.
    @Test("still pins a binary that is not in a bundle at all")
    func pinsLooseBinary() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hindsight-loose-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pinned = binary(digest: String(repeating: "a", count: 64))
        try write("tampered", named: pinned.fileName, in: directory)

        let store = BinaryStore(directory: directory)
        #expect(throws: BinaryStoreError.self) { try store.verifiedURL(for: pinned) }
    }

    @Test("an executable bit is still required, signed bundle or not")
    func stillRequiresAnExecutable() throws {
        let resources = try makeBundle(signed: true)
        let pinned = binary(digest: String(repeating: "a", count: 64))
        let file = resources.appendingPathComponent(pinned.fileName)
        try Data("not executable".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        let store = BinaryStore(directory: resources)
        #expect(throws: BinaryStoreError.self) { try store.verifiedURL(for: pinned) }
    }
}
