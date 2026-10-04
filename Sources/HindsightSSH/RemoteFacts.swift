import Foundation
import HindsightCore

public struct RemoteMount: Hashable, Sendable, Codable {
    public let source: String
    public let target: String
    public let filesystem: String

    public init(source: String, target: String, filesystem: String) {
        self.source = source
        self.target = target
        self.filesystem = filesystem
    }

    /// Filesystems that can give a consistent point-in-time view.
    public var supportsSnapshots: Bool {
        ["btrfs", "zfs"].contains(filesystem) || source.hasPrefix("/dev/mapper/")
    }
}

public struct RemoteFacts: Hashable, Sendable, Codable {
    public var platform: Platform
    public var homeDirectory: String
    public var hasPasswordlessSudo: Bool
    public var hasNice: Bool
    public var hasIonice: Bool
    public var dockerServerVersion: String?
    public var hasCoolifyDirectory: Bool
    public var coolifyContainers: [String]
    /// Present only on machines deliberately marked as throwaway test targets.
    public var hasTestMarker: Bool
    public var mounts: [RemoteMount]
    public var listeningPorts: [Int]

    public init(
        platform: Platform,
        homeDirectory: String,
        hasPasswordlessSudo: Bool,
        hasNice: Bool,
        hasIonice: Bool,
        dockerServerVersion: String?,
        hasCoolifyDirectory: Bool,
        coolifyContainers: [String],
        hasTestMarker: Bool,
        mounts: [RemoteMount],
        listeningPorts: [Int]
    ) {
        self.platform = platform
        self.homeDirectory = homeDirectory
        self.hasPasswordlessSudo = hasPasswordlessSudo
        self.hasNice = hasNice
        self.hasIonice = hasIonice
        self.dockerServerVersion = dockerServerVersion
        self.hasCoolifyDirectory = hasCoolifyDirectory
        self.coolifyContainers = coolifyContainers
        self.hasTestMarker = hasTestMarker
        self.mounts = mounts
        self.listeningPorts = listeningPorts
    }

    public var hasDocker: Bool { dockerServerVersion != nil }

    public var looksLikeCoolify: Bool {
        hasCoolifyDirectory || coolifyContainers.contains("coolify")
    }

    /// `ionice` is missing from many minimal images, so the prefix degrades to
    /// `nice` alone rather than failing the run.
    public var lowPriorityPrefix: [String] {
        var prefix: [String] = []
        if hasNice { prefix += ["nice", "-n", "19"] }
        if hasIonice { prefix += ["ionice", "-c3"] }
        return prefix
    }

    public var snapshotCapableMounts: [RemoteMount] {
        mounts.filter(\.supportsSnapshots)
    }
}

/// One round trip collects every fact: a probe per question would multiply ssh
/// latency across onboarding and every preflight.
enum RemoteFactsProbe {
    static let script = """
    echo "uname_m=$(uname -m 2>/dev/null)"
    echo "kernel=$(uname -r 2>/dev/null)"
    if [ -r /etc/os-release ]; then . /etc/os-release; fi
    echo "distro_id=${ID:-unknown}"
    echo "version_id=${VERSION_ID:-unknown}"
    echo "pretty_name=${PRETTY_NAME:-unknown}"
    echo "home=${HOME:-/root}"
    if command -v nice >/dev/null 2>&1; then echo "has_nice=1"; else echo "has_nice=0"; fi
    if command -v ionice >/dev/null 2>&1; then echo "has_ionice=1"; else echo "has_ionice=0"; fi
    if sudo -n true >/dev/null 2>&1; then echo "has_sudo=1"; else echo "has_sudo=0"; fi
    if [ -d /data/coolify ]; then echo "coolify_dir=1"; else echo "coolify_dir=0"; fi
    if [ -f /etc/hindsight-test-target ]; then echo "test_marker=1"; else echo "test_marker=0"; fi
    docker_version="$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
    if [ -z "$docker_version" ]; then
      docker_version="$(sudo -n docker version --format '{{.Server.Version}}' 2>/dev/null)"
    fi
    echo "docker_version=$docker_version"
    for name in $(docker ps --format '{{.Names}}' 2>/dev/null || sudo -n docker ps --format '{{.Names}}' 2>/dev/null); do
      echo "container=$name"
    done
    if command -v findmnt >/dev/null 2>&1; then
      findmnt -rno SOURCE,TARGET,FSTYPE 2>/dev/null | while read -r source target fstype; do
        echo "mount=$source	$target	$fstype"
      done
    fi
    if command -v ss >/dev/null 2>&1; then
      ss -H -ltn 2>/dev/null | awk '{print $4}' | sed 's/.*://' | while read -r port; do
        echo "port=$port"
      done
    fi
    """

    static func parse(_ output: String) throws -> RemoteFacts {
        var values: [String: String] = [:]
        var containers: [String] = []
        var mounts: [RemoteMount] = []
        var ports: Set<Int> = []

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<separator])
            let value = String(line[line.index(after: separator)...])
            switch key {
            case "container":
                if !value.isEmpty { containers.append(value) }
            case "mount":
                let fields = value.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                if fields.count == 3 {
                    mounts.append(RemoteMount(source: fields[0], target: fields[1], filesystem: fields[2]))
                }
            case "port":
                if let port = Int(value), (1...65535).contains(port) { ports.insert(port) }
            default:
                values[key] = value
            }
        }

        guard let machine = values["uname_m"], let architecture = Architecture(unameMachine: machine) else {
            throw SSHError.unexpectedProbeOutput(
                command: "uname -m",
                output: values["uname_m"] ?? "(no output)"
            )
        }

        let platform = Platform(
            distributionID: values["distro_id"] ?? "unknown",
            versionID: values["version_id"] ?? "unknown",
            prettyName: values["pretty_name"] ?? "unknown",
            kernelRelease: values["kernel"] ?? "unknown",
            architecture: architecture
        )

        let dockerVersion = values["docker_version"].flatMap { $0.isEmpty ? nil : $0 }

        return RemoteFacts(
            platform: platform,
            homeDirectory: values["home"] ?? "/root",
            hasPasswordlessSudo: values["has_sudo"] == "1",
            hasNice: values["has_nice"] == "1",
            hasIonice: values["has_ionice"] == "1",
            dockerServerVersion: dockerVersion,
            hasCoolifyDirectory: values["coolify_dir"] == "1",
            coolifyContainers: containers,
            hasTestMarker: values["test_marker"] == "1",
            mounts: mounts,
            listeningPorts: ports.sorted()
        )
    }
}
