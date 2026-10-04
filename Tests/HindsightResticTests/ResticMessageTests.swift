import Foundation
import HindsightCore
import Testing
@testable import HindsightRestic

/// Every fixture here was captured from restic 0.19.1 rather than written from
/// memory, so these tests fail if a restic upgrade changes the real shape.
@Suite("restic JSON")
struct ResticMessageTests {
    static let summaryLine = #"{"message_type":"summary","files_new":2,"files_changed":0,"files_unmodified":0,"dirs_new":2,"dirs_changed":0,"dirs_unmodified":0,"data_blobs":2,"tree_blobs":3,"data_added":201530,"data_added_packed":201185,"total_files_processed":2,"total_bytes_processed":200006,"total_duration":0.749722625,"backup_start":"2026-10-04T11:35:34.979356+05:00","backup_end":"2026-10-04T11:35:35.729079+05:00","snapshot_id":"0381817e72f31a37088b0175e0fd1d0fbb55790637868f338b74606e67148485"}"#

    static let statusLine = #"{"message_type":"status","seconds_elapsed":2,"seconds_remaining":8,"percent_done":0.25,"total_files":3,"files_done":1,"total_bytes":300000000,"bytes_done":75000000,"current_files":["/root/big3.bin"]}"#

    static let verboseLine = #"{"message_type":"verbose_status","action":"modified","item":"/rtest/data/a.txt","duration":0.0017715,"data_size":16,"data_size_in_repo":98,"metadata_size":0,"metadata_size_in_repo":0,"total_files":0}"#

    static let errorLine = #"{"message_type":"error","error":{"message":"open /root/secret: permission denied"},"during":"archival","item":"/root/secret"}"#

    static let snapshotsJSON = #"[{"time":"2026-10-04T11:35:34.979356+05:00","tree":"b330ba32f508ba5135bc4eae1f7d67e0e85429dace528de005941a2174a1615e","paths":["/srv/data"],"hostname":"web-01","username":"root","uid":0,"gid":0,"tags":["hindsight","profile:full"],"program_version":"restic 0.19.1","summary":{"backup_start":"2026-10-04T11:35:34.979356+05:00","backup_end":"2026-10-04T11:35:35.729079+05:00","files_new":2,"files_changed":0,"files_unmodified":0,"dirs_new":2,"dirs_changed":0,"dirs_unmodified":0,"data_blobs":2,"tree_blobs":3,"data_added":201530,"data_added_packed":201185,"total_files_processed":2,"total_bytes_processed":200006},"id":"0381817e72f31a37088b0175e0fd1d0fbb55790637868f338b74606e67148485","short_id":"0381817e"}]"#

    static let checkLine = #"{"message_type":"summary","num_errors":0,"broken_packs":null,"suggest_repair_index":false,"suggest_prune":false}"#

    @Test("decodes a backup summary")
    func decodesSummary() throws {
        guard case let .summary(summary) = ResticMessage.decode(line: Self.summaryLine) else {
            Issue.record("expected a summary")
            return
        }
        #expect(summary.filesNew == 2)
        #expect(summary.dataAdded == 201_530)
        #expect(summary.totalBytesProcessed == 200_006)
        #expect(summary.snapshotID?.hasPrefix("0381817e") == true)
        #expect(summary.backupStart != nil)
        #expect(summary.backupEnd != nil)
    }

    @Test("decodes progress, which is what the activity view shows")
    func decodesStatus() throws {
        guard case let .status(status) = ResticMessage.decode(line: Self.statusLine) else {
            Issue.record("expected a status")
            return
        }
        #expect(status.percentDone == 0.25)
        #expect(status.bytesDone == 75_000_000)
        #expect(status.totalBytes == 300_000_000)
        #expect(status.secondsRemaining == 8)
        #expect(status.currentFiles == ["/root/big3.bin"])
    }

    @Test("decodes a per-item verbose status")
    func decodesVerboseStatus() {
        guard case let .verboseStatus(status) = ResticMessage.decode(line: Self.verboseLine) else {
            Issue.record("expected a verbose status")
            return
        }
        #expect(status.action == "modified")
        #expect(status.item == "/rtest/data/a.txt")
    }

    @Test("decodes an error without losing which file it was")
    func decodesError() {
        guard case let .error(error) = ResticMessage.decode(line: Self.errorLine) else {
            Issue.record("expected an error")
            return
        }
        #expect(error.error.message.contains("permission denied"))
        #expect(error.item == "/root/secret")
        #expect(error.during == "archival")
    }

    @Test("survives output a pseudo-terminal interleaves with the JSON")
    func ignoresNonJSONLines() {
        // Backups run with a terminal attached so restic emits progress, which
        // means other output shares the stream.
        #expect(ResticMessage.decode(line: "") == nil)
        #expect(ResticMessage.decode(line: "Warning: Permanently added a host key") == nil)
        #expect(ResticMessage.decode(line: "\u{1B}[2K\r") == nil)
        #expect(ResticMessage.decode(line: "not json at all") == nil)
    }

