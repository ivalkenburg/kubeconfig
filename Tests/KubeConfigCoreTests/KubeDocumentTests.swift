import XCTest
import Yams
@testable import KubeConfigCore

final class KubeDocumentTests: XCTestCase {
    func testRoundTripRetainsUnknownValuesExtensionsAndScalarTypes() throws {
        let original = try Fixtures.document()
        let reparsed = try KubeDocument(yaml: original.serialized())
        XCTAssertEqual(original, reparsed)
        XCTAssertEqual(reparsed.root["vendor-root"]?["enabled"]?.bool, true)
        let extensionValue = reparsed.entry(.clusters, named: "dev")!.fields["extensions"]!.array()[0]["extension"]!
        XCTAssertEqual(extensionValue["retries"]?.int, 3)
        XCTAssertEqual(extensionValue["label"]?.tag, Tag(.str))
    }

    func testEmptyConfigurationIsValid() throws { try KubeDocument.empty.validate() }

    func testNamespaceEditRetainsReferencesAndUnknownContextFields() throws {
        var doc = try Fixtures.document()
        let old = doc.entry(.contexts, named: "development")!
        try doc.update(.contexts, originalName: old.name, name: old.name, fields: ["namespace": "payments"])
        let edited = doc.entry(.contexts, named: old.name)!
        XCTAssertEqual(edited.value("namespace"), "payments")
        XCTAssertEqual(edited.value("cluster"), "dev")
        XCTAssertEqual(edited.fields["extensions"], old.fields["extensions"])
        try doc.validate()
    }

    func testClearingOptionalFieldActuallyRemovesIt() throws {
        var doc = try Fixtures.document()
        try doc.update(.contexts, originalName: "development", name: "development", fields: ["namespace": ""])
        XCTAssertNil(doc.entry(.contexts, named: "development")!.fields["namespace"])
        try doc.validate()
    }

    func testRenameClusterAndUserRewritesContextReferences() throws {
        var doc = try Fixtures.document()
        try doc.update(.clusters, originalName: "dev", name: "new-cluster", fields: [:])
        try doc.update(.users, originalName: "developer", name: "new-user", fields: [:])
        let context = doc.entry(.contexts, named: "development")!
        XCTAssertEqual(context.value("cluster"), "new-cluster")
        XCTAssertEqual(context.value("user"), "new-user")
        XCTAssertEqual(doc.entry(.users, named: "new-user")!.value("token"), "fixture-secret-token")
        try doc.validate()
    }

    func testRenameActiveContextPreservesActivation() throws {
        var doc = try Fixtures.document()
        try doc.update(.contexts, originalName: "development", name: "renamed", fields: [:])
        XCTAssertEqual(doc.currentContext, "renamed")
        XCTAssertNil(doc.entry(.contexts, named: "development"))
        try doc.validate()
    }

    func testRenameCollisionLeavesDocumentUnchanged() throws {
        var doc = try Fixtures.document()
        try doc.update(.contexts, originalName: nil, name: "other", fields: ["cluster": "dev"])
        let before = doc
        XCTAssertThrowsError(try doc.update(.contexts, originalName: "development", name: "other", fields: [:]))
        XCTAssertEqual(before, doc)
    }

    func testDeleteReferencedEntriesIsBlocked() throws {
        var doc = try Fixtures.document()
        let before = doc
        XCTAssertThrowsError(try doc.delete(.clusters, name: "dev"))
        XCTAssertThrowsError(try doc.delete(.users, name: "developer"))
        XCTAssertEqual(before, doc)
    }

    func testDeleteActiveContextNeedsExplicitClearing() throws {
        var doc = try Fixtures.document()
        XCTAssertThrowsError(try doc.delete(.contexts, name: "development"))
        try doc.setCurrentContext("")
        try doc.delete(.contexts, name: "development")
        try doc.delete(.users, name: "developer")
        try doc.delete(.clusters, name: "dev")
        try doc.validate()
    }

    func testActivationRejectsMissingContext() throws {
        var doc = try Fixtures.document()
        XCTAssertThrowsError(try doc.setCurrentContext("absent"))
        XCTAssertEqual(doc.currentContext, "development")
    }

    func testMissingReferencesAndBadServerAreValidationErrors() throws {
        var doc = try Fixtures.document()
        try doc.update(.contexts, originalName: "development", name: "development", fields: ["cluster": "missing", "user": "absent"])
        try doc.update(.clusters, originalName: "dev", name: "dev", fields: ["server": "not a url"])
        XCTAssertEqual(doc.validationIssues.count, 3)
        XCTAssertThrowsError(try doc.validate())
    }

