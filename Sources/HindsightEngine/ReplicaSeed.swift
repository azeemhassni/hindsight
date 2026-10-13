import Foundation
import HindsightCore

/// Builds the cloud-init seed that turns a fresh cloud image into a replica.
///
/// A snapshot holds no kernel and no bootloader, so no disk image can be built
/// from one taken with the default profile. What a snapshot *does* hold, in
/// its metadata, is everything needed to rebuild the machine: the package
/// selections, the enabled services, the containers and their images. So the
/// replica is made the other way round — boot the distribution's own cloud
/// image, let this seed put the same software on it, and then restore the data
/// onto it with Hindsight like any other server.
///
/// Deliberately not in the seed: the data. It is gigabytes, it is already in
/// the repository, and putting a repository password on a removable disk to
/// fetch it would be the worst place to keep one.
public struct ReplicaSeed: Sendable {
    /// What the metadata snapshot recorded about the machine being copied.
    public struct Source: Sendable {
        public var hostname: String
        public var osRelease: String
        public var packages: String
        public var systemdUnits: String
        public var dockerPresent: Bool
        public var sshUser: String
        /// Hindsight's own public key, so the replica is reachable the moment
        /// it boots and the data can be restored onto it.
        public var authorizedKey: String?

        public init(
            hostname: String,
            osRelease: String,
            packages: String,
            systemdUnits: String,
            dockerPresent: Bool,
            sshUser: String,
            authorizedKey: String?
        ) {
            self.hostname = hostname
            self.osRelease = osRelease
            self.packages = packages
            self.systemdUnits = systemdUnits
            self.dockerPresent = dockerPresent
            self.sshUser = sshUser
            self.authorizedKey = authorizedKey
        }
    }

    public struct Output: Sendable, Equatable {
        public var userData: String
        public var metaData: String
        /// Written onto the replica, and shown in the app: what this did, what
        /// it did not do, and what to do next.
        public var notes: String
        /// Things a person has to know rather than discover.
        public var warnings: [String]
    }

    public enum PackageFormat: Sendable, Equatable {
        case dpkg
        case rpm
        case unknown
    }

    /// `dpkg --get-selections` writes `name\tinstall`; `rpm -qa` writes one
    /// `name-version-release.arch` per line and no tabs.
    public static func packageFormat(of text: String) -> PackageFormat {
        let lines = text.split(separator: "\n").prefix(40)
        guard !lines.isEmpty else { return .unknown }
        if lines.contains(where: { $0.contains("\t") || $0.contains("install") }) { return .dpkg }
        if lines.contains(where: { $0.contains(".") && $0.contains("-") }) { return .rpm }
        return .unknown
    }