    @Test("reports an unfamiliar message type instead of failing")
    func toleratesNewMessageTypes() {
        let message = ResticMessage.decode(line: #"{"message_type":"something_new","x":1}"#)
        #expect(message == .unknown(type: "something_new"))
    }

    @Test("decodes a snapshot list and maps it to the domain model")
    func decodesSnapshots() throws {
        let data = try #require(Self.snapshotsJSON.data(using: .utf8))
        let decoded = try JSONDecoder.restic().decode([ResticSnapshot].self, from: data)
        #expect(decoded.count == 1)

        let snapshot = decoded[0].toSnapshot()
        #expect(snapshot.id.short == "0381817e")
        #expect(snapshot.hostname == "web-01")
        #expect(snapshot.paths == ["/srv/data"])
        #expect(snapshot.tags == ["hindsight", "profile:full"])
        #expect(snapshot.kind == .filesystem)
        #expect(snapshot.sizeBytes == 200_006)
        #expect(snapshot.dataAddedBytes == 201_530)
    }

    @Test("infers a snapshot's kind from the tags Hindsight writes")
    func infersKind() {
        #expect(ResticSnapshot.inferKind(from: ["hindsight"]) == .filesystem)
        #expect(ResticSnapshot.inferKind(from: ["db:postgres", "dbname:app"]) == .databaseDump)
        #expect(ResticSnapshot.inferKind(from: ["profile:metadata"]) == .metadata)
        #expect(ResticSnapshot.inferKind(from: ["safety", "restore:job-1"]) == .safety)
    }

    @Test("decodes a check summary, including a healthy one")
    func decodesCheckSummary() throws {
        let data = try #require(Self.checkLine.data(using: .utf8))
        let summary = try JSONDecoder.restic().decode(ResticCheckSummary.self, from: data)
        #expect(summary.numErrors == 0)
        #expect(summary.isHealthy)

        let brokenJSON = #"{"message_type":"summary","num_errors":2,"broken_packs":["1a2b"],"suggest_repair_index":true,"suggest_prune":false}"#
        let broken = try JSONDecoder.restic().decode(
            ResticCheckSummary.self,
            from: try #require(brokenJSON.data(using: .utf8))
        )
        #expect(!broken.isHealthy)
        #expect(broken.brokenPacks == ["1a2b"])
    }

    @Test("decodes a diff, which is what a restore preview is built from")
    func decodesDiff() {
        let change = ResticDiffMessage.decode(line: #"{"message_type":"change","path":"/rtest/data/a.txt","modifier":"M"}"#)
        #expect(change == .change(path: "/rtest/data/a.txt", modifier: "M"))

        let statisticsLine = #"{"message_type":"statistics","source_snapshot":"0381817e","target_snapshot":"f6f47d15","changed_files":1,"added":{"files":0,"dirs":0,"others":0,"data_blobs":1,"tree_blobs":3,"bytes":1539},"removed":{"files":0,"dirs":0,"others":0,"data_blobs":1,"tree_blobs":3,"bytes":1530}}"#
        guard case let .statistics(statistics) = ResticDiffMessage.decode(line: statisticsLine) else {
            Issue.record("expected statistics")
            return
        }
        #expect(statistics.changedFiles == 1)
        #expect(statistics.added.bytes == 1539)
        #expect(statistics.removed.bytes == 1530)
    }

    @Test("parses restic timestamps with and without fractional seconds")
    func parsesTimestamps() {
        #expect(ResticTimestamp.parse("2026-10-04T11:35:34.979356+05:00") != nil)
        #expect(ResticTimestamp.parse("2026-10-04T11:35:34+05:00") != nil)
        #expect(ResticTimestamp.parse("2026-10-04T06:35:34Z") != nil)
        #expect(ResticTimestamp.parse("not a date") == nil)
    }
}

@Suite("rest-server credentials")
struct RestServerCredentialTests {
    @Test("writes the {SHA} entry rest-server accepts")
    func writesShaEntry() {
        let credential = RestServerCredential(
            username: "web-01",
            password: Secret(label: "test", value: "abc")
        )
        // base64(sha1("abc")) is a published constant.
        #expect(credential.htpasswdLine == "web-01:{SHA}qZk+NkcGgWq6PiVxeFDCbJzQ2J0=")
    }

    @Test("generates a password with real entropy")
    func generatesStrongPassword() {
        let first = RestServerCredential.generate(username: "web-01")
        let second = RestServerCredential.generate(username: "web-01")
        #expect(first.password.value != second.password.value)
        #expect(first.password.value.count >= 40)
    }

    @Test("escapes the credential for a rest URL")
    func escapesURLUserInfo() {
        let credential = RestServerCredential(
            username: "web-01",
            password: Secret(label: "test", value: "a+b/c=d")
        )
        #expect(credential.urlUserInfo == "web-01:a%2Bb%2Fc%3Dd")
        #expect(!credential.urlUserInfo.contains("+"))
        #expect(!credential.urlUserInfo.contains("/"))
    }

    @Test("writes the htpasswd file readable only by its owner")
    func writesPrivateFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hindsight-htpasswd-\(UUID().uuidString)")
        try RestServerCredential.generate(username: "web-01").write(to: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.int16Value & 0o177 == 0)
    }

    @Test("reads the port rest-server reports")
    func parsesPort() {
        #expect(RestServer.parsePort(from: "start server on 127.0.0.1:55393") == 55393)
        #expect(RestServer.parsePort(from: "Append only mode enabled") == nil)
        #expect(RestServer.parsePort(from: "") == nil)
    }
}
