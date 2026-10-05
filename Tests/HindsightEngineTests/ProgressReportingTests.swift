import Foundation
import HindsightProtocol
import Testing

/// What a running backup tells the window.
///
/// Copying files is one phase of several, and only that phase has a
/// percentage. A bar left at 100% through the phases after it is how a backup
/// that was still dumping databases looked finished for four hours.
@Suite("Reporting a backup in progress")
struct ProgressReportingTests {
    private func job(phase: String?, percent: Double? = 1.0) -> RunningJob {
        RunningJob(
            id: "job-1",
            serverID: "web-01",
            kind: "backup",
            startedAt: Date(),
            percentDone: percent,
            bytesDone: 17_970_000_000,
            totalBytes: 17_970_000_000,
            phase: phase,
            detail: phase == "dumpingDatabases" ? "Dumping coolify-db (3 of 11)…" : nil
        )
    }

    @Test("shows a percentage only while files are being copied")
    func percentageBelongsToTheCopy() {
        #expect(job(phase: "backingUp").showsPercentage)
        #expect(!job(phase: "dumpingDatabases").showsPercentage)
        #expect(!job(phase: "recording").showsPercentage)
        // Before any phase has been reported there is nothing better to show.
        #expect(job(phase: nil).showsPercentage)
    }

    @Test("names the phase in words rather than in restic's")
    func namesThePhase() {
        #expect(job(phase: "dumpingDatabases").phaseLabel == "Dumping databases")
        #expect(job(phase: "backingUp").phaseLabel == "Copying files")
        #expect(job(phase: "verifyingBinary").phaseLabel.contains("restic"))
        #expect(job(phase: "somethingNew").phaseLabel == "Backing up")
    }

    @Test("carries the line that says what it is waiting on")
    func carriesTheDetail() {
        #expect(job(phase: "dumpingDatabases").detail?.contains("3 of 11") == true)
    }

    @Test("survives the trip over the protocol")
    func encodesAndDecodes() throws {
        let original = job(phase: "dumpingDatabases")
        let decoded = try AgentCoding.decode(
            RunningJob.self,
            from: try AgentCoding.encode(original)
        )
        // Field by field: a date loses its fractions through JSON, and that
        // difference says nothing about whether the phase survived.
        #expect(decoded.phase == original.phase)
        #expect(decoded.detail == original.detail)
        #expect(decoded.percentDone == original.percentDone)
        #expect(decoded.bytesDone == original.bytesDone)
        #expect(decoded.showsPercentage == original.showsPercentage)
    }
}
