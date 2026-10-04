import Foundation
import HindsightSSH

/// A client that is never actually used: some tests only exercise pure logic
/// that happens to hang off a type which owns a connection.
func makeUnusedClient() -> SSHClient {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("hindsight-unused-\(UUID().uuidString)")
    return SSHClient(
        paths: SSHPaths(
            configurationDirectory: base.appendingPathComponent("ssh"),
            preferredControlDirectory: base.appendingPathComponent("cm")
        ),
        policy: NetworkPolicy(mode: .localTestTargetsOnly)
    )
}
