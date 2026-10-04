import Foundation
import HindsightCore
import HindsightProcess
import Testing
@testable import HindsightSSH

@Suite("Remote facts")
struct RemoteFactsTests {
    static let ubuntuOutput = """
    uname_m=aarch64
    kernel=6.8.0-41-generic
    distro_id=ubuntu
    version_id=24.04
    pretty_name=Ubuntu 24.04.1 LTS
    home=/root
    has_nice=1
    has_ionice=1
    has_bash=1
    has_sudo=0
    coolify_dir=1
    test_marker=1
    docker_version=27.3.1
    container=coolify
    container=coolify-db
    container=coolify-proxy
    mount=/dev/vda1\t/\text4
    mount=/dev/mapper/vg0-data\t/data\text4
    mount=tank/srv\t/srv\tzfs
    port=22
    port=5432
    port=22
    """

    @Test("parses a full probe")
    func parsesFullProbe() throws {
        let facts = try RemoteFactsProbe.parse(Self.ubuntuOutput)
        #expect(facts.platform.architecture == .aarch64)
        #expect(facts.platform.distributionID == "ubuntu")
        #expect(facts.platform.versionID == "24.04")
        #expect(facts.platform.prettyName == "Ubuntu 24.04.1 LTS")
        #expect(facts.platform.kernelRelease == "6.8.0-41-generic")
        #expect(facts.homeDirectory == "/root")
        #expect(facts.hasNice)
        #expect(facts.hasIonice)
        #expect(facts.hasBash)
        #expect(!facts.hasPasswordlessSudo)
        #expect(facts.dockerServerVersion == "27.3.1")
        #expect(facts.hasDocker)
        #expect(facts.hasCoolifyDirectory)
        #expect(facts.looksLikeCoolify)
        #expect(facts.hasTestMarker)
        #expect(facts.coolifyContainers == ["coolify", "coolify-db", "coolify-proxy"])
        #expect(facts.mounts.count == 3)
        #expect(facts.listeningPorts == [22, 5432])
    }

    @Test("identifies which mounts can be snapshotted")
    func identifiesSnapshotCapableMounts() throws {
        let facts = try RemoteFactsProbe.parse(Self.ubuntuOutput)
        let targets = facts.snapshotCapableMounts.map(\.target).sorted()
        #expect(targets == ["/data", "/srv"])
    }

    @Test("degrades the priority prefix when ionice is missing")
    func degradesPriorityPrefix() throws {
        let withBoth = try RemoteFactsProbe.parse(Self.ubuntuOutput)
        #expect(withBoth.lowPriorityPrefix == ["nice", "-n", "19", "ionice", "-c3"])

        let withoutIonice = try RemoteFactsProbe.parse(
            Self.ubuntuOutput.replacingOccurrences(of: "has_ionice=1", with: "has_ionice=0")
        )
        #expect(withoutIonice.lowPriorityPrefix == ["nice", "-n", "19"])

        let withNeither = try RemoteFactsProbe.parse(
            Self.ubuntuOutput
                .replacingOccurrences(of: "has_ionice=1", with: "has_ionice=0")
                .replacingOccurrences(of: "has_nice=1", with: "has_nice=0")
        )
        #expect(withNeither.lowPriorityPrefix.isEmpty)
    }

    @Test("treats an empty docker version as no docker")
    func noDocker() throws {
        let facts = try RemoteFactsProbe.parse(
            Self.ubuntuOutput.replacingOccurrences(of: "docker_version=27.3.1", with: "docker_version=")
        )
        #expect(facts.dockerServerVersion == nil)
        #expect(!facts.hasDocker)
    }

    @Test("fails loudly on an architecture it has no restic build for")
    func failsOnUnknownArchitecture() {
        #expect(throws: SSHError.self) {
            try RemoteFactsProbe.parse(
                Self.ubuntuOutput.replacingOccurrences(of: "uname_m=aarch64", with: "uname_m=riscv64")
            )
        }
    }

    @Test("round-trips through Codable so a probe can be cached in the catalog")
    func codableRoundTrip() throws {
        let facts = try RemoteFactsProbe.parse(Self.ubuntuOutput)
        let decoded = try JSONDecoder().decode(RemoteFacts.self, from: JSONEncoder().encode(facts))
        #expect(decoded == facts)
    }

    @Test("probes everything in one round trip")
    func probeIsASingleScript() {
        // Latency, not elegance: a probe per question would multiply the cost of
        // onboarding and of every preflight.
        for expected in ["uname -m", "os-release", "sudo -n true", "hindsight-test-target", "findmnt"] {
            #expect(RemoteFactsProbe.script.contains(expected), "probe is missing \(expected)")
        }
    }
}

