import Foundation
import HindsightCore
import HindsightProtocol

/// Formatting shared across the interface.
///
/// Gathered in one place so that a size or an age never reads differently in
/// two views, and so the wording can be tested.
public enum Format {
    public static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: value)
    }

    /// Relative time, kept short enough for a sidebar and a menu bar.
    public static func age(of date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        let interval = now.timeIntervalSince(date)
        if interval < 0 { return "in the future" }
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        if interval < 86400 * 7 { return "\(Int(interval / 86400))d ago" }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    public static func timeUntil(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "not scheduled" }
        let interval = date.timeIntervalSince(now)
        if interval <= 0 { return "due now" }
        if interval < 60 { return "in under a minute" }
        if interval < 3600 { return "in \(Int(interval / 60))m" }
        if interval < 86400 { return "in \(Int(interval / 3600))h" }
        return "in \(Int(interval / 86400))d"
    }

    public static func duration(_ value: Duration?) -> String {
        guard let value else { return "—" }
        let seconds = Double(value.components.seconds)
            + Double(value.components.attoseconds) / 1e18
        if seconds < 1 { return String(format: "%.0f ms", seconds * 1000) }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        if seconds < 3600 { return "\(Int(seconds / 60))m \(Int(seconds) % 60)s" }
        return "\(Int(seconds / 3600))h \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60))m"
    }

    public static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int((value * 100).rounded()))%"
    }

    /// Dedup and compression savings, stated as a ratio rather than a
    /// percentage because "3.4× smaller" is easier to believe than "71% saved".
    public static func savings(stored: Int64, processed: Int64) -> String {
        guard stored > 0, processed > stored else { return "—" }
        let ratio = Double(processed) / Double(stored)
        return String(format: "%.1f× smaller", ratio)
    }

    public static func transferRate(bytes: Int64?, over duration: Duration?) -> String {
        guard let bytes, let duration else { return "—" }
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        guard seconds > 0.1 else { return "—" }
        return "\(self.bytes(Int64(Double(bytes) / seconds)))/s"
    }

    public static func estimatedTimeRemaining(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "—" }
        if seconds < 60 { return "\(seconds)s left" }
        if seconds < 3600 { return "\(seconds / 60)m left" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m left"
    }
}

/// What the health dot means, in words.
public extension ServerStatus.Health {
    var label: String {
        switch self {
        case .healthy: "Healthy"
        case .stale: "Backup is overdue"
        case .failing: "Needs attention"
        case .unknown: "Not backed up yet"
        }
    }

    /// Spoken by VoiceOver, so it stands alone without the colour.
    var accessibilityDescription: String {
        switch self {
        case .healthy: "Healthy. Recent backup, last check passed."
        case .stale: "Overdue. The most recent backup is more than two days old."
        case .failing: "Needs attention. The last integrity check did not pass."
        case .unknown: "Unknown. This server has not been backed up yet."
        }
    }

    var symbolName: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .stale: "clock.badge.exclamationmark.fill"
        case .failing: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    /// Sorting puts what needs attention at the top of the sidebar.
    var severity: Int {
        switch self {
        case .failing: 0
        case .stale: 1
        case .unknown: 2
        case .healthy: 3
        }
    }
}
