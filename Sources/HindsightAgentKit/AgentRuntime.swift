import Foundation
import HindsightCatalog
import HindsightCore
import HindsightEngine
import HindsightKeychain
import HindsightProtocol

public let hindsightAgentVersion = "0.1.0"

/// The background agent.
///
/// It owns the schedule and every job, and it is the only writer of the
/// catalog. The app is a client: closing the window must not stop a backup,
/// and two processes writing the same SQLite file is a bug waiting to happen.
///
/// The runtime lives in a library rather than in the executable so that the
/// SwiftPM build and the app bundle's copy are the same code, built once. Two
/// copies of this would drift.
public enum AgentRuntime {
    public static func run() async {
        let configuration = AgentConfiguration.load()

        let catalog: Catalog
        do {
            catalog = try Catalog.open(at: configuration.catalogURL)
        } catch {
            FileHandle.standardError.write(Data("hindsight-agent: \(error)\n".utf8))
            exit(1)
        }

        let core = AgentCore(
            configuration: configuration,
            catalog: catalog,
            secrets: Keychain(),
            version: hindsightAgentVersion
        )
        await core.start()

        let delegate = AgentListenerDelegate(core: core)
        let listener = NSXPCListener(machServiceName: hindsightAgentMachServiceName)
        listener.delegate = delegate
        listener.resume()

        SleepWakeObserver.start(core: core)

        // The agent is long-lived by design; it exits only when launchd says
        // so. A sleeping loop rather than a continuation nobody resumes: a
        // continuation that is never resumed is reported as a leak, and the
        // task it parks can be freed with the process still expected to serve.
        while true {
            try? await Task.sleep(for: .seconds(3600))
        }
    }
}

public final class AgentListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let core: AgentCore

    public init(core: AgentCore) {
        self.core = core
    }

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        // Anyone who can reach this service can drive backups and restores, so
        // the peer is pinned to this team's signature before anything else.
        if let team = ConnectionSecurity.teamIdentifierFromEnvironment {
            connection.setCodeSigningRequirement(
                ConnectionSecurity.codeSigningRequirement(teamIdentifier: team)
            )
        }

        connection.exportedInterface = NSXPCInterface(with: HindsightAgentService.self)
        connection.exportedObject = AgentServiceAdapter(core: core, connection: connection)
        connection.remoteObjectInterface = NSXPCInterface(with: HindsightAgentObserver.self)
        connection.resume()
        return true
    }
}

public final class AgentServiceAdapter: NSObject, HindsightAgentService, @unchecked Sendable {
    private let core: AgentCore
    private weak var connection: NSXPCConnection?
    private var observerToken: UUID?

    public init(core: AgentCore, connection: NSXPCConnection) {
        self.core = core
        self.connection = connection
        super.init()

        // The proxy is not Sendable, so events are delivered through a box
        // that owns it and hands out only a Sendable closure.
        let sink = ObserverSink(connection: connection)
        Task { [weak self] in
            guard let self else { return }
            let token = await core.observe { event in
                guard let data = try? AgentCoding.encode(event) else { return }
                sink.send(data)
            }
            self.observerToken = token
        }

        connection.invalidationHandler = { [weak self] in
            guard let self, let token = self.observerToken else { return }
            Task { await core.removeObserver(token) }
        }
    }

    public func perform(_ request: Data, reply: @escaping @Sendable (Data?) -> Void) {
        Task { [core] in
            let decoded: AgentRequest
            do {
                decoded = try AgentCoding.decode(AgentRequest.self, from: request)
            } catch {
                reply(try? AgentCoding.encode(AgentResponse.failed(message: "Unreadable request.")))
                return
            }
            let response = await core.handle(decoded)
            reply(try? AgentCoding.encode(response))
        }
    }
}

/// Owns the non-`Sendable` XPC proxy so that event delivery can be.
public final class ObserverSink: @unchecked Sendable {
    private let lock = NSLock()
    private weak var connection: NSXPCConnection?

    public init(connection: NSXPCConnection) {
        self.connection = connection
    }

    public func send(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        (connection?.remoteObjectProxy as? HindsightAgentObserver)?.receive(data)
    }
}

/// Re-evaluates the schedule when the Mac wakes.
///
/// Without this the agent would keep sleeping on a timer that was set before
/// the machine suspended, and a backup due during sleep would be late by
/// however long the lid was shut.
public enum SleepWakeObserver {
    public static func start(core: AgentCore) {
        let center = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsUnlocked", "com.apple.system.powersources.timeremaining"] {
            center.addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: .main
            ) { _ in
                Task { await core.wakeUp() }
            }
        }
    }
}

extension AgentCore {
    func wakeUp() async {
        await handleWake()
    }
}
