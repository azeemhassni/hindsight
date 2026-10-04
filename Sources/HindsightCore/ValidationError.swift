public enum ValidationError: Error, Hashable, Sendable {
    case emptyServerID
    case serverIDTooLong(Int, maximum: Int)
    case serverIDHasDisallowedCharacters(String)
    case emptySnapshotID
    case snapshotIDNotHexadecimal(String)
    case emptyServerName
    case invalidPort(Int)
    case emptySSHHost
    case emptySSHUser
    case invalidHourInterval(Int)
    case invalidTimeOfDay(hour: Int, minute: Int)
    case unknownTimeZone(String)
    case negativeRetentionCount(String, Int)
    case retentionKeepsNothing
    case emptyIncludePaths
    case relativePath(String)
    case invalidBandwidthLimit(Int)
}

extension ValidationError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .emptyServerID:
            "Server identifier is empty."
        case let .serverIDTooLong(length, maximum):
            "Server identifier is \(length) characters; the maximum is \(maximum)."
        case let .serverIDHasDisallowedCharacters(raw):
            "Server identifier \(raw.debugDescription) must be lowercase letters, digits, and inner hyphens only."
        case .emptySnapshotID:
            "Snapshot identifier is empty."
        case let .snapshotIDNotHexadecimal(raw):
            "Snapshot identifier \(raw.debugDescription) is not a hexadecimal restic id."
        case .emptyServerName:
            "Server name is empty."
        case let .invalidPort(port):
            "Port \(port) is outside 1–65535."
        case .emptySSHHost:
            "SSH host is empty."
        case .emptySSHUser:
            "SSH user is empty."
        case let .invalidHourInterval(hours):
            "An interval of \(hours) hours is not between 1 and 24."
        case let .invalidTimeOfDay(hour, minute):
            "\(hour):\(minute) is not a valid time of day."
        case let .unknownTimeZone(identifier):
            "Unknown time zone \(identifier.debugDescription)."
        case let .negativeRetentionCount(rule, value):
            "Retention rule \(rule) cannot be negative (got \(value))."
        case .retentionKeepsNothing:
            "A retention policy that keeps nothing would delete every snapshot."
        case .emptyIncludePaths:
            "A backup profile must include at least one path."
        case let .relativePath(path):
            "Path \(path.debugDescription) must be absolute."
        case let .invalidBandwidthLimit(limit):
            "Bandwidth limit \(limit) KiB/s must be greater than zero."
        }
    }
}
