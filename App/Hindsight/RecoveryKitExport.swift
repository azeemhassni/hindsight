import AppKit
import HindsightCatalog
import HindsightCore
import HindsightKeychain
import HindsightUI

/// Saving the recovery kit.
///
/// The kit is assembled in the app rather than the agent because saving it is
/// something a person does, with a file dialog. It reads the passwords from the
/// Keychain, which the app can do because it is signed with the same team as
/// the agent and shares its keychain access group.
@MainActor
enum RecoveryKitExport {
    static func run(catalog: CatalogReader?, secrets: any SecretStore) {
        guard let catalog else {
            present(message: "No catalog is open yet, so there is nothing to export.")
            return
        }

        let kit: RecoveryKit
        do {
            kit = try build(catalog: catalog, secrets: secrets)
        } catch {
            present(message: "Could not assemble the recovery kit: \(error)")
            return
        }

        // A kit missing a password would look like the job was done while
        // leaving the backups unreadable, so it is refused rather than saved.
        guard kit.isUsable else {
            present(
                message: """
                Some repositories have no password in the Keychain \
                (\(kit.missingPasswordServers.joined(separator: ", "))). Saving \
                this kit would look like the job was done while leaving those \
                backups unreadable.
                """
            )
            return
        }

        let panel = NSSavePanel()
        panel.title = "Save recovery kit"
        panel.nameFieldStringValue = "Hindsight recovery kit.md"
        panel.message = """
        Keep this somewhere other than this Mac. Without it, these backups \
        cannot be read by anyone, ever.
        """
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try Data(kit.markdown().utf8).write(to: url, options: .atomic)
            // The machine-readable copy goes beside it, for a password manager
            // or another tool.
            let json = url.deletingPathExtension().appendingPathExtension("json")
            try Data(kit.json().utf8).write(to: json, options: .atomic)
            // Owner-only: this file is as sensitive as the servers themselves.
            for file in [url, json] {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: file.path
                )
            }
        } catch {
            present(message: "Could not write the recovery kit: \(error)")
        }
    }

    static func build(catalog: CatalogReader, secrets: any SecretStore) throws -> RecoveryKit {
        let servers = try catalog.servers()
        let entries = servers.map { server -> RecoveryKit.Entry in
            let repository = try? catalog.repository(forServer: server.id)
            let password = try? secrets.read(.repositoryPassword(server.id))
            return RecoveryKit.Entry(
                serverID: server.id.value,
                serverName: server.name,
                host: server.endpoint.host,
                repositoryPath: repository?.path ?? "",
                repositoryPassword: password?.value ?? "",
                createdAt: repository?.createdAt ?? Date()
            )
        }

        return RecoveryKit(
            entries: entries,
            resticVersion: (try? PinnedResticVersion.current) ?? "0.19.1",
            hindsightVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                ?? "0.1.0"
        )
    }

    private static func present(message: String) {
        let alert = NSAlert()
        alert.messageText = "Recovery kit"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// The restic version the kit should name, taken from the pinned table rather
/// than written down twice.
enum PinnedResticVersion {
    static var current: String {
        get throws { try HindsightUI.pinnedResticVersion() }
    }
}
