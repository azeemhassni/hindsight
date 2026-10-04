import Foundation
import HindsightCore
import HindsightProcess
import Testing
@testable import HindsightSSH

@Suite("Remote command")
struct RemoteCommandTests {
    @Test("sends secrets over stdin and keeps them out of the script")
    func secretsNeverAppearInTheScript() throws {
        let secret = Secret(label: "repo-password", value: "correct-horse-battery-staple")
        let command = RemoteCommand(
            executable: "/root/.cache/hindsight/restic-0.19.1",
            arguments: ["backup", "--json", "/etc"],
            secretEnvironment: ["RESTIC_PASSWORD": secret]
        )

        let script = try RemoteCommand.script(for: command)
        #expect(!script.contains(secret.value))
        #expect(script.contains("IFS= read -r __hs_RESTIC_PASSWORD"))
        #expect(script.contains("RESTIC_PASSWORD=\"$__hs_RESTIC_PASSWORD\"; export RESTIC_PASSWORD"))
        #expect(script.contains("unset __hs_RESTIC_PASSWORD"))
        #expect(command.standardInputPayload() == Data((secret.value + "\n").utf8))
    }

    @Test("reads secrets in the same order it writes them")
    func secretOrderMatches() throws {
        let command = RemoteCommand(
            executable: "/bin/true",
            secretEnvironment: [
                "B_TOKEN": Secret(label: "b", value: "bbb"),
                "A_TOKEN": Secret(label: "a", value: "aaa"),
                "C_TOKEN": Secret(label: "c", value: "ccc"),
            ]
        )
        let script = try RemoteCommand.script(for: command)
        let readOrder = script
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard line.hasPrefix("IFS= read -r __hs_") else { return nil }
                return line.dropFirst("IFS= read -r __hs_".count)
                    .split(separator: " ")
                    .first
                    .map(String.init)
            }
        #expect(readOrder == ["A_TOKEN", "B_TOKEN", "C_TOKEN"])
        #expect(command.standardInputPayload() == Data("aaa\nbbb\nccc\n".utf8))
    }

    @Test("puts the payload after the secret lines")
    func payloadFollowsSecrets() throws {
        let command = RemoteCommand(
            executable: "/bin/cat",
            secretEnvironment: ["TOKEN": Secret(label: "t", value: "sekret")],
            standardInput: Data("dump-bytes".utf8)
        )
        #expect(command.standardInputPayload() == Data("sekret\ndump-bytes".utf8))
    }

    @Test("refuses a secret containing a newline, which would desynchronise the reads")
    func refusesMultilineSecret() {
        let command = RemoteCommand(
            executable: "/bin/true",
            secretEnvironment: ["TOKEN": Secret(label: "multiline", value: "one\ntwo")]
        )
        #expect(throws: RemoteCommandError.secretContainsNewline(label: "multiline")) {
            try RemoteCommand.script(for: command)
        }
    }

    @Test("quotes the argument vector and execs it")
    func quotesArgv() throws {
        let command = RemoteCommand(
            executable: "/bin/echo",
            arguments: ["it's", "$HOME", "a b"],
            priorityPrefix: ["nice", "-n", "19"]
        )
        let script = try RemoteCommand.script(for: command)
        #expect(script.hasPrefix("exec nice -n 19 /bin/echo 'it'\\''s' '$HOME' 'a b'"))
    }

    @Test("exports plain environment values with quoting")
    func exportsEnvironment() throws {
        let command = RemoteCommand(
            executable: "/bin/true",
            environment: ["RESTIC_REPOSITORY": "rest:http://127.0.0.1:8000/web-01/"]
        )
        let script = try RemoteCommand.script(for: command)
        #expect(script.contains("RESTIC_REPOSITORY=rest:http://127.0.0.1:8000/web-01/; export RESTIC_REPOSITORY"))
    }

    @Test("a real shell exports the secret and runs the command")
    func realShellRoundTrip() async throws {
        // Proves the read/export/exec sequence works in an actual POSIX shell,
        // which is the only place it matters.
        let secret = Secret(label: "token", value: "value-with spaces and 'quotes'")
        let command = RemoteCommand(
            executable: "/bin/sh",
            arguments: ["-c", "printf '%s' \"$MY_TOKEN\""],
            secretEnvironment: ["MY_TOKEN": secret]
        )
        let script = try RemoteCommand.script(for: command)
        let result = try await ProcessRunner().run(
            Command(
                path: "/bin/sh",
                arguments: ["-c", script],
                standardInput: .data(command.standardInputPayload()),
                additionalSecrets: [secret]
            )
        )
        #expect(result.standardOutput == "<secret:token>")
    }

    @Test("prefixes sudo only when the server needs it")
    func addsSudoWhenNeeded() async throws {
        let paths = try makeTemporaryPaths()
        let client = SSHClient(paths: paths, policy: .unrestricted)

        let rootCommand = try client.localCommand(
            for: RemoteCommand(executable: "/bin/true", requiresRoot: true),
            on: try makeDestination(privilege: .root)
        )
        #expect(!rootCommand.arguments.contains("sudo"))

        let sudoCommand = try client.localCommand(
            for: RemoteCommand(executable: "/bin/true", requiresRoot: true),
            on: try makeDestination(privilege: .sudo)
        )
        #expect(sudoCommand.arguments.contains("sudo"))
        #expect(sudoCommand.arguments.contains("-n"))

        let unprivileged = try client.localCommand(
            for: RemoteCommand(executable: "/bin/true", requiresRoot: false),
            on: try makeDestination(privilege: .sudo)
        )
        #expect(!unprivileged.arguments.contains("sudo"))
    }

    @Test("passes the managed config and never the user's")
    func usesManagedConfig() throws {
        let paths = try makeTemporaryPaths()
        let client = SSHClient(paths: paths, policy: .unrestricted)
        let local = try client.localCommand(
            for: RemoteCommand(executable: "/bin/true"),
            on: try makeDestination()
        )
        #expect(local.arguments.first == "-F")
        #expect(local.arguments[1] == paths.configFile.path)
        #expect(local.arguments.contains("hs-web-01"))
        #expect(!local.redactedDescription.contains("/.ssh/config"))
    }
}
