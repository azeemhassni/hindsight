import Foundation
import HindsightCore
import HindsightRestic
import HindsightSSH
import Testing
@testable import HindsightRestore

private func facts(hasTestMarker: Bool) -> RemoteFacts {
    RemoteFacts(
        platform: Platform(
            distributionID: "ubuntu", versionID: "24.04", prettyName: "Ubuntu",
            kernelRelease: "6.8", architecture: .aarch64
        ),
        homeDirectory: "/root",
        hasPasswordlessSudo: false,
        hasNice: true,
        hasIonice: true,
        hasBash: true,
        dockerServerVersion: nil,
        containerNames: [],
        hasTestMarker: hasTestMarker,
        mounts: [],
        listeningPorts: [22]
    )
}

private func destination(host: String) throws -> SSHDestination {
    SSHDestination(
        serverID: try ServerID(validating: "target"),
        host: host,
        port: 22,
        user: "root",
        identityFile: "/tmp/key",
        privilege: .root
    )
}

/// The guard that keeps tests away from real servers.
///
/// This is the suite the whole safety story rests on, so it checks both halves
/// of the rule independently: a local address is not enough, and the marker
/// file is not enough.
@Suite("Destructive operation guard")
struct DestructiveOperationGuardTests {
    @Test(
        "refuses a routable address even when it carries the marker",
        arguments: ["198.51.100.10", "203.0.113.7", "my-server.example.com", "8.8.8.8"]
    )
    func refusesRemoteHosts(_ host: String) throws {
        // A real server could have the marker file by accident, or because
        // somebody copied an image. The address check is what stops that.
        #expect(throws: DestructiveOperationError.targetIsNotLocal(host)) {
            try DestructiveOperationPolicy.localTestTargetOnly.authorize(
                try destination(host: host),
                facts: facts(hasTestMarker: true)
            )
        }
    }

    @Test(
        "refuses a local address without the marker",
        arguments: ["127.0.0.1", "localhost", "192.168.1.50", "172.17.0.2", "testbox.orb.local"]
    )
    func refusesUnmarkedLocalHosts(_ host: String) throws {
        // Someone's own machine, or a local VM that matters, is local but is
        // not a throwaway test target.
        #expect(throws: DestructiveOperationError.self) {
            try DestructiveOperationPolicy.localTestTargetOnly.authorize(
                try destination(host: host),
                facts: facts(hasTestMarker: false)
            )
        }
    }

    @Test("admits a local address that carries the marker")
    func admitsMarkedLocalHosts() throws {
        for host in ["127.0.0.1", "localhost", "192.168.139.204"] {
            #expect(throws: Never.self) {
                try DestructiveOperationPolicy.localTestTargetOnly.authorize(
                    try destination(host: host),
                    facts: facts(hasTestMarker: true)
                )
            }
        }
    }

    @Test("names the marker file in its refusal, so the reason is actionable")
    func explainsItsRefusal() throws {
        do {
            try DestructiveOperationPolicy.localTestTargetOnly.authorize(
                try destination(host: "127.0.0.1"),
                facts: facts(hasTestMarker: false)
            )
            Issue.record("expected a refusal")
        } catch let error as DestructiveOperationError {
            #expect("\(error)".contains("/etc/hindsight-test-target"))
        }
    }

    @Test("the production policy requires the hostname to be typed exactly")
    func requiresTypedHostname() throws {
        let target = try destination(host: "web-01.example.com")

        #expect(throws: Never.self) {
            try DestructiveOperationPolicy.userConfirmedHostname("web-01.example.com")
                .authorize(target, facts: facts(hasTestMarker: false))
        }
        // Whitespace and case are forgiven; a different name is not.
        #expect(throws: Never.self) {
            try DestructiveOperationPolicy.userConfirmedHostname("  WEB-01.EXAMPLE.COM ")
                .authorize(target, facts: facts(hasTestMarker: false))
        }
        #expect(throws: DestructiveOperationError.self) {
            try DestructiveOperationPolicy.userConfirmedHostname("web-02.example.com")
                .authorize(target, facts: facts(hasTestMarker: false))
        }
        #expect(throws: DestructiveOperationError.self) {
            try DestructiveOperationPolicy.userConfirmedHostname("")
                .authorize(target, facts: facts(hasTestMarker: false))
        }
    }

    @Test("a local test target is never admitted by hostname confirmation alone")
    func hostnameConfirmationIsNotTheTestPath() throws {
        // The two policies are separate on purpose: a test can only construct
        // the local-only one, so no amount of typing lets a test write to a
        // real host.
        let production = DestructiveOperationPolicy.userConfirmedHostname("127.0.0.1")
        #expect(production != .localTestTargetOnly)
    }
}

