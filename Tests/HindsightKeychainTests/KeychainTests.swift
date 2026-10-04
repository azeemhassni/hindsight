import Foundation
import HindsightCore
import Testing
@testable import HindsightKeychain


@Suite("Which keychain the secrets live in")
struct KeychainDomainTests {
    /// Asking for the data-protection keychain without the entitlement fails
    /// with -34018, so the choice is made from the signature rather than from
    /// the fact that a build happens to be signed.
    @Test("falls back to the login keychain without a keychain-access-groups entitlement")
    func followsTheEntitlement() {
        let domain = KeychainDomain.automatic
        if CodeIdentity.keychainAccessGroups.isEmpty {
            #expect(domain == .file)
            #expect(domain.accessGroup == nil)
        } else {
            #expect(domain == .dataProtection(accessGroup: CodeIdentity.keychainAccessGroups[0]))
        }
    }

    @Test("a file-keychain query carries no access group and no data-protection flag")
    func fileQueriesStayPlain() {
        let keychain = Keychain(service: "app.hindsight.test", domain: .file)
        #expect(keychain.accessGroup == nil)
        #expect(!keychain.domain.usesDataProtection)
    }

    @Test("explains itself in words someone could act on")
    func explainsItself() {
        #expect(KeychainDomain.file.explanation.contains("login keychain"))
        #expect(
            KeychainDomain.dataProtection(accessGroup: "ABC.app.hindsight")
                .explanation.contains("ABC.app.hindsight")
        )
    }
}

@Suite("Keychain failures a person can act on")
struct KeychainFailureMessageTests {
    /// -25293 means the item is there and this binary is not on its access
    /// list — almost always a differently signed build, which is not obvious
    /// from "refused access".
    @Test("explains an access list that does not name this build")
    func explainsAuthorizationFailure() {
        let message = "\(SecretStoreError.keychainFailure(account: "repo-password/web-01", status: -25293, keychain: "login keychain"))"
        #expect(message.contains("differently signed build"))
        #expect(message.contains("recovery kit"))
        #expect(message.contains("repo-password/web-01"))
    }

    @Test("says the same for a prompt the agent cannot answer")
    func explainsInteractionNotAllowed() {
        let message = "\(SecretStoreError.keychainFailure(account: "repo-password/web-01", status: -25308, keychain: "login keychain"))"
        #expect(message.contains("differently signed build"))
    }

    @Test("keeps the plain wording for anything else")
    func keepsPlainWording() {
        let message = "\(SecretStoreError.keychainFailure(account: "x", status: -42, keychain: "login keychain"))"
        #expect(message.contains("refused access to x (status -42)"))
    }
}
