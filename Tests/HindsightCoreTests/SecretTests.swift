import Testing
@testable import HindsightCore

@Suite("Secrets")
struct SecretTests {
    @Test("a secret never prints its value")
    func neverPrintsValue() {
        let secret = Secret(label: "repo-password", value: "hunter2hunter2")
        #expect("\(secret)" == "<secret:repo-password>")
        #expect(String(reflecting: secret) == "<secret:repo-password>")
        #expect(!"\(secret)".contains("hunter2"))
    }

    @Test("redacts every occurrence across a line")
    func redactsAllOccurrences() {
        let redactor = SecretRedactor([Secret(label: "token", value: "s3cret")])
        #expect(redactor.redact("a s3cret b s3cret") == "a <secret:token> b <secret:token>")
    }

    @Test("redacts the longer secret when one contains another")
    func redactsLongestFirst() {
        let redactor = SecretRedactor([
            Secret(label: "short", value: "abc"),
            Secret(label: "long", value: "abcdef"),
        ])
        #expect(redactor.redact("value=abcdef") == "value=<secret:long>")
    }

    @Test("ignores empty secrets so innocuous output is left alone")
    func ignoresEmpty() {
        let redactor = SecretRedactor([Secret(label: "empty", value: "")])
        #expect(redactor.isEmpty)
        #expect(redactor.redact("nothing to hide") == "nothing to hide")
    }

    @Test("passes text through when nothing is registered")
    func passthrough() {
        #expect(SecretRedactor().redact("plain") == "plain")
    }

    @Test("adding secrets keeps earlier ones")
    func adding() {
        let redactor = SecretRedactor([Secret(label: "a", value: "aaa")])
            .adding([Secret(label: "b", value: "bbb")])
        #expect(redactor.redact("aaa bbb") == "<secret:a> <secret:b>")
    }
}