    /// The packages to install. Only those actually selected: the list also
    /// carries entries marked `deinstall`, and asking for those would install
    /// what the machine was deliberately without.
    public static func installablePackages(from text: String) -> [String] {
        guard packageFormat(of: text) == .dpkg else { return [] }
        var names: [String] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
                .map(String.init)
                .filter { !$0.isEmpty }
            guard fields.count >= 2, fields[1] == "install" else { continue }
            // `name:amd64` is the same package as `name`.
            names.append(fields[0].split(separator: ":").first.map(String.init) ?? fields[0])
        }
        return Array(Set(names)).sorted()
    }

    /// Unit names that were enabled, which is what decides what starts at boot.
    public static func enabledUnits(from text: String) -> [String] {
        var units: [String] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 2, fields[1] == "enabled" else { continue }
            // Templates cannot be enabled without an instance name.
            guard !fields[0].hasSuffix("@.service") else { continue }
            units.append(fields[0])
        }
        return units.sorted()
    }

    public static func value(_ key: String, inOSRelease text: String) -> String? {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == key else { continue }
            return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    public static func build(from source: Source, instanceID: String = UUID().uuidString) -> Output {
        var warnings: [String] = []
        let format = packageFormat(of: source.packages)
        let packages = installablePackages(from: source.packages)
        let units = enabledUnits(from: source.systemdUnits)
        let distribution = value("ID", inOSRelease: source.osRelease) ?? "unknown"
        let version = value("VERSION_ID", inOSRelease: source.osRelease) ?? "unknown"

        if format == .rpm {
            warnings.append("""
            This server uses rpm, and `rpm -qa` records each package with its \
            version, which cannot be installed by name. The list is in the \
            notes on the replica; the packages are not installed for you.
            """)
        } else if format == .unknown {
            warnings.append("No package list was recorded, so nothing is installed for you.")
        }
        if source.authorizedKey == nil {
            warnings.append("""
            Hindsight's public key was not available, so the replica will not \
            accept a restore until you add a key to it yourself.
            """)
        }
        warnings.append("""
        Packages are installed by name from \(distribution) \(version)'s own \
        repositories. Any that have since been removed from them will fail, \
        and cloud-init records which in /var/log/cloud-init-output.log.
        """)

        var lines = ["#cloud-config", "hostname: \(source.hostname)", "preserve_hostname: false"]
        if let key = source.authorizedKey {
            lines += [
                "users:",
                "  - name: \(source.sshUser)",
                "    ssh_authorized_keys:",
                "      - \(key)",
            ]
            if source.sshUser != "root" {
                lines += ["    sudo: ALL=(ALL) NOPASSWD:ALL", "    shell: /bin/bash"]
            }
        }
        if !packages.isEmpty {
            lines += ["package_update: true", "packages:"]
            lines += packages.map { "  - \($0)" }
        }

        var commands: [String] = []
        if source.dockerPresent {
            // From Docker's own convenience script rather than the
            // distribution's package, which is usually far behind.
            commands.append("curl -fsSL https://get.docker.com | sh")
        }
        commands += units.map { "systemctl enable \($0) || true" }
        if !commands.isEmpty {
            lines += ["runcmd:"]
            lines += commands.map { "  - \($0)" }
        }

        let notes = buildNotes(
            source: source,
            distribution: distribution,
            version: version,
            packages: packages,
            units: units,
            format: format,
            warnings: warnings
        )
        lines += [
            "write_files:",
            "  - path: /root/hindsight-replica.md",
            "    permissions: '0600'",
            "    content: |",
        ]
        lines += notes.split(separator: "\n", omittingEmptySubsequences: false).map { "      \($0)" }

        let metaData = """
        instance-id: \(instanceID)
        local-hostname: \(source.hostname)
        """
        return Output(
            userData: lines.joined(separator: "\n") + "\n",
            metaData: metaData + "\n",
            notes: notes,
            warnings: warnings
        )
    }

    private static func buildNotes(
        source: Source,
        distribution: String,
        version: String,
        packages: [String],
        units: [String],
        format: PackageFormat,
        warnings: [String]
    ) -> String {
        var text = """
        # Replica of \(source.hostname)

        Built by Hindsight from a backup's metadata. Boot this on a fresh
        \(distribution) \(version) cloud image.

        ## What this did

        - Set the hostname to \(source.hostname)
        - Installed \(packages.count) package(s) recorded on the original
        - Enabled \(units.count) systemd unit(s)
        """
        if source.dockerPresent {
            text += "\n- Installed Docker\n"
        } else {
            text += "\n"
        }
        text += """

        ## What this did NOT do

        **None of your data is here.** This seed rebuilds the machine, not its
        contents: no /srv, no /data, no home directories, no container volumes
        and no databases. A backup's metadata describes the machine; the data
        lives in the repository on the Mac, which is far too large to carry on
        a seed disk and would need the repository password to read.

        Restore it from Hindsight: open the server this was copied from, choose
        Restore, and pick this machine under "Where". It will ask you to type
        this machine's hostname and to confirm with Touch ID.

        Containers are not recreated. The original's `docker inspect` output is
        in the metadata snapshot, which the snapshot browser can read.

        ## Worth knowing

        """
        for warning in warnings {
            text += "- \(warning.replacingOccurrences(of: "\n", with: " "))\n"
        }
        return text
    }
}
