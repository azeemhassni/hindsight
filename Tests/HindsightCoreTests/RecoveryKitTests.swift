import Foundation
import Testing
@testable import HindsightCore
@Suite("Recovery kit")
struct RecoveryKitTests {
    private func kit(password: String = "dGVzdC1wYXNzd29yZC1oZXJl") -> RecoveryKit {
        RecoveryKit(
            entries: [
                RecoveryKit.Entry(
                    serverID: "web-01",
                    serverName: "Web 01",
                    host: "198.51.100.10",
                    repositoryPath: "/Volumes/Backups/Hindsight/repos/web-01",
                    repositoryPassword: password,
                    createdAt: Date(timeIntervalSince1970: 1_800_000_000)
                ),
            ],
            resticVersion: "0.19.1",
            hindsightVersion: "0.1.0",
            exportedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    @Test("contains the password, because that is the whole point")
    func containsThePassword() {
        let markdown = kit().markdown()
        #expect(markdown.contains("dGVzdC1wYXNzd29yZC1oZXJl"))
        #expect(markdown.contains("/Volumes/Backups/Hindsight/repos/web-01"))
        #expect(markdown.contains("Web 01"))
    }

    @Test("says plainly that losing it means losing the backups")
    func warnsAboutLoss() {
        let markdown = kit().markdown()
        // The warning has to be unmissable and unambiguous — no hedging.
        #expect(markdown.contains("no recovery"))
        #expect(markdown.contains("the backups are gone"))
        #expect(markdown.contains("survives the Mac"))
    }

    @Test("warns that the document is as sensitive as the servers")
    func warnsAboutDisclosure() {
        #expect(kit().markdown().contains("keys to the servers"))
    }

    @Test("gives commands that can be pasted as they are")
    func givesLiteralCommands() {
        let markdown = kit().markdown()
        // No placeholders to work out under stress.
        #expect(markdown.contains("export RESTIC_REPOSITORY='/Volumes/Backups/Hindsight/repos/web-01'"))
        #expect(markdown.contains("export RESTIC_PASSWORD='dGVzdC1wYXNzd29yZC1oZXJl'"))
        #expect(markdown.contains("restic snapshots"))
        #expect(markdown.contains("restic restore latest --target /tmp/restored-web-01"))
        #expect(markdown.contains("restic check --read-data"))
        #expect(!markdown.contains("<password>"))
        #expect(!markdown.contains("YOUR_"))
    }

    @Test("quotes a password that would otherwise break the shell")
    func quotesAwkwardPasswords() {
        let markdown = kit(password: "it's a+b/c=d").markdown()
        #expect(markdown.contains("export RESTIC_PASSWORD='it'\\''s a+b/c=d'"))
    }

    @Test("names the restic version needed to read the repository")
    func namesResticVersion() {
        #expect(kit().markdown().contains("0.19.1"))
        #expect(kit().markdown().contains("restic.net"))
    }

    @Test("says what it cannot do, as well as what it can")
    func admitsItsLimits() {
        // A password cannot rebuild a lost disk, and someone reading this
        // under pressure should not have to work that out.
        #expect(kit().markdown().contains("cannot rebuild missing data"))
        #expect(kit().markdown().contains("second copy"))
    }

    @Test("round-trips as machine-readable JSON")
    func exportsJSON() throws {
        let json = try kit().json()
        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(decoded?["format"] as? String == "hindsight-recovery-kit/1")
        let repositories = try #require(decoded?["repositories"] as? [[String: Any]])
        #expect(repositories.count == 1)
        #expect(repositories[0]["repositoryPassword"] as? String == "dGVzdC1wYXNzd29yZC1oZXJl")
    }

    @Test("refuses to call itself usable when a password is missing")
    func detectsMissingPasswords() {
        #expect(kit().isUsable)

        let incomplete = kit(password: "")
        // Exporting a kit with no password would look like the job was done.
        #expect(!incomplete.isUsable)
        #expect(incomplete.missingPasswordServers == ["Web 01"])
    }

    @Test("an empty kit is not usable")
    func emptyKitIsNotUsable() {
        let empty = RecoveryKit(entries: [], resticVersion: "0.19.1", hindsightVersion: "0.1.0")
        #expect(!empty.isUsable)
    }

    @Test("covers every server, not just the first")
    func coversEveryServer() {
        let many = RecoveryKit(
            entries: (1...3).map { index in
                RecoveryKit.Entry(
                    serverID: "web-0\(index)",
                    serverName: "Web 0\(index)",
                    host: "198.51.100.\(index)",
                    repositoryPath: "/repos/web-0\(index)",
                    repositoryPassword: "password-\(index)",
                    createdAt: Date()
                )
            },
            resticVersion: "0.19.1",
            hindsightVersion: "0.1.0"
        )
        let markdown = many.markdown()
        for index in 1...3 {
            #expect(markdown.contains("password-\(index)"))
            #expect(markdown.contains("Web 0\(index)"))
        }
    }
}

@Suite("Recovery kit version")
struct RecoveryKitVersionTests {
    /// The kit tells someone which restic to use. If that drifts from the
    /// version Hindsight actually writes repositories with, the instructions
    /// could name a release that cannot read them.
    @Test("names the same restic version the build pins")
    func matchesThePinnedVersion() throws {
        let checksums = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("vendor/checksums.txt")
        let contents = try String(contentsOf: checksums, encoding: .utf8)

        let pinned = contents
            .split(separator: "\n")
            .filter { !$0.hasPrefix("#") && $0.contains("restic\t") }
            .compactMap { $0.split(separator: "\t").dropFirst().first.map(String.init) }

        #expect(!pinned.isEmpty, "no restic version found in vendor/checksums.txt")
        #expect(
            pinned.allSatisfy { $0 == RecoveryKit.defaultResticVersion },
            "the recovery kit names \(RecoveryKit.defaultResticVersion) but the build pins \(Set(pinned))"
        )
    }
}
