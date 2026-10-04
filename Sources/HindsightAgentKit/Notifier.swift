import Foundation
import UserNotifications

/// User notifications from the agent.
///
/// Only things worth interrupting someone for: a backup that failed, a restore
/// that finished, and an integrity problem. A successful routine backup is not
/// news, and a tool that announces every success trains people to ignore it —
/// which is exactly the wrong habit for the one notification that matters.
public struct Notifier: Sendable {
    /// Whether a notification centre is available at all.
    ///
    /// `UNUserNotificationCenter.current()` requires a bundle identifier and
    /// traps without one, which is the case when the agent runs from the
    /// command line or under tests.
    private let isAvailable: Bool

    public init() {
        isAvailable = Bundle.main.bundleIdentifier != nil
    }

    public func requestAuthorizationIfNeeded() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public func backupFailed(server: String, reason: String) {
        post(
            identifier: "backup-failed-\(server)",
            title: "Backup of \(server) failed",
            body: Self.firstLine(of: reason)
        )
    }

    public func restoreFinished(server: String, succeeded: Bool) {
        post(
            identifier: "restore-\(server)-\(Date().timeIntervalSince1970)",
            title: succeeded
                ? "Restore of \(server) finished"
                : "Restore of \(server) failed",
            body: succeeded
                ? "A snapshot was taken of everything it replaced, so this can be undone."
                : "Nothing was changed that cannot be undone from the safety snapshot."
        )
    }

    public func integrityProblem(server: String, message: String) {
        post(
            identifier: "integrity-\(server)",
            title: "\(server): backup integrity problem",
            body: Self.firstLine(of: message)
        )
    }

    private func post(identifier: String, title: String, body: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        )
    }

    /// Notifications are read at a glance, and a Swift error description can
    /// run to a dozen lines of shell script.
    static func firstLine(of text: String) -> String {
        let line = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? text
        return line.count > 180 ? String(line.prefix(177)) + "…" : line
    }
}
