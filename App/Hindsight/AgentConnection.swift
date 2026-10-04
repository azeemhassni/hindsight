import Foundation
import HindsightProtocol
import Observation

/// The app's end of the XPC connection.
///
/// The connection is recreated on demand: the agent is launched by launchd and
/// may be restarted independently, so holding a dead connection open would be
/// a way to look broken when nothing is wrong.
@MainActor
@Observable
final class AgentConnection {
    var onEvent: ((AgentEvent) -> Void)?

    private var connection: NSXPCConnection?
    private let observer = EventObserver()

    init() {
        observer.deliver = { [weak self] event in
            Task { @MainActor in self?.onEvent?(event) }
        }
    }

    func send(_ request: AgentRequest) async -> AgentResponse? {
        guard let payload = try? AgentCoding.encode(request) else { return nil }
        let connection = ensureConnection()

        return await withCheckedContinuation { continuation in
            let box = ReplyBox(continuation: continuation)

            // Both closures are explicitly `@Sendable`, and capture only the
            // box. Without that they inherit this type's `@MainActor`
            // isolation, and XPC calls them on its own queue — which traps on
            // the isolation check rather than reporting the failure.
            //
            // The error handler itself is what keeps a request to an absent
            // agent from leaving the caller suspended forever: XPC never calls
            // the reply block at all in that case.
            let service = connection?.remoteObjectProxyWithErrorHandler { @Sendable _ in
                box.finish(nil)
            } as? HindsightAgentService

            guard let service else {
                box.finish(nil)
                return
            }

            service.perform(payload) { @Sendable data in
                box.finish(data.flatMap { try? AgentCoding.decode(AgentResponse.self, from: $0) })
            }
        }
    }

    private func ensureConnection() -> NSXPCConnection? {
        if connection == nil {
            let created = NSXPCConnection(machServiceName: hindsightAgentMachServiceName)
            created.remoteObjectInterface = NSXPCInterface(with: HindsightAgentService.self)
            created.exportedInterface = NSXPCInterface(with: HindsightAgentObserver.self)
            created.exportedObject = observer

            // The agent holds the repository passwords and can drive restores,
            // so the peer is pinned to this team's signature.
            if let team = ConnectionSecurity.teamIdentifierFromEnvironment {
                created.setCodeSigningRequirement(
                    ConnectionSecurity.codeSigningRequirement(teamIdentifier: team)
                )
            }

            created.invalidationHandler = { [weak self] in
                Task { @MainActor in self?.connection = nil }
            }
            created.interruptionHandler = { [weak self] in
                Task { @MainActor in self?.connection = nil }
            }
            created.resume()
            connection = created
        }
        return connection
    }
}

/// Receives live job events from the agent.
final class EventObserver: NSObject, HindsightAgentObserver, @unchecked Sendable {
    var deliver: ((AgentEvent) -> Void)?

    func receive(_ event: Data) {
        guard let decoded = try? AgentCoding.decode(AgentEvent.self, from: event) else { return }
        deliver?(decoded)
    }
}

/// Makes sure a continuation is resumed exactly once, even if XPC calls the
/// reply block twice or not at all.
private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AgentResponse?, Never>?

    init(continuation: CheckedContinuation<AgentResponse?, Never>) {
        self.continuation = continuation
    }

    func finish(_ response: AgentResponse?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: response)
    }
}
