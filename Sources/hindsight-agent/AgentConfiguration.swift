import Foundation
import HindsightCore

/// Where the agent keeps its state.
///
/// Read from disk rather than compiled in, so the app and the agent agree on
/// one location and a person can point Hindsight at an external disk.
struct AgentConfiguration: Codable, Sendable {
    var catalogURL: URL
    var repositoryRoot: URL
    var sshConfigurationDirectory: URL
    var binaryDirectory: URL

    static var defaultConfigurationURL: URL {
        applicationSupport.appendingPathComponent("Hindsight/agent.json")
    }

    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static var fallback: AgentConfiguration {
        let base = applicationSupport.appendingPathComponent("Hindsight")
        return AgentConfiguration(
            catalogURL: base.appendingPathComponent("catalog.sqlite"),
            repositoryRoot: base.appendingPathComponent("repos"),
            sshConfigurationDirectory: base.appendingPathComponent("ssh"),
            binaryDirectory: Bundle.main.resourceURL ?? base.appendingPathComponent("bin")
        )
    }

    static func load(from url: URL = defaultConfigurationURL) -> AgentConfiguration {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(AgentConfiguration.self, from: data)
        else { return fallback }
        return decoded
    }

    func save(to url: URL = defaultConfigurationURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
