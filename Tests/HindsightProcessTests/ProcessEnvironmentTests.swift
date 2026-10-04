import Foundation
import HindsightCore
import Testing
@testable import HindsightProcess

@Suite("Process environment")
struct ProcessEnvironmentTests {
    let runner = ProcessRunner()

    @Test("does not pass the parent environment beyond the allowlist")
    func doesNotInheritEverything() async throws {
        setenv("HINDSIGHT_TEST_LEAK", "leaked-value", 1)
        defer { unsetenv("HINDSIGHT_TEST_LEAK") }

        let result = try await runner.run(Command(path: "/usr/bin/env"))
        #expect(!result.standardOutput.contains("HINDSIGHT_TEST_LEAK"))
        #expect(!result.standardOutput.contains("leaked-value"))
    }

    @Test("inherits only the documented keys")
    func inheritsAllowlistOnly() async throws {
        setenv("HINDSIGHT_TEST_LEAK", "leaked-value", 1)
        defer { unsetenv("HINDSIGHT_TEST_LEAK") }

        let result = try await runner.run(
            Command(
                path: "/usr/bin/env",
                environment: Environment(inheritedKeys: ["HINDSIGHT_TEST_LEAK"])
            )
        )
        #expect(result.standardOutput.contains("HINDSIGHT_TEST_LEAK=leaked-value"))
        #expect(!result.standardOutput.contains("PATH="))
    }

    @Test("explicit values override inherited ones")
    func explicitValuesWin() async throws {
        let result = try await runner.run(
            Command(
                path: "/bin/sh",
                arguments: ["-c", "echo $PATH"],
                environment: Environment(values: ["PATH": "/hindsight/bin"])
            )
        )
        #expect(result.standardOutput == "/hindsight/bin")
    }

    @Test("passes secrets through the environment, never through arguments")
    func secretsTravelInEnvironment() async throws {
        let secret = Secret(label: "repo-password", value: "correct-horse-battery-staple")
        let command = Command(
            path: "/bin/sh",
            arguments: ["-c", "echo ${RESTIC_PASSWORD}"],
            environment: Environment(secretValues: ["RESTIC_PASSWORD": secret])
        )

        #expect(!command.redactedDescription.contains(secret.value))

        let result = try await runner.run(command)
        // The child does receive the real value; it is only the captured output
        // and any error text that must be redacted.
        #expect(result.standardOutput == "<secret:repo-password>")
    }
}

@Suite("Secret redaction in process output")
struct ProcessRedactionTests {
    let runner = ProcessRunner()

    @Test("redacts secrets from stdout, stderr, and the thrown error")
    func redactsEverywhere() async throws {
        let secret = Secret(label: "token", value: "SUPERSECRETVALUE")
        let command = Command(
            path: "/bin/sh",
            arguments: ["-c", "echo \"out=SUPERSECRETVALUE\"; echo \"err=SUPERSECRETVALUE\" 1>&2; exit 4"],
            additionalSecrets: [secret]
        )

        do {
            _ = try await runner.run(command)
            Issue.record("expected a failure")
        } catch let error as ProcessError {
            let description = "\(error)"
            #expect(!description.contains(secret.value))
            #expect(description.contains("<secret:token>"))
            guard case let .exitedWithFailure(commandDescription, _, standardError) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(!standardError.contains(secret.value))
            #expect(standardError == "err=<secret:token>")
            #expect(!commandDescription.contains(secret.value))
        }
    }

    @Test("redacts a secret that spans a read boundary")
    func redactsAcrossChunks() async throws {
        // Lines, not byte chunks, are the redaction unit; this proves it by
        // padding the line past a single pipe read.
        let secret = Secret(label: "token", value: "BOUNDARYSECRET")
        let padding = String(repeating: "p", count: 200_000)
        let command = Command(
            path: "/bin/sh",
            arguments: ["-c", "printf '%s' '\(padding)'; printf 'BOUNDARYSECRET\\n'"],
            additionalSecrets: [secret]
        )

        let result = try await runner.run(command)
        #expect(!result.standardOutput.contains(secret.value))
        #expect(result.standardOutput.hasSuffix("<secret:token>"))
    }
}
