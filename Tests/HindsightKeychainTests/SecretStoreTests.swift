import Foundation
import HindsightCore
import Testing
@testable import HindsightKeychain

@Suite("Secret store")
struct SecretStoreTests {
    private func serverID() throws -> ServerID { try ServerID(validating: "web-01") }

    @Test("names each secret distinctly and readably")
    func namesSecrets() throws {
        let id = try serverID()
        #expect(SecretKey.repositoryPassword(id).account == "repo-password/web-01")
        #expect(SecretKey.restServerCredential(id).account == "rest-credential/web-01")
        #expect(SecretKey.sshPrivateKey(id).account == "ssh-key/web-01")

        let accounts = Set([
            SecretKey.repositoryPassword(id),
            .restServerCredential(id),
            .sshPrivateKey(id),
        ].map(\.account))
        #expect(accounts.count == 3)
        #expect(SecretKey.repositoryPassword(id).label.contains("web-01"))
    }

    @Test("stores and reads a secret")
    func roundTrip() throws {
        let store = InMemorySecretStore()
        let key = SecretKey.repositoryPassword(try serverID())

        #expect(!store.contains(key))
        #expect(throws: SecretStoreError.notFound(account: key.account)) { try store.read(key) }

        try store.write("hunter2hunter2", for: key)
        #expect(store.contains(key))
        #expect(try store.read(key).value == "hunter2hunter2")

        try store.delete(key)
        #expect(!store.contains(key))
    }

    @Test("generates a strong password the first time and keeps it afterwards")
    func generatesOnce() throws {
        let store = InMemorySecretStore()
        let key = SecretKey.repositoryPassword(try serverID())

        let first = try store.readOrCreate(key)
        #expect(first.value.count >= 40)
        let second = try store.readOrCreate(key)
        #expect(second.value == first.value, "a repository password must never silently change")
    }

    @Test("generated passwords are not predictable")
    func generatesDistinctPasswords() {
        let values = Set((0..<32).map { _ in InMemorySecretStore.randomPassword() })
        #expect(values.count == 32)
    }

    @Test("a missing repository password says what it means")
    func explainsAMissingPassword() {
        let error = SecretStoreError.notFound(account: "repo-password/web-01")
        #expect("\(error)".contains("recovery kit"))
    }

    @Test("a secret never prints its value, even through the store")
    func neverPrintsValue() throws {
        let store = InMemorySecretStore()
        let key = SecretKey.repositoryPassword(try serverID())
        try store.write("super-secret-value", for: key)
        let secret = try store.read(key)
        #expect(!"\(secret)".contains("super-secret-value"))
    }

    /// Opt-in: touching the real login Keychain prompts, and a test suite that
    /// asks for a password is a test suite nobody runs.
    @Test(
        "round-trips through the real Keychain",
        .enabled(if: ProcessInfo.processInfo.environment["HINDSIGHT_TEST_KEYCHAIN"] == "1")
    )
    func realKeychainRoundTrip() throws {
        let keychain = Keychain(service: "app.hindsight.tests")
        let key = SecretKey.repositoryPassword(try ServerID(validating: "keychain-test"))
        try? keychain.delete(key)

        try keychain.write("value-under-test", for: key)
        #expect(keychain.contains(key))
        #expect(try keychain.read(key).value == "value-under-test")

        try keychain.write("replacement", for: key)
        #expect(try keychain.read(key).value == "replacement")

        try keychain.delete(key)
        #expect(!keychain.contains(key))
    }
}