@Suite("Restore exclusions")
struct RestoreExclusionTests {
    @Test("excludes every dangerous category by default")
    func excludesByDefault() {
        let patterns = RestoreExclusions.patterns(optedInto: [])
        #expect(patterns.contains("/boot"))
        #expect(patterns.contains("/etc/fstab"))
        #expect(patterns.contains("/etc/netplan"))
        #expect(patterns.contains("/etc/ssh/ssh_host_*"))
        #expect(patterns.contains("/root/.ssh/authorized_keys"))
    }

    @Test("honours a deliberate opt-in, and only for that category")
    func honoursOptIn() {
        let patterns = RestoreExclusions.patterns(optedInto: [.bootloader])
        #expect(!patterns.contains("/boot"))
        // The others stay excluded.
        #expect(patterns.contains("/etc/fstab"))
        #expect(patterns.contains("/etc/ssh/ssh_host_*"))
    }

    @Test(
        "recognises which category a path falls into",
        arguments: [
            ("/boot/vmlinuz", RestoreExclusions.Category.bootloader),
            ("/boot", RestoreExclusions.Category.bootloader),
            ("/etc/fstab", RestoreExclusions.Category.filesystemTable),
            ("/etc/netplan/01-net.yaml", RestoreExclusions.Category.networkConfiguration),
            ("/etc/resolv.conf", RestoreExclusions.Category.networkConfiguration),
            ("/etc/ssh/ssh_host_ed25519_key", RestoreExclusions.Category.sshHostKeys),
            ("/root/.ssh/authorized_keys", RestoreExclusions.Category.authorizedKeys),
            ("/home/deploy/.ssh/authorized_keys", RestoreExclusions.Category.authorizedKeys),
        ]
    )
    func categorisesPaths(_ example: (String, RestoreExclusions.Category)) {
        #expect(RestoreExclusions.category(forPath: example.0) == example.1)
    }

    @Test("leaves ordinary paths alone")
    func leavesOrdinaryPathsAlone() {
        for path in ["/etc/nginx/nginx.conf", "/srv/app", "/var/lib/docker/volumes/data", "/home/deploy/app"] {
            #expect(RestoreExclusions.category(forPath: path) == nil, "\(path) should not be excluded")
        }
    }

    @Test("explains the risk behind every category, for the UI to show")
    func explainsEveryRisk() {
        for category in RestoreExclusions.Category.allCases {
            #expect(!category.risk.isEmpty)
            #expect(!category.title.isEmpty)
            #expect(!category.patterns.isEmpty)
        }
        #expect(RestoreExclusions.Category.networkConfiguration.risk.contains("unreachable"))
        #expect(RestoreExclusions.Category.bootloader.risk.contains("does not start"))
    }

    @Test("matches a directory pattern against the directory itself and its contents")
    func matchesGlobs() {
        #expect(RestoreExclusions.matches(path: "/boot", pattern: "/boot/**"))
        #expect(RestoreExclusions.matches(path: "/boot/grub/grub.cfg", pattern: "/boot/**"))
        #expect(!RestoreExclusions.matches(path: "/bootstrap", pattern: "/boot/**"))
        #expect(RestoreExclusions.matches(path: "/etc/ssh/ssh_host_rsa_key", pattern: "/etc/ssh/ssh_host_*"))
        #expect(!RestoreExclusions.matches(path: "/etc/ssh/sshd_config", pattern: "/etc/ssh/ssh_host_*"))
    }
}

@Suite("Restore safety check")
struct RestoreSafetyCheckTests {
    private func plan(
        scope: RestoreScope = .fullServer,
        target: RestoreTarget = .inPlace,
        optedIn: Set<RestoreExclusions.Category> = []
    ) -> RestorePlan {
        RestorePlan(
            snapshotID: SnapshotID(unchecked: "aa11"),
            scope: scope,
            target: target,
            mode: .standard,
            optedInExclusions: optedIn,
            serverHostname: "web-01",
            sshAuthorizedKeysPath: "/root/.ssh/authorized_keys"
        )
    }

