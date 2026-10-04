import Foundation
import HindsightSSH

/// Collects the facts that make a snapshot self-describing.
///
/// These are recorded, never replayed: a restore writes files back, it does not
/// reinstall packages or start units. Their value is that a rebuild years later
/// does not have to guess what the machine was.
public enum MetadataCollector {
    /// Written to a tmpfs path so nothing lands on the server's disk, and under
    /// a fixed path so the snapshot's file tree is stable and browsable.
    public static let remoteDirectory = "/run/hindsight/meta"

    public static var script: String {
        """
        set -u
        target=\(remoteDirectory)
        rm -rf "$target"
        mkdir -p "$target/crontabs"

        (dpkg --get-selections 2>/dev/null || rpm -qa 2>/dev/null || true) > "$target/packages.txt"
        (systemctl list-unit-files --state=enabled --no-pager --no-legend 2>/dev/null || true) \
          > "$target/systemd-units.txt"
        (systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null || true) \
          > "$target/systemd-running.txt"

        for user in $(cut -d: -f1 /etc/passwd 2>/dev/null); do
          crontab -l -u "$user" > "$target/crontabs/$user" 2>/dev/null || true
          [ -s "$target/crontabs/$user" ] || rm -f "$target/crontabs/$user"
        done
        (cat /etc/crontab 2>/dev/null || true) > "$target/crontabs/etc-crontab"

        (docker ps --no-trunc --format '{{json .}}' 2>/dev/null || true) > "$target/docker-ps.json"
        (docker image ls --digests --format '{{json .}}' 2>/dev/null || true) > "$target/docker-images.json"
        (docker volume ls --format '{{json .}}' 2>/dev/null || true) > "$target/docker-volumes.json"
        for container in $(docker ps -q 2>/dev/null); do
          docker inspect "$container" > "$target/docker-inspect-$container.json" 2>/dev/null || true
        done

        (findmnt -A --json 2>/dev/null || mount 2>/dev/null || true) > "$target/mounts.json"
        (lsblk --json 2>/dev/null || true) > "$target/lsblk.json"
        (cat /etc/os-release 2>/dev/null || true) > "$target/os-release"
        (uname -a 2>/dev/null || true) > "$target/uname.txt"
        (ip -json addr 2>/dev/null || ip addr 2>/dev/null || true) > "$target/network.json"
        (free -b 2>/dev/null || true) > "$target/memory.txt"
        (df -PB1 2>/dev/null || true) > "$target/disk-usage.txt"
        """
    }

    public static func manifestScript(contents: String) -> String {
        """
        cat > \(ShellQuoting.quote(remoteDirectory + "/hindsight-manifest.json")) <<'HINDSIGHT_MANIFEST'
        \(contents)
        HINDSIGHT_MANIFEST
        """
    }

    public static var cleanupScript: String {
        "rm -rf \(ShellQuoting.quote(remoteDirectory))"
    }
}

/// Recorded alongside the metadata so a snapshot explains itself without the
/// catalog, which is the situation that matters during a disaster.
public struct SnapshotManifest: Codable, Sendable, Hashable {
    public var hindsightVersion: String
    public var resticVersion: String
    public var profileName: String
    public var includePaths: [String]
    public var excludePatterns: [String]
    public var serverName: String
    public var serverID: String
    public var createdAt: Date

    public init(
        hindsightVersion: String,
        resticVersion: String,
        profileName: String,
        includePaths: [String],
        excludePatterns: [String],
        serverName: String,
        serverID: String,
        createdAt: Date = Date()
    ) {
        self.hindsightVersion = hindsightVersion
        self.resticVersion = resticVersion
        self.profileName = profileName
        self.includePaths = includePaths
        self.excludePatterns = excludePatterns
        self.serverName = serverName
        self.serverID = serverID
        self.createdAt = createdAt
    }

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
