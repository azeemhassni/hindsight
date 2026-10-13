import Foundation
import HindsightProtocol
import Testing
@testable import HindsightUI

/// Adding a machine to restore onto, from its connection details.
@MainActor
@Suite("Adding a restore target")
struct RestoreTargetFlowTests {
    private func model(
        hostKey: HostKeyReport? = HostKeyReport(
            keyType: "ssh-ed25519",
            base64Key: "AAAAC3NzaC1lZDI1NTE5",
            fingerprint: "SHA256:abc123"
        ),
        trusts: Bool = true,
        probes: Bool = true,
        adds: Bool = true,
        record: ((AgentRequest) -> Void)? = nil
    ) -> AppModel {
        let model = AppModel()
        model.send = { request in
            record?(request)
            switch request {
            case .scanHostKey:
                return hostKey.map { .hostKey($0) } ?? .failed(message: "unreachable")
            case .trustHostKey:
                return trusts ? .done : .failed(message: "refused")
            case .probeServer:
                return probes
                    ? .probe(ServerProbeReport(
                        prettyName: "Ubuntu 24.04",
                        architecture: "aarch64",
                        hasPasswordlessSudo: true,
                        dockerVersion: nil,
                        homeDirectory: "/root",
                        isTestTarget: false
                    ))
                    : .failed(message: "could not connect")
            case .addRestoreTarget:
                return adds ? .serverAdded(serverID: "web-02") : .failed(message: "refused")
            case .status:
                return .status(AgentStatus(version: "test", servers: [], runningJobs: []))
            default:
                return .done
            }
        }
        return model
    }

    private func flow(_ model: AppModel) -> RestoreTargetFlow {
        let flow = RestoreTargetFlow(model: model)
        flow.host = "198.51.100.20"
        flow.user = "root"
        flow.port = "22"
        return flow
    }

    @Test("will not scan without a host, user and valid port")
    func requiresDetails() {
        let flow = RestoreTargetFlow(model: model())
        #expect(!flow.canScan)
        flow.host = "198.51.100.20"
        flow.user = "root"
        #expect(flow.canScan)
        flow.port = "0"
        #expect(!flow.canScan, "port 0 is not a port")
        flow.port = "70000"
        #expect(!flow.canScan)
        flow.port = "2222"
        #expect(flow.canScan)
    }

    /// The key is shown before anything is trusted, because the whole point is
    /// that a person compares it with the machine.
    @Test("shows the host key before accepting it")
    func showsTheHostKeyFirst() async {
        var requests: [String] = []
        let model = model(record: { request in
            if case .trustHostKey = request { requests.append("trust") }
            if case .addRestoreTarget = request { requests.append("add") }
        })
        let flow = flow(model)

        await flow.scan()
        guard case let .confirmingHostKey(report) = flow.stage else {
            Issue.record("expected a fingerprint to compare, got \(flow.stage)")
            return
        }
        #expect(report.fingerprint == "SHA256:abc123")
        // Nothing has been trusted or recorded yet.
        #expect(requests.isEmpty)
    }

    @Test("records the machine once the key is accepted")
    func addsAfterConfirmation() async {
        let flow = flow(model())
        await flow.scan()
        await flow.confirmHostKey()

        guard case let .added(serverID, hostname, _) = flow.stage else {
            Issue.record("expected the machine to be added, got \(flow.stage)")
            return
        }
        #expect(serverID == "web-02")
        #expect(hostname == "198.51.100.20")
        #expect(flow.probe?.prettyName == "Ubuntu 24.04")
    }

    /// Finding out at restore time that the details were wrong is finding out
    /// too late.
    @Test("a connection that does not work is refused before it is recorded")
    func refusesAnUnreachableMachine() async {
        var added = false
        let model = model(probes: false, record: { request in
            if case .addRestoreTarget = request { added = true }
        })
        let flow = flow(model)

        await flow.scan()
        await flow.confirmHostKey()

        guard case .failed = flow.stage else {
            Issue.record("expected a failure, got \(flow.stage)")
            return
        }
        #expect(!added, "a machine that cannot be reached must not be recorded")
    }

    @Test("an unreachable host fails at the scan, before anything is trusted")
    func failsWhenTheHostCannotBeReached() async {
        let flow = flow(model(hostKey: nil))
        await flow.scan()
        guard case .failed = flow.stage else {
            Issue.record("expected a failure, got \(flow.stage)")
            return
        }
    }
}