    @Test("refuses to overwrite the key Hindsight logs in with, even with the opt-in")
    func neverOverwritesOwnAccess() {
        // The category can be opted into, but the specific file this connection
        // authenticates against still cannot be replaced: a restore that locks
        // Hindsight out cannot be undone by Hindsight.
        #expect(throws: RestoreSafetyError.wouldRemoveOwnAccess(path: "/root/.ssh/authorized_keys")) {
            try RestoreSafety.check(
                plan: plan(optedIn: [.authorizedKeys]),
                pathsToWrite: ["/root/.ssh/authorized_keys"]
            )
        }
    }

    @Test("refuses a parent directory that would take the key with it")
    func refusesParentOfOwnAccess() {
        #expect(throws: RestoreSafetyError.self) {
            try RestoreSafety.check(
                plan: plan(optedIn: [.authorizedKeys]),
                pathsToWrite: ["/root/.ssh"]
            )
        }
    }

    @Test("refuses an excluded path that was not opted into")
    func refusesExcludedPaths() {
        #expect(throws: RestoreSafetyError.excludedWithoutOptIn(
            path: "/etc/fstab",
            category: .filesystemTable
        )) {
            try RestoreSafety.check(plan: plan(), pathsToWrite: ["/etc/fstab"])
        }
    }

    @Test("allows an excluded path once it has been opted into")
    func allowsOptedInPaths() {
        #expect(throws: Never.self) {
            try RestoreSafety.check(
                plan: plan(optedIn: [.filesystemTable]),
                pathsToWrite: ["/etc/fstab"]
            )
        }
    }

    @Test("allows ordinary paths")
    func allowsOrdinaryPaths() {
        #expect(throws: Never.self) {
            try RestoreSafety.check(
                plan: plan(),
                pathsToWrite: ["/srv/app", "/var/lib/docker/volumes/app-data", "/etc/nginx"]
            )
        }
    }

    @Test("does not apply the in-place rules to a restore somewhere else")
    func skipsChecksForAlternatePath() {
        // Restoring /etc/fstab into /tmp/inspect harms nothing.
        #expect(throws: Never.self) {
            try RestoreSafety.check(
                plan: plan(target: .alternatePath("/tmp/inspect")),
                pathsToWrite: ["/etc/fstab", "/root/.ssh/authorized_keys"]
            )
        }
    }

    @Test("compares the typed hostname forgivingly but not loosely")
    func comparesHostname() {
        #expect(RestoreSafety.confirmationMatches("web-01", hostname: "web-01"))
        #expect(RestoreSafety.confirmationMatches(" WEB-01 ", hostname: "web-01"))
        #expect(!RestoreSafety.confirmationMatches("web-0", hostname: "web-01"))
        #expect(!RestoreSafety.confirmationMatches("", hostname: "web-01"))
    }
}

@Suite("Selections that contain excluded paths")
struct RestoreSelectionConflictTests {
    private func plan(
        paths: [String],
        optedIn: Set<RestoreExclusions.Category> = []
    ) -> RestorePlan {
        RestorePlan(
            snapshotID: SnapshotID(unchecked: "aa11"),
            scope: .paths(paths),
            target: .inPlace,
            mode: .standard,
            optedInExclusions: optedIn,
            serverHostname: "web-01"
        )
    }

    @Test("refuses /etc, because it contains the filesystem table and host keys")
    func refusesSelectingEtc() {
        // restic will not restore a selected path while excluding part of it,
        // so a selection of /etc would quietly bring back fstab and host keys.
        #expect(throws: RestoreSafetyError.self) {
            try RestoreSafety.check(plan: plan(paths: ["/etc"]), pathsToWrite: ["/etc"])
        }
    }

    @Test("names every category in the way, so the message is actionable")
    func namesTheCategories() throws {
        do {
            try RestoreSafety.check(plan: plan(paths: ["/etc"]), pathsToWrite: ["/etc"])
            Issue.record("expected a refusal")
        } catch let error as RestoreSafetyError {
            guard case let .selectionContainsExcludedPaths(_, categories) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(categories.contains(.filesystemTable))
            #expect(categories.contains(.networkConfiguration))
            #expect(categories.contains(.sshHostKeys))
            #expect("\(error)".contains("narrow the selection"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("allows it once those categories are opted into")
    func allowsWithOptIn() {
        #expect(throws: Never.self) {
            try RestoreSafety.check(
                plan: plan(
                    paths: ["/etc"],
                    optedIn: [.filesystemTable, .networkConfiguration, .sshHostKeys]
                ),
                pathsToWrite: ["/etc"]
            )
        }
    }

    @Test("allows a selection with nothing dangerous under it")
    func allowsSafeSelections() {
        for path in ["/srv/app", "/var/lib/docker/volumes/data", "/etc/nginx", "/opt"] {
            #expect(throws: Never.self, "\(path) should be restorable") {
                try RestoreSafety.check(plan: plan(paths: [path]), pathsToWrite: [path])
            }
        }
    }

    @Test("refuses /root and /home, which hold authorised keys")
    func refusesHomeDirectories() {
        #expect(throws: RestoreSafetyError.self) {
            try RestoreSafety.check(plan: plan(paths: ["/root"]), pathsToWrite: ["/root"])
        }
        #expect(throws: RestoreSafetyError.self) {
            try RestoreSafety.check(plan: plan(paths: ["/home"]), pathsToWrite: ["/home"])
        }
    }

    @Test("finds the literal directory a pattern lives under")
    func findsLiteralPrefix() {
        #expect(RestoreExclusions.literalPrefix(of: "/etc/fstab") == "/etc/fstab")
        #expect(RestoreExclusions.literalPrefix(of: "/etc/ssh/ssh_host_*") == "/etc/ssh")
        #expect(RestoreExclusions.literalPrefix(of: "/home/*/.ssh/authorized_keys") == "/home")
        #expect(RestoreExclusions.literalPrefix(of: "/boot/**") == "/boot")
    }
}

