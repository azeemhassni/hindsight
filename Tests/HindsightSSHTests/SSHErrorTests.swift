import Foundation
import HindsightCore
import HindsightProcess
import Testing
@testable import HindsightSSH

@Suite("Telling an unknown host key from a changed one")
struct HostKeyErrorInterpretationTests {
    private func interpret(_ stderr: String) -> any Error {
        SSHClient.interpret(
            .exitedWithFailure(
                command: "ssh",
                exit: ProcessExit(terminationStatus: 255, uncaughtSignal: nil, duration: .zero),
                standardError: stderr
            ),
            host: "127.0.0.1"
        )
    }

    /// ssh's own wording for a server it has never seen. Reporting this as a
    /// changed key tells someone their connection may be intercepted when in
    /// fact nothing has been recorded yet — alarming and wrong.
    @Test("an unrecorded key is reported as unknown, not as changed")
    func unknownKeyIsNotChanged() {
        let error = interpret(
            """
            No ED25519 host key is known for [127.0.0.1]:2222 and you have requested strict checking.
            Host key verification failed.
            """
        )
        guard case SSHError.hostKeyUnknown = error else {
            Issue.record("expected hostKeyUnknown, got \(error)")
            return
        }
        #expect("\(error)".contains("Confirm the server's fingerprint"))
    }

    @Test("a changed key still says so, in the strongest terms")
    func changedKeyIsReportedAsChanged() {
        let error = interpret(
            """
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            Host key verification failed.
            """
        )
        guard case SSHError.hostKeyChanged = error else {
            Issue.record("expected hostKeyChanged, got \(error)")
            return
        }
        #expect("\(error)".contains("intercepted"))
    }
}
