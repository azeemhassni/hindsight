import Testing
@testable import HindsightSSH

@Suite("Network policy")
struct NetworkPolicyTests {
    @Test(
        "treats loopback, private, and local virtual-machine addresses as local",
        arguments: [
            "127.0.0.1", "127.1.2.3", "localhost", "LOCALHOST", "::1",
            "10.0.0.5", "172.17.0.2", "172.31.255.254", "192.168.1.10",
            "198.19.249.2", "100.64.0.1", "ubuntu.orb.local", "db.internal",
        ]
    )
    func recognisesLocalAddresses(_ host: String) {
        #expect(NetworkPolicy.isLocalTestAddress(host))
    }

    @Test(
        "treats routable addresses and real hostnames as remote",
        arguments: [
            "198.51.100.10", "8.8.8.8", "172.32.0.1", "172.15.0.1",
            "example.com", "vps.my-server.net", "1.1.1.1", "", "999.1.1.1",
        ]
    )
    func recognisesRemoteAddresses(_ host: String) {
        #expect(!NetworkPolicy.isLocalTestAddress(host))
    }

    @Test("a local-only build refuses a routable host before any network traffic")
    func refusesRemoteHost() {
        let policy = NetworkPolicy(mode: .localTestTargetsOnly)
        #expect(throws: SSHError.hostNotPermittedInThisBuild("198.51.100.10")) {
            try policy.check(host: "198.51.100.10")
        }
        #expect(throws: Never.self) { try policy.check(host: "127.0.0.1") }
    }

    @Test("an explicit allowlist overrides the restriction")
    func honoursAllowlist() {
        let policy = NetworkPolicy(
            mode: .localTestTargetsOnly,
            explicitlyAllowedHosts: ["staging.example.com"]
        )
        #expect(throws: Never.self) { try policy.check(host: "staging.example.com") }
        #expect(throws: SSHError.self) { try policy.check(host: "other.example.com") }
    }

    @Test("an unrestricted policy allows anything, which is what shipping builds do")
    func unrestrictedAllowsAnything() {
        #expect(throws: Never.self) { try NetworkPolicy.unrestricted.check(host: "198.51.100.10") }
    }

    @Test("test builds default to local targets only")
    func testBuildsAreRestricted() {
        // This suite runs in a debug build, which is exactly the configuration
        // the guard exists for.
        #expect(NetworkPolicy.fromEnvironment([:]).mode == .localTestTargetsOnly)
    }

    @Test("reads the allowlist from the environment")
    func readsAllowlistFromEnvironment() {
        let policy = NetworkPolicy.fromEnvironment(["HINDSIGHT_SSH_ALLOW_HOSTS": "a.example, b.example ,"])
        #expect(policy.explicitlyAllowedHosts == ["a.example", "b.example"])
    }
}
