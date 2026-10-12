import Foundation
import HindsightTestSupport
import Testing

/// Fails when an environment the caller asked for is not actually there.
///
/// This exists because of a real near-miss: the Docker containers were stopped
/// by a hypervisor restart, every integration suite skipped, and the run still
/// reported success. A skipped test looks exactly like a passing one in a
/// summary line, which makes silence the most dangerous result a test can give.
///
/// `make test-integration` sets the flags below, so a
/// missing environment fails loudly instead of quietly proving nothing.
@Suite("Test environment presence")
struct EnvironmentPresenceTests {
    @Test(
        "the Docker environment is up when the caller said it should be",
        .enabled(if: ProcessInfo.processInfo.environment["HINDSIGHT_REQUIRE_TEST_ENV"] == "1")
    )
    func dockerEnvironmentIsPresent() {
        #expect(
            TestEnvironment.isAvailable,
            """
            HINDSIGHT_REQUIRE_TEST_ENV is set but the local Docker environment \
            is not reachable, so every integration test would have skipped. \
            Run scripts/testenv.sh up.
            """
        )
        #expect(
            TestEnvironment.allowsDestructiveOperations,
            """
            HINDSIGHT_ALLOW_DESTRUCTIVE_TESTS is not set, so the restore tests \
            would have skipped.
            """
        )
    }
}
