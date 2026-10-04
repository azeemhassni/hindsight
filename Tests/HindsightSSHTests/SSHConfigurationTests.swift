import Foundation
import HindsightCore
import Testing
@testable import HindsightSSH

func makeDestination(
    id: String = "web-01",
    host: String = "127.0.0.1",
    port: Int = 2222,
    user: String = "root",
    privilege: Privilege = .root
) throws -> SSHDestination {
    SSHDestination(
        serverID: try ServerID(validating: id),
        host: host,
        port: port,
        user: user,
        identityFile: "/tmp/hindsight-test/id_ed25519",
        privilege: privilege
    )
}

func makeTemporaryPaths() throws -> SSHPaths {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("hindsight-ssh-\(UUID().uuidString)")
    let paths = SSHPaths(
        configurationDirectory: base.appendingPathComponent("ssh"),
        preferredControlDirectory: base.appendingPathComponent("cm")
    )
    try paths.prepare()
    return paths
}

@Suite("SSH destination")
struct SSHDestinationTests {
    @Test("brackets the host in known_hosts only when the port is not 22")
    func knownHostsHost() throws {
        try #expect(makeDestination(port: 22).knownHostsHost == "127.0.0.1")
        try #expect(makeDestination(port: 2222).knownHostsHost == "[127.0.0.1]:2222")
    }

    @Test("names the config alias after the server id")
    func configAlias() throws {
        try #expect(makeDestination(id: "web-01").configAlias == "hs-web-01")
    }

    @Test("derives a short, stable control token")
    func controlToken() throws {
        let token = try makeDestination().controlToken
        #expect(token.count == 10)
        let isHexadecimal = token.allSatisfy(\.isHexDigit)
        #expect(isHexadecimal)
        try #expect(makeDestination().controlToken == token)
        try #expect(makeDestination(id: "web-02").controlToken != token)
        try #expect(makeDestination(port: 2223).controlToken != token)
        try #expect(makeDestination(user: "hindsight").controlToken != token)
    }
}

@Suite("SSH paths")
struct SSHPathsTests {
    @Test("keeps the control socket inside the kernel's path limit")
    func controlPathFitsLimit() throws {
        let paths = try makeTemporaryPaths()
        let path = try paths.controlPath(forToken: try makeDestination().controlToken)
        #expect(path.utf8.count < SSHPaths.socketPathLimit)
    }

    @Test("falls back to a short private directory when the preferred path is too long")
    func fallsBackForLongPaths() throws {
        let long = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent(String(repeating: "deep-directory-name/", count: 8))
        let paths = SSHPaths(
            configurationDirectory: long.appendingPathComponent("ssh"),
            preferredControlDirectory: long.appendingPathComponent("cm")
        )
        let path = try paths.controlPath(forToken: "abcdef0123")
        #expect(path.hasPrefix("/tmp/hindsight-"))
        #expect(path.utf8.count < SSHPaths.socketPathLimit)
    }

    @Test("refuses a socket directory other users can write to")
    func refusesWorldWritableDirectory() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hindsight-unsafe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
        #expect(throws: SSHError.self) { try SSHPaths.verifyPrivateOwnership(of: directory) }
    }

    @Test("accepts a private directory it owns")
    func acceptsPrivateDirectory() throws {
        let paths = try makeTemporaryPaths()
        #expect(throws: Never.self) {
            try SSHPaths.verifyPrivateOwnership(of: paths.configurationDirectory)
        }
    }

    @Test("creates known_hosts with owner-only permissions")
    func knownHostsPermissions() throws {
        let paths = try makeTemporaryPaths()
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.knownHostsFile.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.int16Value & 0o077 == 0)
    }
}

@Suite("SSH configuration")
struct SSHConfigurationTests {
    @Test("pins host key checking and never touches the user's own ssh setup")
    func stanzaIsStrict() throws {
        let paths = try makeTemporaryPaths()
        let stanza = try SSHConfiguration(paths: paths).stanza(for: try makeDestination())

        #expect(stanza.contains("StrictHostKeyChecking yes"))
        #expect(!stanza.contains("accept-new"))
        #expect(stanza.contains("UserKnownHostsFile \(paths.knownHostsFile.path)"))
        #expect(stanza.contains("GlobalKnownHostsFile /dev/null"))
        #expect(stanza.contains("IdentitiesOnly yes"))
        #expect(stanza.contains("IdentityAgent none"))
        #expect(stanza.contains("ExitOnForwardFailure yes"))
        #expect(stanza.contains("BatchMode yes"))
        #expect(stanza.contains("ForwardAgent no"))
        #expect(!stanza.contains("/.ssh/"))
    }

