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
        // Overridable so a development agent can be run against a scratch
        // catalog and repository root without touching the installed one.
        if let override = ProcessInfo.processInfo.environment["HINDSIGHT_AGENT_CONFIG"] {
            return URL(fileURLWithPath: override)
        }
        return applicationSupport.appendingPathComponent("Hindsight/agent.json")
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
            binaryDirectory: bundledBinaryDirectory(for: Bundle.main.bundleURL)
                ?? base.appendingPathComponent("bin")
        )
    }

    /// Where the vendored restic and rest-server are, seen from the agent.
    ///
    /// The agent is a small app bundle nested inside the main one, and the
    /// binaries are shipped once, in the outer bundle's Resources — copying
    /// forty megabytes twice to save this lookup would be the worse trade. A
    /// standalone build keeps its own Resources, which is what a development
    /// run uses.
    public static func bundledBinaryDirectory(for bundleURL: URL) -> URL? {
        let own = bundleURL.appendingPathComponent("Contents/Resources")
        if FileManager.default.fileExists(atPath: own.path),
           hasVendoredBinaries(own) {
            return own
        }

        // …/Hindsight.app/Contents/Library/LaunchAgents/HindsightAgent.app
        let enclosing = bundleURL
            .deletingLastPathComponent()  // LaunchAgents
            .deletingLastPathComponent()  // Library
            .deletingLastPathComponent()  // Contents
            .deletingLastPathComponent()  // Hindsight.app
            .appendingPathComponent("Contents/Resources")
        return hasVendoredBinaries(enclosing) ? enclosing : nil
    }

    private static func hasVendoredBinaries(_ directory: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return false }
        return names.contains { $0.hasPrefix("restic-") }
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
