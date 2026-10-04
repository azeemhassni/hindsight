import Foundation
import Testing
@testable import HindsightCore

@Suite("Retention policy")
struct RetentionPolicyTests {
    @Test("defaults are valid and match the documented grandfather-father-son policy")
    func defaults() {
        let policy = RetentionPolicy.filesystemDefault
        #expect(policy.keepWithinHours == 24)
        #expect(policy.keepDaily == 7)
        #expect(policy.keepWeekly == 4)
        #expect(policy.keepMonthly == 12)
        #expect(policy.keepYearly == 2)
    }

    @Test("a policy that keeps nothing is refused")
    func refusesEmptyPolicy() {
        #expect(throws: ValidationError.retentionKeepsNothing) {
            try RetentionPolicy(
                scope: .filesystem,
                keepWithinHours: 0,
                keepDaily: 0,
                keepWeekly: 0,
                keepMonthly: 0,
                keepYearly: 0
            )
        }
    }

    @Test("negative counts are refused")
    func refusesNegativeCounts() {
        #expect(throws: ValidationError.negativeRetentionCount("keep-daily", -1)) {
            try RetentionPolicy(
                scope: .filesystem,
                keepWithinHours: 24,
                keepDaily: -1,
                keepWeekly: 0,
                keepMonthly: 0,
                keepYearly: 0
            )
        }
    }

    @Test("dumps keep a different policy from the filesystem")
    func dumpScopeDiffers() {
        #expect(RetentionPolicy.databaseDumpsDefault.scope == .databaseDumps)
        #expect(RetentionPolicy.databaseDumpsDefault.keepDaily > RetentionPolicy.filesystemDefault.keepDaily)
    }
}

@Suite("Schedule")
struct ScheduleTests {
    @Test("hour intervals outside 1...24 are refused", arguments: [0, -1, 25, 48])
    func refusesBadInterval(_ hours: Int) {
        #expect(throws: ValidationError.invalidHourInterval(hours)) {
            try Schedule(cadence: .everyHours(hours))
        }
    }

    @Test("an unknown time zone is refused")
    func refusesUnknownTimeZone() {
        #expect(throws: ValidationError.unknownTimeZone("Mars/Olympus")) {
            try Schedule(cadence: .hourly, timeZoneIdentifier: "Mars/Olympus")
        }
    }

    @Test("a nil time zone resolves to the current one")
    func resolvesTimeZone() throws {
        #expect(try Schedule(cadence: .hourly).timeZone == TimeZone.current)
        #expect(try Schedule(cadence: .hourly, timeZoneIdentifier: "Europe/Berlin").timeZone.identifier == "Europe/Berlin")
    }

    @Test("times of day outside the clock are refused")
    func refusesBadTimeOfDay() {
        #expect(throws: (any Error).self) { try TimeOfDay(hour: 24, minute: 0) }
        #expect(throws: (any Error).self) { try TimeOfDay(hour: 0, minute: 60) }
        #expect(throws: (any Error).self) { try TimeOfDay(hour: -1, minute: 0) }
    }

    @Test("cron expressions are stored as typed, not normalised away")
    func keepsCronVerbatim() throws {
        let schedule = try Schedule(cadence: .cron("*/15 2 * * 1-5"))
        guard case let .cron(expression) = schedule.cadence else {
            Issue.record("expected a cron cadence")
            return
        }
        #expect(expression == "*/15 2 * * 1-5")
    }
}

@Suite("Backup profile")
struct BackupProfileTests {
    @Test("the full-server default covers every documented path")
    func fullServerDefault() {
        let profile = BackupProfile.fullServer
        for path in ["/etc", "/root", "/home", "/opt", "/srv", "/usr/local", "/var/lib/docker/volumes", "/var/spool/cron", "/data"] {
            #expect(profile.includePaths.contains(path), "missing include \(path)")
        }
        for path in ["/proc", "/sys", "/dev", "/run", "/tmp", "/var/cache", "/var/lib/docker/overlay2"] {
            #expect(profile.excludePatterns.contains(path), "missing exclude \(path)")
        }
        #expect(profile.oneFileSystem)
    }

    @Test("relative include paths are refused")
    func refusesRelativePaths() {
        #expect(throws: ValidationError.relativePath("etc")) {
            try BackupProfile(includePaths: ["etc"], excludePatterns: [])
        }
    }

    @Test("an empty include list is refused")
    func refusesEmptyIncludes() {
        #expect(throws: ValidationError.emptyIncludePaths) {
            try BackupProfile(includePaths: [], excludePatterns: [])
        }
    }

    @Test("a non-positive bandwidth limit is refused")
    func refusesBadBandwidth() {
        #expect(throws: ValidationError.invalidBandwidthLimit(0)) {
            try BackupProfile(includePaths: ["/etc"], excludePatterns: [], bandwidthLimitKiBPerSecond: 0)
        }
    }
}

@Suite("Server")
struct ServerTests {
    @Test("round-trips through Codable")
    func codableRoundTrip() throws {
        let server = try Server(
            id: ServerID(validating: "web-01"),
            name: "Web 01",
            endpoint: SSHEndpoint(host: "198.51.100.10", port: 2222, user: "root"),
            authentication: .existingKey(path: "/Users/me/.ssh/id_ed25519"),
            privilege: .root,
            platform: Platform(
                distributionID: "ubuntu",
                versionID: "24.04",
                prettyName: "Ubuntu 24.04 LTS",
                kernelRelease: "6.8.0-41-generic",
                architecture: .aarch64
            ),
            coolifyVersion: "4.3.23"
        )
        let decoded = try JSONDecoder().decode(Server.self, from: JSONEncoder().encode(server))
        #expect(decoded == server)
        #expect(decoded.isCoolifyServer)
    }

    @Test("rejects an invalid endpoint")
    func rejectsBadEndpoint() {
        #expect(throws: ValidationError.invalidPort(0)) { try SSHEndpoint(host: "h", port: 0, user: "root") }
        #expect(throws: ValidationError.emptySSHHost) { try SSHEndpoint(host: " ", user: "root") }
        #expect(throws: ValidationError.emptySSHUser) { try SSHEndpoint(host: "h", user: "") }
    }

    @Test("maps uname machine strings to architectures")
    func mapsArchitecture() {
        #expect(Architecture(unameMachine: "x86_64") == .x86_64)
        #expect(Architecture(unameMachine: "amd64") == .x86_64)
        #expect(Architecture(unameMachine: "aarch64\n") == .aarch64)
        #expect(Architecture(unameMachine: "arm64") == .aarch64)
        #expect(Architecture(unameMachine: "riscv64") == nil)
    }
}
