import Foundation

/// Paths a full-server restore must not write unless asked to, and one it must
/// never write at all.
///
/// The categories exist because these failures are different in kind: writing
/// an old `/etc/fstab` or network configuration can leave a server that does
/// not boot or cannot be reached, which is worse than the problem the restore
/// was meant to fix.
public enum RestoreExclusions {
    public enum Category: String, Sendable, Hashable, Codable, CaseIterable {
        case bootloader
        case filesystemTable
        case networkConfiguration
        case sshHostKeys
        case authorizedKeys

        public var title: String {
            switch self {
            case .bootloader: "Boot files"
            case .filesystemTable: "Filesystem table"
            case .networkConfiguration: "Network configuration"
            case .sshHostKeys: "SSH host keys"
            case .authorizedKeys: "Authorised SSH keys"
            }
        }

        public var risk: String {
            switch self {
            case .bootloader:
                "Restoring old boot files can leave a server that does not start."
            case .filesystemTable:
                """
                An old filesystem table can reference disks that are no longer \
                there, which can stop the server from booting.
                """
            case .networkConfiguration:
                "An old network configuration can leave the server unreachable."
            case .sshHostKeys:
                """
                Replacing host keys makes every client, Hindsight included, \
                treat the server as a possible impostor until the new keys are \
                confirmed.
                """
            case .authorizedKeys:
                """
                Restoring old authorised keys can remove the key Hindsight and \
                you use to log in.
                """
            }
        }

        public var patterns: [String] {
            switch self {
            case .bootloader:
                ["/boot", "/boot/**"]
            case .filesystemTable:
                ["/etc/fstab", "/etc/crypttab", "/etc/mdadm/mdadm.conf"]
            case .networkConfiguration:
                [
                    "/etc/netplan", "/etc/netplan/**",
                    "/etc/NetworkManager", "/etc/NetworkManager/**",
                    "/etc/systemd/network", "/etc/systemd/network/**",
                    "/etc/network", "/etc/network/**",
                    "/etc/resolv.conf", "/etc/hostname", "/etc/hosts",
                ]
            case .sshHostKeys:
                ["/etc/ssh/ssh_host_*"]
            case .authorizedKeys:
                ["/root/.ssh/authorized_keys", "/home/*/.ssh/authorized_keys"]
            }
        }
    }

    /// The exclude patterns for a plan, honouring any deliberate opt-ins.
    public static func patterns(optedInto optedIn: Set<Category>) -> [String] {
        Category.allCases
            .filter { !optedIn.contains($0) }
            .flatMap(\.patterns)
    }

    public static func category(forPath path: String) -> Category? {
        Category.allCases.first { category in
            category.patterns.contains { matches(path: path, pattern: $0) }
        }
    }

    /// Categories whose paths live underneath one of the selected paths.
    ///
    /// This closes a bypass. `restic restore` refuses `--include` and
    /// `--exclude` in the same invocation (verified against 0.19.1: "exclude
    /// and include patterns are mutually exclusive"), so a restore scoped to
    /// `/etc` cannot also exclude `/etc/fstab`. Selecting a parent of something
    /// dangerous therefore has to be caught here rather than left to restic.
    public static func conflictingCategories(
        forIncludePaths includes: [String]
    ) -> [Category] {
        Category.allCases.filter { category in
            category.patterns.contains { pattern in
                let literal = literalPrefix(of: pattern)
                return includes.contains { include in
                    literal == include || literal.hasPrefix(include + "/")
                }
            }
        }
    }

    /// The part of a pattern before any wildcard, which is the deepest
    /// directory it can be known to live under.
    static func literalPrefix(of pattern: String) -> String {
        guard let wildcard = pattern.firstIndex(where: { $0 == "*" || $0 == "?" }) else { return pattern }
        let head = String(pattern[pattern.startIndex..<wildcard])
        guard let lastSlash = head.lastIndex(of: "/") else { return head }
        return String(head[head.startIndex..<lastSlash])
    }

    /// Glob matching with `*` confined to one path component and `**` spanning
    /// components, which is what restic's exclude patterns mean.
    public static func matches(path: String, pattern: String) -> Bool {
        if pattern.hasSuffix("/**") {
            let prefix = String(pattern.dropLast(3))
            return path == prefix || path.hasPrefix(prefix + "/")
        }
        return fnmatch(pattern, path, 0) == 0
    }
}

public enum RestoreSafetyError: Error, Hashable, Sendable, CustomStringConvertible {
    case wouldRemoveOwnAccess(path: String)
    case excludedWithoutOptIn(path: String, category: RestoreExclusions.Category)
    case selectionContainsExcludedPaths(path: String, categories: [RestoreExclusions.Category])
    case hostnameConfirmationRequired

    public var description: String {
        switch self {
        case let .wouldRemoveOwnAccess(path):
            """
            Refusing this restore: it would overwrite \(path), which is how \
            Hindsight reaches this server. Losing access during a restore is \
            the one failure that prevents its own repair, so this is never \
            allowed — not even with an opt-in.
            """
        case let .excludedWithoutOptIn(path, category):
            "\(path) is excluded as \(category.title.lowercased()). \(category.risk)"
        case let .selectionContainsExcludedPaths(path, categories):
            """
            \(path) contains paths Hindsight excludes by default: \
            \(categories.map(\.title).joined(separator: ", ")). restic cannot \
            restore a selected path while excluding part of it, so either \
            narrow the selection, or opt into those categories deliberately.
            """
        case .hostnameConfirmationRequired:
            "Type the server's hostname to confirm this restore."
        }
    }
}

/// The final check before anything is written.
public enum RestoreSafety {
    /// Refuses outright any plan that would overwrite the access Hindsight
    /// itself depends on.
    ///
    /// This is deliberately not an opt-in: `authorizedKeys` can be opted into
    /// as a category, but the specific file the current connection
    /// authenticates against still cannot be replaced, because a half-finished
    /// restore would leave no way back in.
    public static func check(
        plan: RestorePlan,
        pathsToWrite: [String]
    ) throws {
        guard plan.target.isInPlace else { return }

        // A selected path that contains something dangerous cannot be handled
        // by exclusions, because restic will not take both at once.
        if case .paths = plan.scope {
            let conflicts = RestoreExclusions
                .conflictingCategories(forIncludePaths: pathsToWrite)
                .filter { !plan.optedInExclusions.contains($0) }
            if let first = conflicts.first {
                let offending = pathsToWrite.first { path in
                    first.patterns.contains {
                        RestoreExclusions.literalPrefix(of: $0).hasPrefix(path)
                    }
                } ?? pathsToWrite[0]
                throw RestoreSafetyError.selectionContainsExcludedPaths(
                    path: offending,
                    categories: conflicts
                )
            }
        }

        for path in pathsToWrite {
            if RestoreExclusions.matches(path: path, pattern: plan.sshAuthorizedKeysPath)
                || path == plan.sshAuthorizedKeysPath {
                throw RestoreSafetyError.wouldRemoveOwnAccess(path: path)
            }
            if RestoreExclusions.matches(path: plan.sshAuthorizedKeysPath, pattern: path + "/**") {
                throw RestoreSafetyError.wouldRemoveOwnAccess(path: plan.sshAuthorizedKeysPath)
            }
            if let category = RestoreExclusions.category(forPath: path),
               !plan.optedInExclusions.contains(category) {
                throw RestoreSafetyError.excludedWithoutOptIn(path: path, category: category)
            }
        }
    }

    public static func confirmationMatches(_ typed: String, hostname: String) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