@Suite("The guard cannot be bypassed")
struct GuardCannotBeBypassedTests {
    /// This suite exists to fail loudly if someone widens the guard.
    ///
    /// It is in the always-run unit tests, not the integration suite, so it
    /// cannot be skipped by a missing environment: a regression here fails the
    /// build rather than quietly disabling the protection.
    @Test("the executor refuses a restore against a host that is not a local test target")
    func executorRefusesNonLocalTargets() throws {
        let executor = RestoreExecutor(
            client: makeThrowawayClient(),
            binaryStore: BinaryStore(directory: URL(fileURLWithPath: "/nonexistent")),
            locks: RepositoryLockManager(),
            policy: .localTestTargetOnly
        )

        for host in ["198.51.100.10", "backup.example.com", "1.1.1.1"] {
            #expect(throws: RestoreExecutionError.self, "\(host) must be refused") {
                try executor.authorize(
                    facts: markedFacts(),
                    destination: try remoteDestination(host: host)
                )
            }
        }
    }

    @Test("there is no policy case that skips the checks")
    func policyHasNoEscapeHatch() {
        // If a third case appears — "unchecked", "force", or similar — this
        // test is where that decision has to be argued for.
        let localOnly = DestructiveOperationPolicy.localTestTargetOnly
        let confirmed = DestructiveOperationPolicy.userConfirmedHostname("web-01")

        switch localOnly {
        case .localTestTargetOnly, .userConfirmedHostname:
            break
        }
        #expect(localOnly != confirmed)
    }

    @Test("a marked local target is still accepted, so the guard is not simply off")
    func localTargetsStillWork() throws {
        let executor = RestoreExecutor(
            client: makeThrowawayClient(),
            binaryStore: BinaryStore(directory: URL(fileURLWithPath: "/nonexistent")),
            locks: RepositoryLockManager(),
            policy: .localTestTargetOnly
        )
        #expect(throws: Never.self) {
            try executor.authorize(
                facts: markedFacts(),
                destination: try remoteDestination(host: "127.0.0.1")
            )
        }
    }
}

private func markedFacts() -> RemoteFacts {
    RemoteFacts(
        platform: Platform(
            distributionID: "ubuntu", versionID: "24.04", prettyName: "Ubuntu",
            kernelRelease: "6.8", architecture: .aarch64
        ),
        homeDirectory: "/root",
        hasPasswordlessSudo: false,
        hasNice: true,
        hasIonice: true,
        hasBash: true,
        dockerServerVersion: nil,
        containerNames: [],
        hasTestMarker: true,
        mounts: [],
        listeningPorts: [22]
    )
}

private func remoteDestination(host: String) throws -> SSHDestination {
    SSHDestination(
        serverID: try ServerID(validating: "target"),
        host: host,
        port: 22,
        user: "root",
        identityFile: "/tmp/key",
        privilege: .root
    )
}

private func makeThrowawayClient() -> SSHClient {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("hindsight-guard-\(UUID().uuidString)")
    return SSHClient(
        paths: SSHPaths(
            configurationDirectory: base.appendingPathComponent("ssh"),
            preferredControlDirectory: base.appendingPathComponent("cm")
        ),
        policy: NetworkPolicy(mode: .localTestTargetsOnly)
    )
}
