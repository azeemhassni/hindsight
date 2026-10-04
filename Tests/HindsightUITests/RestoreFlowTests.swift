import Foundation
import HindsightProtocol
import Testing
@testable import HindsightUI

@MainActor
@Suite("Restore flow")
struct RestoreFlowTests {
    private func makeFlow(
        reply: @escaping @MainActor (AgentRequest) async -> AgentResponse?
    ) -> (RestoreFlow, AppModel) {
        let model = AppModel()
        model.send = reply
        let flow = RestoreFlow(model: model, serverID: "web-01", serverHostname: "web-01.example.com")
        flow.snapshotID = "aa11bb22"
        flow.paths = ["/srv/app"]
        return (flow, model)
    }

    private let report = RestorePreviewReport(
        changes: [
            RestoreChange(path: "/srv/app/one", kind: "modified"),
            RestoreChange(path: "/srv/app/two", kind: "added"),
        ],
        safetySnapshotID: "ffee1122",
        bytesAdded: 100,
        bytesRemoved: 0
    )

    @Test("will not confirm before a preview exists")
    func needsAPreviewFirst() {
        let (flow, _) = makeFlow { _ in nil }
        flow.typedHostname = "web-01.example.com"
        // The hostname matches, but nothing has been previewed, so there is
        // nothing the person could have reviewed.
        #expect(!flow.canConfirm)
    }

    @Test("will not confirm until the hostname matches exactly")
    func needsTheHostname() async {
        let (flow, _) = makeFlow { _ in .restorePreview(report) }
        await flow.prepare()
        #expect(flow.stage == .reviewing)

        #expect(!flow.canConfirm)
        flow.typedHostname = "web-01"
        #expect(!flow.canConfirm, "a prefix of the hostname is not the hostname")
        flow.typedHostname = " WEB-01.EXAMPLE.COM "
        #expect(flow.canConfirm, "case and surrounding space are forgiven")
    }

    @Test("previews under the server's own name, not whatever was typed")
    func previewsWithTheRealHostname() async {
        // Otherwise a preview could be used to poke at a server the person has
        // not identified.
        let seen = Captured()
        let (flow, _) = makeFlow { request in
            if case let .previewRestore(command) = request {
                await seen.record(command.typedHostname)
            }
            return .restorePreview(report)
        }
        flow.typedHostname = "something else"
        await flow.prepare()
        #expect(await seen.values == ["web-01.example.com"])
    }

    @Test("reports what the preview found in words")
    func describesThePreview() async {
        let (flow, _) = makeFlow { _ in .restorePreview(report) }
        await flow.prepare()
        #expect(flow.statusText.contains("1 to add"))
        #expect(flow.statusText.contains("1 to change"))
    }

    @Test("a refused preview leaves the flow in a failed state, not a silent one")
    func reportsRefusal() async {
        let (flow, _) = makeFlow { _ in .failed(message: "Type the server's hostname to confirm this restore.") }
        await flow.prepare()
        guard case let .failed(message) = flow.stage else {
            Issue.record("expected a failure, got \(flow.stage)")
            return
        }
        #expect(message.contains("hostname"))
    }

    @Test("does not send a restore while the confirmation is wrong")
    func refusesToRunUnconfirmed() async {
        let requests = Captured()
        let (flow, _) = makeFlow { request in
            if case .runRestore = request { await requests.record("run") }
            return .restorePreview(report)
        }
        await flow.prepare()
        flow.typedHostname = "wrong"
        await flow.run()
        #expect(await requests.values.isEmpty, "a restore was sent without a matching hostname")
    }

    @Test("sends the restore once everything lines up")
    func runsWhenConfirmed() async {
        let requests = Captured()
        let (flow, _) = makeFlow { request in
            switch request {
            case .previewRestore: return .restorePreview(report)
            case .runRestore:
                await requests.record("run")
                return .accepted(jobID: "job-1")
            default: return .status(AgentStatus(version: "t", servers: [], runningJobs: []))
            }
        }
        await flow.prepare()
        flow.typedHostname = "web-01.example.com"
        await flow.run()
        #expect(await requests.values == ["run"])
        #expect(flow.stage == .running)
    }

    @Test("reflects the agent's outcome, including how to undo it")
    func reflectsTheOutcome() async {
        let (flow, _) = makeFlow { _ in .restorePreview(report) }
        flow.apply(.restoreFinished(
            serverID: "web-01",
            succeeded: true,
            safetySnapshotID: "ffee1122aabb",
            message: nil
        ))
        #expect(flow.stage == .finished(succeeded: true, safetySnapshotID: "ffee1122aabb"))
        #expect(flow.statusText.contains("ffee1122"))
        #expect(flow.statusText.contains("Undo"))
    }

