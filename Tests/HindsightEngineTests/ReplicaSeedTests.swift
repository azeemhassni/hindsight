import Foundation
import Testing
@testable import HindsightEngine

/// The seed rebuilds the machine; the data is restored onto it afterwards.
@Suite("Replica seed")
struct ReplicaSeedTests {
    private let dpkgList = """
    bash\tinstall
    coreutils\tinstall
    nginx:amd64\tinstall
    postfix\tdeinstall
    curl\tinstall
    """

    private let units = """
    nginx.service                    enabled
    docker.service                   enabled
    getty@.service                   enabled
    apt-daily.timer                  disabled
    ssh.service                      enabled
    """

    private let osRelease = """
    NAME="Ubuntu"
    ID=ubuntu
    VERSION_ID="24.04"
    PRETTY_NAME="Ubuntu 24.04.1 LTS"
    """

    private func source(
        packages: String? = nil,
        key: String? = "ssh-ed25519 AAAAC3Nza hindsight"
    ) -> ReplicaSeed.Source {
        ReplicaSeed.Source(
            hostname: "web-01",
            osRelease: osRelease,
            packages: packages ?? dpkgList,
            systemdUnits: units,
            dockerPresent: true,
            sshUser: "root",
            authorizedKey: key
        )
    }

    @Test("installs what was selected, and not what was deselected")
    func readsPackageSelections() {
        let packages = ReplicaSeed.installablePackages(from: dpkgList)
        #expect(packages == ["bash", "coreutils", "curl", "nginx"])
        // `deinstall` means the machine was deliberately without it.
        #expect(!packages.contains("postfix"))
    }

    @Test("enables the units that were enabled, and skips templates")
    func readsEnabledUnits() {
        let enabled = ReplicaSeed.enabledUnits(from: units)
        #expect(enabled == ["docker.service", "nginx.service", "ssh.service"])
        // A template cannot be enabled without an instance.
        #expect(!enabled.contains("getty@.service"))
        #expect(!enabled.contains("apt-daily.timer"))
    }

    @Test("produces cloud-config a NoCloud datasource will read")
    func producesCloudConfig() {
        let output = ReplicaSeed.build(from: source(), instanceID: "hs-test")

        #expect(output.userData.hasPrefix("#cloud-config\n"))
        #expect(output.userData.contains("hostname: web-01"))
        #expect(output.userData.contains("  - nginx"))
        #expect(output.userData.contains("systemctl enable nginx.service"))
        #expect(output.userData.contains("get.docker.com"))
        #expect(output.metaData.contains("instance-id: hs-test"))
        #expect(output.metaData.contains("local-hostname: web-01"))
    }

    /// Without a key the replica cannot be restored onto, which is the whole
    /// point of building it.
    @Test("carries Hindsight's key so the replica can be restored onto")
    func carriesTheKey() {
        let output = ReplicaSeed.build(from: source())
        #expect(output.userData.contains("ssh_authorized_keys"))
        #expect(output.userData.contains("ssh-ed25519 AAAAC3Nza hindsight"))

        let without = ReplicaSeed.build(from: source(key: nil))
        #expect(!without.userData.contains("ssh_authorized_keys"))
        #expect(without.warnings.contains { $0.contains("will not") && $0.contains("restore") })
    }

    /// The thing a person is most likely to assume wrongly.
    @Test("says plainly that it carries no data")
    func saysItHasNoData() {
        let output = ReplicaSeed.build(from: source())
        #expect(output.notes.contains("None of your data is here"))
        #expect(output.notes.contains("Restore it from Hindsight"))
        // And it is written onto the replica, not just shown once.
        #expect(output.userData.contains("/root/hindsight-replica.md"))
    }

    @Test("refuses to pretend it can install rpm packages by name")
    func handlesRPM() {
        let rpm = """
        bash-5.2.15-1.fc38.x86_64
        coreutils-9.1-12.fc38.x86_64
        """
        #expect(ReplicaSeed.packageFormat(of: rpm) == .rpm)

        let output = ReplicaSeed.build(from: source(packages: rpm))
        #expect(output.warnings.contains { $0.contains("rpm") })
        // Nothing invented: no package list rather than a wrong one.
        #expect(!output.userData.contains("packages:"))
    }

    @Test("warns that packages are installed by name from the distribution")
    func warnsAboutMissingPackages() {
        let output = ReplicaSeed.build(from: source())
        #expect(output.warnings.contains { $0.contains("removed from them will fail") })
    }
}

/// Writing the seed as an ISO a cloud-init datasource will actually find.
@Suite("Replica seed image")
struct SeedISOTests {
    @Test("writes an ISO9660 image labelled cidata, holding both files")
    func writesAMountableImage() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hindsight-seed-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("seed.iso")
        let written = try await SeedISO.write(
            userData: "#cloud-config\nhostname: replica\n",
            metaData: "instance-id: hs-1\nlocal-hostname: replica\n",
            to: destination
        )

        #expect(FileManager.default.fileExists(atPath: written.path))
        let size = try FileManager.default.attributesOfItem(atPath: written.path)[.size] as? Int ?? 0
        #expect(size > 0)

        // ISO9660 writes the identifier "CD001" at the start of the volume
        // descriptor, one sector in. A file with the right name that is not an
        // image would pass every other check here.
        let handle = try FileHandle(forReadingFrom: written)
        defer { try? handle.close() }
        try handle.seek(toOffset: 32_769)
        let marker = try handle.read(upToCount: 5) ?? Data()
        #expect(String(decoding: marker, as: UTF8.self) == "CD001")
    }

    @Test("refuses to report success when nothing was written")
    func failsLoudly() async {
        await #expect(throws: (any Error).self) {
            _ = try await SeedISO.write(
                userData: "x",
                metaData: "y",
                to: URL(fileURLWithPath: "/this/path/does/not/exist/seed.iso")
            )
        }
    }
}