    func testAnonymousContextIsAllowed() throws {
        var doc = try Fixtures.document()
        try doc.update(.contexts, originalName: "development", name: "development", fields: ["user": ""])
        try doc.validate()
    }

    func testDuplicateNamesAndKeysAreRejected() {
        XCTAssertThrowsError(try KubeDocument(yaml: "clusters: []\nclusters: []"))
        XCTAssertThrowsError(try KubeDocument(yaml: "users:\n- name: same\n  user: {}\n- name: same\n  user: {}"))
        XCTAssertThrowsError(try KubeDocument(yaml: "users:\n- name: user\n  user:\n    token: one\n    token: two"))
    }

    func testMalformedStructureAndMultipleDocumentsAreRejected() {
        for yaml in ["[]", "contexts: wrong", "contexts: [hello]", "users: [{name: true, user: {}}]", "kind: Config\n---\nkind: Config"] {
            XCTAssertThrowsError(try KubeDocument(yaml: yaml), yaml)
        }
    }

    func testSyntaxErrorHasLocationWithoutLeakingSource() {
        do {
            _ = try KubeDocument(yaml: "token: fixture-secret-token\ncontexts: [broken")
            XCTFail("Expected syntax failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("line"))
            XCTAssertFalse(error.localizedDescription.contains("fixture-secret-token"))
        }
    }

    func testRedactionCoversMultilineKeysExecArgumentsAndProviderTokens() throws {
        let yaml = """
        users:
        - name: example
          user:
            client-key-data: |
              PRIVATE KEY CONTENTS
            exec:
              command: provider
              args: [--secret, argument-secret]
              env: [{name: TOKEN, value: environment-secret}]
            auth-provider:
              name: provider
              config:
                access-token: access-secret
                refresh-token: refresh-secret
        """
        let redacted = try KubeDocument(yaml: yaml).serialized(revealingSecrets: false)
        for secret in ["PRIVATE KEY", "argument-secret", "environment-secret", "access-secret", "refresh-secret"] {
            XCTAssertFalse(redacted.contains(secret))
        }
        XCTAssertTrue(redacted.contains("provider"))
    }

    func testDiffMasksBothOldAndNewSecretsAndHandlesInvalidOriginal() throws {
        var doc = try Fixtures.document()
        try doc.update(.users, originalName: "developer", name: "developer", fields: ["token": "new-secret"])
        let text = try ConfigurationDiff.lines(before: Fixtures.yaml, after: doc).map(\.text).joined(separator: "\n")
        XCTAssertFalse(text.contains("fixture-secret-token"))
        XCTAssertFalse(text.contains("new-secret"))
        XCTAssertTrue(text.contains("changed secret"))
        let revealed = try ConfigurationDiff.lines(before: Fixtures.yaml, after: doc, reveal: true)
        XCTAssertTrue(revealed.contains { $0.change == .added && $0.text.contains("new-secret") })
        let invalid = try ConfigurationDiff.lines(before: "token: [PRIVATE", after: doc)
        XCTAssertFalse(invalid.map(\.text).joined().contains("PRIVATE"))
    }

    func testParsingExecConfigurationNeverExecutesIt() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let yaml = "users:\n- name: plugin\n  user:\n    exec:\n      command: /usr/bin/touch\n      args: [\(marker.path)]\n"
        let doc = try KubeDocument(yaml: yaml)
        _ = try doc.serialized()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testKnownFieldTypesAndMalformedPluginsAreBlocked() throws {
        for yaml in [
            "users: [{name: u, user: {token: 123}}]",
            "users: [{name: u, user: {exec: invalid}}]",
            "users: [{name: u, user: {exec: {command: plugin, args: [12]}}}]",
            "users: [{name: u, user: {exec: {command: plugin, env: [{name: TOKEN, value: 1}]}}}]",
            "clusters: [{name: c, cluster: {server: 'https://c.invalid', insecure-skip-tls-verify: 'false'}}]"
        ] {
            let doc = try KubeDocument(yaml: yaml)
            XCTAssertThrowsError(try doc.validate(), yaml)
        }
    }

    func testYamlAnchorsRetainIndependentValuesAfterEditing() throws {
        var doc = try KubeDocument(yaml: """
        clusters:
        - name: one
          cluster: &shared {server: 'https://one.invalid'}
        - name: two
          cluster: *shared
        """)
        try doc.update(.clusters, originalName: "one", name: "one", fields: ["server": "https://changed.invalid"])
        let reloaded = try KubeDocument(yaml: doc.serialized())
        XCTAssertEqual(reloaded.entry(.clusters, named: "one")?.value("server"), "https://changed.invalid")
        XCTAssertEqual(reloaded.entry(.clusters, named: "two")?.value("server"), "https://one.invalid")
    }
}