    @Test("ignores an outcome for a different server")
    func ignoresOtherServers() async {
        let (flow, _) = makeFlow { _ in nil }
        flow.apply(.restoreFinished(serverID: "db-01", succeeded: false, safetySnapshotID: nil, message: "boom"))
        #expect(flow.stage == .choosing)
    }
}

private actor Captured {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}

@MainActor
@Suite("A restore asks the person first")
struct RestorePresenceTests {
    private func makeFlow(
        presence: any UserPresenceCheck,
        reply: @escaping @MainActor (AgentRequest) async -> AgentResponse?
    ) -> (RestoreFlow, AppModel, Recorder) {
        let recorder = Recorder()
        let model = AppModel()
        model.send = { request in
            recorder.requests.append(request)
            return await reply(request)
        }
        let flow = RestoreFlow(
            model: model,
            serverID: "web-01",
            serverHostname: "web-01.example.com",
            presence: presence
        )
        flow.snapshotID = "aa11bb22"
        flow.typedHostname = "web-01.example.com"
        flow.preview = RestorePreviewReport(
            changes: [RestoreChange(path: "/srv/app", kind: "modified")],
            safetySnapshotID: "ffee1122",
            bytesAdded: 10,
            bytesRemoved: 0
        )
        return (flow, model, recorder)
    }

    final class Recorder {
        var requests: [AgentRequest] = []
        var ranRestore: Bool {
            requests.contains { if case .runRestore = $0 { true } else { false } }
        }
    }

    @Test("asks for Touch ID, then sends the restore with the token it was given")
    func confirmsBeforeRestoring() async {
        let (flow, _, recorder) = makeFlow(presence: StubPresence(.confirmed)) { request in
            switch request {
            case .authorizeRestore:
                return .restoreAuthorization(token: "token-123", expiresAt: Date().addingTimeInterval(120))
            case .runRestore:
                return .accepted(jobID: "job-1")
            default:
                return .done
            }
        }
        await flow.run()

        let sent = recorder.requests.compactMap { request -> RestoreCommand? in
            if case let .runRestore(command) = request { return command }
            return nil
        }
        #expect(sent.count == 1)
        #expect(sent.first?.authorization == "token-123")
        #expect(flow.stage == .running)
    }

    /// The point of the whole thing: saying no leaves the server untouched.
    @Test("sends nothing when the person declines")
    func declineStopsTheRestore() async {
        let (flow, _, recorder) = makeFlow(presence: StubPresence(.declined)) { request in
            if case .authorizeRestore = request {
                return .restoreAuthorization(token: "token-123", expiresAt: Date().addingTimeInterval(120))
            }
            return .accepted(jobID: "job-1")
        }
        await flow.run()

        #expect(!recorder.ranRestore)
        guard case let .failed(message) = flow.stage else {
            Issue.record("expected a failed stage, got \(flow.stage)")
            return
        }
        #expect(message.contains("nothing was changed"))
    }

    @Test("sends nothing when the Mac cannot ask")
    func unavailableStopsTheRestore() async {
        let (flow, _, recorder) = makeFlow(
            presence: StubPresence(.unavailable("no authentication is available"))
        ) { _ in .restoreAuthorization(token: "t", expiresAt: Date().addingTimeInterval(120)) }
        await flow.run()

        #expect(!recorder.ranRestore)
        guard case let .failed(message) = flow.stage else {
            Issue.record("expected a failed stage, got \(flow.stage)")
            return
        }
        #expect(message.contains("could not ask"))
    }

    @Test("does not ask at all when the agent refuses to authorise")
    func refusedAuthorisationStopsBeforeThePrompt() async {
        let (flow, _, recorder) = makeFlow(presence: StubPresence(.confirmed)) { request in
            if case .authorizeRestore = request {
                return .failed(message: "No server with id web-01.")
            }
            return .accepted(jobID: "job-1")
        }
        await flow.run()
        #expect(!recorder.ranRestore)
    }

    /// The prompt has to name what is about to happen: a system dialog that
    /// only says "authenticate" is one people approve without reading.
    @Test("the prompt says what is about to be written, and where")
    func reasonNamesTheServerAndScope() {
        let (flow, _, _) = makeFlow(presence: StubPresence()) { _ in .done }
        #expect(flow.confirmationReason.contains("web-01.example.com"))
        #expect(flow.confirmationReason.contains("everything in this snapshot"))

        flow.paths = ["/etc/nginx/nginx.conf"]
        #expect(flow.confirmationReason.contains("/etc/nginx/nginx.conf"))

        flow.paths = ["/a", "/b", "/c"]
        #expect(flow.confirmationReason.contains("3 paths"))
    }
}
