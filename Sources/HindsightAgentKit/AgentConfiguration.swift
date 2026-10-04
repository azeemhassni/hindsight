import Foundation
import HindsightCore

/// Where the agent keeps its state.
///
/// Read from disk rather than compiled in, so the app and the agent agree on
/// one location and a person can point Hindsight at an external disk.
public struct AgentConfiguration: Codable, Sendable {
    public var catalogURL: URL
    public var repositoryRoot: URL
    public var sshConfigurationDirectory: URL
    public var binaryDirectory: URL

    public static var defaultConfigurationURL: URL {
        applicationSupport.appendingPathComponent("Hindsight/agent.json")
    }

    public static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    public static var fallback: AgentConfiguration {
        let base = applicationSupport.appendingPathComponent("Hindsight")
        return AgentConfiguration(
            catalogURL: base.appendingPathComponent("catalog.sqlite"),
            repositoryRoot: base.appendingPathComponent("repos"),
            sshConfigurationDirectory: base.appendingPathComponent("ssh"),
            binaryDirectory: Bundle.main.resourceURL ?? base.appendingPathComponent("bin")
        )
    }

    public static func load(from url: URL = defaultConfigurationURL) -> AgentConfiguration {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(AgentConfiguration.self, from: data)
        else { return fallback }
        return decoded
    }

    public func save(to url: URL = defaultConfigurationURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