@Suite("Host keys")
struct HostKeyTests {
    @Test("parses ssh-keyscan output and ignores its comments")
    func parsesKeyscanOutput() {
        let line = "[127.0.0.1]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIabcdef"
        let key = HostKey.parse(keyscanLine: line)
        #expect(key?.host == "[127.0.0.1]:2222")
        #expect(key?.keyType == "ssh-ed25519")
        #expect(key?.base64Key == "AAAAC3NzaC1lZDI1NTE5AAAAIabcdef")
        #expect(HostKey.parse(keyscanLine: "# 127.0.0.1:2222 SSH-2.0-OpenSSH_9.6") == nil)
        #expect(HostKey.parse(keyscanLine: "") == nil)
        #expect(HostKey.parse(keyscanLine: "incomplete line") == nil)
    }

    @Test("extracts the SHA256 fingerprint ssh-keygen prints")
    func parsesFingerprint() {
        let output = "256 SHA256:7BkKpQvZ8Qp3h8xVX4h0Yw7ZqFn3b2k root@host (ED25519)"
        #expect(HostKey.parseFingerprint(output) == "SHA256:7BkKpQvZ8Qp3h8xVX4h0Yw7ZqFn3b2k")
        #expect(HostKey.parseFingerprint("no fingerprint here") == nil)
    }

    @Test("prefers ed25519 over the older key types")
    func ranksKeyTypes() {
        let keys = ["ssh-rsa", "ssh-ed25519", "ecdsa-sha2-nistp256"].map {
            HostKey(host: "h", keyType: $0, base64Key: "k", fingerprint: "f")
        }
        let ordered = keys.sorted { $0.preferenceRank < $1.preferenceRank }.map(\.keyType)
        #expect(ordered == ["ssh-ed25519", "ecdsa-sha2-nistp256", "ssh-rsa"])
    }

    @Test("renders a known_hosts line")
    func rendersKnownHostsLine() {
        let key = HostKey(host: "[127.0.0.1]:2222", keyType: "ssh-ed25519", base64Key: "AAAA", fingerprint: "SHA256:x")
        #expect(key.knownHostsLine == "[127.0.0.1]:2222 ssh-ed25519 AAAA")
    }
}

@Suite("SSH failure interpretation")
struct SSHFailureTests {
    private func failure(_ standardError: String, status: Int32 = 255) -> ProcessErrorStub {
        ProcessErrorStub(standardError: standardError, status: status)
    }

    struct ProcessErrorStub {
        let standardError: String
        let status: Int32
    }

    @Test("recognises a changed host key as a hard failure")
    func recognisesChangedHostKey() {
        let stub = failure("@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@")
        let mapped = SSHClient.interpret(
            .exitedWithFailure(
                command: "ssh",
                exit: ProcessExit(terminationStatus: stub.status, uncaughtSignal: nil, duration: .zero),
                standardError: stub.standardError
            ),
            host: "web-01"
        )
        guard case SSHError.hostKeyChanged = mapped else {
            Issue.record("expected hostKeyChanged, got \(mapped)")
            return
        }
        #expect("\(mapped)".contains("intercepted"))
    }

    @Test("recognises host key verification failure")
    func recognisesVerificationFailure() {
        let mapped = SSHClient.interpret(
            .exitedWithFailure(
                command: "ssh",
                exit: ProcessExit(terminationStatus: 255, uncaughtSignal: nil, duration: .zero),
                standardError: "Host key verification failed."
            ),
            host: "web-01"
        )
        guard case SSHError.hostKeyChanged = mapped else {
            Issue.record("expected hostKeyChanged, got \(mapped)")
            return
        }
    }

    @Test("recognises a rejected key")
    func recognisesAuthFailure() {
        let mapped = SSHClient.interpret(
            .exitedWithFailure(
                command: "ssh",
                exit: ProcessExit(terminationStatus: 255, uncaughtSignal: nil, duration: .zero),
                standardError: "root@127.0.0.1: Permission denied (publickey)."
            ),
            host: "web-01"
        )
        guard case SSHError.authenticationFailed = mapped else {
            Issue.record("expected authenticationFailed, got \(mapped)")
            return
        }
    }

    @Test("passes a remote command's own exit status through unchanged")
    func passesThroughRemoteFailure() {
        let original = ProcessError.exitedWithFailure(
            command: "ssh",
            exit: ProcessExit(terminationStatus: 3, uncaughtSignal: nil, duration: .zero),
            standardError: "restic: repository is already locked"
        )
        let mapped = SSHClient.interpret(original, host: "web-01")
        #expect(mapped as? ProcessError == original)
    }

    @Test("parses the port sshd allocated for a reverse forward")
    func parsesAllocatedPort() {
        #expect(SSHClient.parseAllocatedPort("54321\n") == 54321)
        #expect(SSHClient.parseAllocatedPort("Allocated port 54321 for remote forward to 127.0.0.1:8000") == 54321)
        #expect(SSHClient.parseAllocatedPort("") == nil)
        #expect(SSHClient.parseAllocatedPort("no port here") == nil)
        #expect(SSHClient.parseAllocatedPort("99999") == nil)
    }
}
