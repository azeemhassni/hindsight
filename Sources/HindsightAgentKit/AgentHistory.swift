import Foundation
import HindsightCatalog
import HindsightCore
import HindsightProtocol

/// Job history, as the interface reads it.
extension AgentCore {
    func jobHistory(serverID: String, limit: Int) -> AgentResponse {
        guard let id = try? ServerID(validating: serverID) else {
            return .failed(message: "Not a server id: \(serverID).")
        }
        guard let records = try? catalog.jobs(forServer: id, limit: max(1, min(limit, 500))) else {
            return .failed(message: "Could not read the job history.")
        }
        return .jobs(records.map(Self.report(for:)))
    }

    func jobLog(jobID: String) -> AgentResponse {
        let id = JobID(unchecked: jobID)
        guard let events = try? catalog.events(for: id) else {
            return .failed(message: "Could not read the log for job \(jobID).")
        }
        return .jobLog(events.map { event in
            JobLogLine(
                sequence: event.sequence,
                at: event.at,
                level: event.level.rawValue,
                message: event.message
            )
        })
    }

    static func report(for record: JobRecord) -> JobReport {
        JobReport(
            id: record.id,
            kind: record.kind.name,
            state: record.state.rawValue,
            queuedAt: record.queuedAt,
            startedAt: record.startedAt,
            finishedAt: record.finishedAt,
            bytesProcessed: record.bytesProcessed,
            bytesAdded: record.bytesAdded,
            filesNew: record.filesNew,
            filesChanged: record.filesChanged,
            errorText: record.errorText,
            resourceUUID: record.resourceUUID
        )
    }
}
