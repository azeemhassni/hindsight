import AppKit
import HindsightCore
import HindsightProtocol

/// Saving the recovery kit.
///
/// The agent assembles it, because the passwords are its to read; the app puts
/// the file where a person wants it, because that is a question only a person
/// can answer.
@MainActor
enum RecoveryKitExport {
    /// Saves a kit the agent assembled. Returns whether a file was actually
    /// written, so a caller can tell saving it from cancelling the dialog —
    /// the difference between a server whose backups can be read elsewhere and
    /// one whose cannot.
    @discardableResult
    static func save(_ report: RecoveryKitReport?) -> Bool {
        guard let report else { return false }

        // A kit missing a password would look like the job was done while
        // leaving the backups unreadable, so it is refused rather than saved.
        guard report.isUsable else {
            present(
                message: report.serverCount == 0
                    ? "That server has no repository yet, so there is nothing to save."
                    : """
                    Some repositories have no password in the Keychain \
                    (\(report.missingPasswordServers.joined(separator: ", "))). Saving \
                    this kit would look like the job was done while leaving those \
                    backups unreadable.
                    """
            )
            return false
        }

        let panel = NSSavePanel()
        panel.title = "Save recovery kit"
        panel.nameFieldStringValue = "Hindsight recovery kit.md"
        panel.message = """
        Keep this somewhere other than this Mac. Without it, these backups \
        cannot be read by anyone, ever.
        """
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return false }

        do {
            try Data(report.markdown.utf8).write(to: url, options: .atomic)
            // The machine-readable copy goes beside it, for a password manager
            // or another tool.
            let json = url.deletingPathExtension().appendingPathExtension("json")
            try Data(report.json.utf8).write(to: json, options: .atomic)
            // Owner-only: this file is as sensitive as the servers themselves.
            for file in [url, json] {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: file.path
                )
            }
            return true
        } catch {
            present(message: "Could not write the recovery kit: \(error)")
            return false
        }
    }

    private static func present(message: String) {
        let alert = NSAlert()
        alert.messageText = "Recovery kit"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}


