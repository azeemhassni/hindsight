import Foundation
import HindsightProcess
import Testing
@testable import HindsightSSH

@Suite("Shell quoting")
struct ShellQuotingTests {
    static let nastyValues = [
        "plain",
        "",
        " ",
        "with space",
        "it's",
        "two''quotes",
        "$HOME",
        "`whoami`",
        "$(id -u)",
        "a;rm -rf /",
        "a\nb",
        "a\tb",
        "back\\slash",
        "quote\"double",
        "glob*?[]",
        "pipe|and&",
        "héllo-ünïcode",
        "--flag=value",
        "/path/to/file.txt",
    ]

    @Test("leaves ordinary values unquoted")
    func leavesSafeValuesAlone() {
        #expect(ShellQuoting.quote("restic") == "restic")
        #expect(ShellQuoting.quote("/usr/bin/restic") == "/usr/bin/restic")
        #expect(ShellQuoting.quote("--tag=profile:full") == "--tag=profile:full")
        #expect(ShellQuoting.quote("") == "''")
    }

    @Test("a real shell reproduces the value exactly", arguments: nastyValues)
    func survivesARealShell(_ value: String) async throws {
        // The only honest test of quoting is to let a shell parse it.
        let result = try await ProcessRunner().run(
            Command(
                path: "/bin/sh",
                arguments: ["-c", "printf '%s' \(ShellQuoting.quote(value))"]
            )
        )
        #expect(result.standardOutput == value)
    }

    @Test("a shell reproduces a whole argument vector")
    func survivesArgumentVector() async throws {
        let argv = ["/bin/echo", "it's", "$HOME", "a b", "`x`"]
        let result = try await ProcessRunner().run(
            Command(path: "/bin/sh", arguments: ["-c", ShellQuoting.quote(argv)])
        )
        #expect(result.standardOutput == "it's $HOME a b `x`")
    }
}