    @Test("renders one stanza per server, in a stable order")
    func rendersStably() throws {
        let paths = try makeTemporaryPaths()
        let configuration = SSHConfiguration(paths: paths)
        let destinations = [
            try makeDestination(id: "web-02"),
            try makeDestination(id: "db-01"),
        ]
        let rendered = try configuration.render(for: destinations)
        let firstIndex = try #require(rendered.range(of: "Host hs-db-01"))
        let secondIndex = try #require(rendered.range(of: "Host hs-web-02"))
        #expect(firstIndex.lowerBound < secondIndex.lowerBound)
        try #expect(configuration.render(for: destinations) == rendered)
    }

    @Test("writes the config readable only by its owner")
    func writesPrivateFile() throws {
        let paths = try makeTemporaryPaths()
        let file = try SSHConfiguration(paths: paths).write(for: [try makeDestination()])
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.int16Value & 0o177 == 0)
        try #expect(String(contentsOf: file, encoding: .utf8).contains("Host hs-web-01"))
    }
}

@Suite("Configuration values with spaces")
struct SSHConfigurationQuotingTests {
    /// The default install path is `~/Library/Application Support/Hindsight`,
    /// and an unquoted value stops at the first space: ssh then looks for
    /// `/Users/you/Library/Application`, finds no known_hosts, and reports
    /// every server's key as unknown. Found by installing the app rather than
    /// by a test, because temporary directories have no spaces in them.
    @Test("quotes a path containing a space")
    func quotesPathsWithSpaces() throws {
        let rendered = try SSHConfiguration.argument(
            "/Users/me/Library/Application Support/Hindsight/ssh/known_hosts",
            keyword: "UserKnownHostsFile"
        )
        #expect(rendered == "\"/Users/me/Library/Application Support/Hindsight/ssh/known_hosts\"")
    }

    @Test("leaves a plain value alone")
    func leavesPlainValuesAlone() throws {
        #expect(try SSHConfiguration.argument("yes", keyword: "StrictHostKeyChecking") == "yes")
        #expect(try SSHConfiguration.argument("/dev/null", keyword: "GlobalKnownHostsFile") == "/dev/null")
        #expect(try SSHConfiguration.argument("127.0.0.1", keyword: "HostName") == "127.0.0.1")
    }

    @Test("refuses a value that would break the file open")
    func refusesUnusableValues() {
        #expect(throws: SSHError.self) {
            try SSHConfiguration.argument("/tmp/a\"b", keyword: "IdentityFile")
        }
        #expect(throws: SSHError.self) {
            try SSHConfiguration.argument("/tmp/a\nHost evil", keyword: "IdentityFile")
        }
    }

    @Test("a whole stanza quotes every path that needs it")
    func stanzaQuotesPaths() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Application Support/Hindsight \(UUID().uuidString)")
        let paths = SSHPaths(
            configurationDirectory: base.appendingPathComponent("ssh"),
            preferredControlDirectory: base.appendingPathComponent("cm")
        )
        try paths.prepare()
        let destination = SSHDestination(
            serverID: try ServerID(validating: "web-01"),
            host: "127.0.0.1",
            port: 2222,
            user: "root",
            identityFile: base.appendingPathComponent("my key").path,
            privilege: .root
        )

        let stanza = try SSHConfiguration(paths: paths).stanza(for: destination)
        let knownHosts = try #require(
            stanza.split(separator: "\n").first { $0.contains("UserKnownHostsFile") }
        )
        #expect(knownHosts.contains("\"") , "a path with a space must be quoted: \(knownHosts)")
        let identity = try #require(
            stanza.split(separator: "\n").first { $0.contains("IdentityFile") }
        )
        #expect(identity.contains("\"my key\"") || identity.contains("my key\""))
    }
}
