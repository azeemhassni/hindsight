import Foundation
import HindsightCore

/// The document that makes backups recoverable without Hindsight.
///
/// This exists because of one failure mode: a Mac that is lost or wiped takes
/// the Keychain with it, and a restic repository without its password is a pile
/// of undecryptable bytes. The kit is therefore not a convenience — it is the
/// difference between having backups and having had them.
public struct RecoveryKit: Sendable, Hashable {
    public struct Entry: Sendable, Hashable, Codable {
        public var serverID: String
        public var serverName: String
        public var host: String
        public var repositoryPath: String
        public var repositoryPassword: String
        public var createdAt: Date

        public init(
            serverID: String,
            serverName: String,
            host: String,
            repositoryPath: String,
            repositoryPassword: String,
            createdAt: Date
        ) {
            self.serverID = serverID
            self.serverName = serverName
            self.host = host
            self.repositoryPath = repositoryPath
            self.repositoryPassword = repositoryPassword
            self.createdAt = createdAt
        }
    }

    public var entries: [Entry]
    public var resticVersion: String
    public var hindsightVersion: String
    public var exportedAt: Date

    public init(
        entries: [Entry],
        resticVersion: String,
        hindsightVersion: String,
        exportedAt: Date = Date()
    ) {
        self.entries = entries
        self.resticVersion = resticVersion
        self.hindsightVersion = hindsightVersion
        self.exportedAt = exportedAt
    }

    /// Machine-readable, for a password manager or another tool.
    public func json() throws -> String {
        struct Payload: Encodable {
            let format: String
            let exportedAt: Date
            let hindsightVersion: String
            let resticVersion: String
            let repositories: [Entry]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(
            Payload(
                format: "hindsight-recovery-kit/1",
                exportedAt: exportedAt,
                hindsightVersion: hindsightVersion,
                resticVersion: resticVersion,
                repositories: entries
            )
        )
        return String(decoding: data, as: UTF8.self)
    }

    /// Human-readable, and written to be followed under stress by someone who
    /// has never used restic: every command is literal, with no placeholders
    /// left to work out.
    public func markdown() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short

        var lines = [
            "# Hindsight recovery kit",
            "",
            "Exported \(formatter.string(from: exportedAt)) by Hindsight \(hindsightVersion).",
            "",
            "## Read this first",
            "",
            """
            Each password below is the only way to read the backups it belongs \
            to. There is no recovery, no reset, and no support channel that can \
            help: the data is encrypted with it and nothing else. If you lose \
            this document and the Mac it came from, the backups are gone.
            """,
            "",
            """
            Keep it somewhere that survives the Mac — a password manager, or \
            printed and stored physically. Anyone who has this document and \
            your repository can read every backup, so treat it like the keys \
            to the servers themselves.
            """,
            "",
            "## Restoring without Hindsight",
            "",
            """
            You need the `restic` binary, version \(resticVersion) or newer, from \
            https://restic.net, and access to the repository files.
            """,
            "",
        ]

        for entry in entries {
            lines += [
                "### \(entry.serverName) (`\(entry.serverID)`)",
                "",
                "- Server: `\(entry.host)`",
                "- Repository: `\(entry.repositoryPath)`",
                "- Added: \(formatter.string(from: entry.createdAt))",
                "",
                "Password:",
                "",
                "```",
                entry.repositoryPassword,
                "```",
                "",
                "List what is in it:",
                "",
                "```sh",
                "export RESTIC_REPOSITORY=\(shellQuoted(entry.repositoryPath))",
                "export RESTIC_PASSWORD=\(shellQuoted(entry.repositoryPassword))",
                "restic snapshots",
                "```",
                "",
                "Restore the most recent snapshot into a new directory:",
                "",
                "```sh",
                "restic restore latest --target /tmp/restored-\(entry.serverID)",
                "```",
                "",
                "Check that the repository is intact:",
                "",
                "```sh",
                "restic check --read-data",
                "```",
                "",
            ]
        }

        lines += [
            "## If the repository itself is gone",
            "",
            """
            These passwords cannot rebuild missing data. If the disk holding a \
            repository has failed and there is no second copy, the backups it \
            held are lost. Hindsight can keep a second copy on another disk or \
            in object storage; if you have not set that up, this document is \
            the reminder to.
            """,
            "",
        ]

        return lines.joined(separator: "\n")
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Whether the kit is complete enough to be worth saving.
    ///
    /// Exporting a kit with no password in it would be worse than not
    /// exporting one, because it would look like the job was done.
    public var isUsable: Bool {
        !entries.isEmpty && entries.allSatisfy { entry in
            !entry.repositoryPassword.isEmpty && !entry.repositoryPath.isEmpty
        }
    }

    public var missingPasswordServers: [String] {
        entries.filter(\.repositoryPassword.isEmpty).map(\.serverName)
    }
}
