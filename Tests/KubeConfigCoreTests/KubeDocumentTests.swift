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

    private func kubeconfig(_ active: String) -> String {
        """
        # top comment
        apiVersion: v1
        clusters: []
        contexts:
        - {name: dev, context: {}}
        - {name: "odd: name", context: {}}
        \(active)users: []   # trailing comment
        """ + "\n"
    }

    func testSettingCurrentContextChangesOnlyItsValue() throws {
        for (old, new) in [("current-context: dev\n", "current-context: 'odd: name'\n"),
                           ("current-context: \"dev\"\n", "current-context: 'odd: name'\n"),
                           ("current-context: 'dev'  # note\n", "current-context: 'odd: name'  # note\n"),
                           ("current-context: dev # note\n", "current-context: 'odd: name' # note\n"),
                           ("current-context:   # note\n", "current-context: 'odd: name' # note\n"),
                           ("current-context: dev\r\n", "current-context: 'odd: name'\r\n")] {
            let patched = try XCTUnwrap(KubeDocument.settingCurrentContext("odd: name", in: kubeconfig(old)), old)
            XCTAssertEqual(patched, kubeconfig(new))
            XCTAssertEqual(try KubeDocument(yaml: patched).currentContext, "odd: name")
        }
    }

    func testSettingCurrentContextAddsAMissingKeyAndClearsAValue() throws {
        let added = try XCTUnwrap(KubeDocument.settingCurrentContext("dev", in: kubeconfig("")))
        XCTAssertEqual(added, kubeconfig("") + "current-context: dev\n")
        let unterminated = String(kubeconfig("").dropLast())
        XCTAssertEqual(KubeDocument.settingCurrentContext("dev", in: unterminated), added)
        let cleared = try XCTUnwrap(KubeDocument.settingCurrentContext("", in: kubeconfig("current-context: dev\n")))
        XCTAssertEqual(try KubeDocument(yaml: cleared).currentContext, "")
        XCTAssertTrue(cleared.contains("# trailing comment"))
        XCTAssertEqual(KubeDocument.settingCurrentContext("", in: kubeconfig("")), kubeconfig(""))
    }

    func testSettingCurrentContextIsNilWhenThePatchCannotBeTrusted() {
        let multiLine = kubeconfig("current-context:\n  dev\n")
        let block = kubeconfig("current-context: |\n  dev\n")
        let nested = "contexts:\n- {name: dev, context: {}}\nnote: \"\ncurrent-context: other\n\"\n"
        let json = #"{"contexts": [{"name": "dev", "context": {}}], "current-context": ""}"#
        for yaml in [multiLine, block] { XCTAssertNil(KubeDocument.settingCurrentContext("odd: name", in: yaml), yaml) }
        for yaml in [nested, json, "not: [valid", ""] { XCTAssertNil(KubeDocument.settingCurrentContext("dev", in: yaml), yaml) }
        XCTAssertNil(KubeDocument.settingCurrentContext("missing", in: kubeconfig("current-context: dev\n")))
    }

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

    func testDeletingTheActiveContextLeavesAnIssueUntilItIsCleared() throws {
        var doc = try Fixtures.document()
        try doc.delete(.contexts, name: "development")
        XCTAssertEqual(doc.validationIssues, ["The active context ‘development’ does not exist."])
        try doc.setCurrentContext("")
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

    func testCredentialPluginNeedsACommand() throws {
        for exec in ["{apiVersion: v1}", "{command: ''}", "{command: 5}"] {
            let doc = try KubeDocument(yaml: "users: [{name: u, user: {exec: \(exec)}}]\n")
            XCTAssertEqual(doc.validationIssues, ["Credential plugin in user ‘u’ needs a command string."], exec)
        }
    }

    func testContextFieldsMustBeStrings() throws {
        let doc = try KubeDocument(yaml: "clusters: [{name: c, cluster: {server: 'https://c.invalid'}}]\ncontexts: [{name: x, context: {cluster: c, namespace: 5}}]\n")
        XCTAssertEqual(doc.validationIssues, ["Namespace in context ‘x’ must be a string."])
    }

    func testMappingKeysMustBeStrings() {
        XCTAssertThrowsError(try KubeDocument(yaml: "vendor: {1: a}\n")) {
            XCTAssertEqual($0 as? ConfigError, .invalid("YAML mapping keys must be strings."))
        }
    }

    func testDocumentLevelFieldsAreValidated() throws {
        let doc = try KubeDocument(yaml: "apiVersion: v2\nkind: Pod\ncurrent-context: 1\n")
        XCTAssertEqual(doc.validationIssues, ["apiVersion must be v1.", "kind must be Config.", "current-context must be a string.", "The active context ‘1’ does not exist."])
    }

    func testMissingClusterIsReportedWhetherEmptyOrDangling() throws {
        let doc = try KubeDocument(yaml: "contexts: [{name: empty, context: {}}, {name: dangling, context: {cluster: gone}}]")
        XCTAssertEqual(doc.validationIssues, ["Context ‘empty’ refers to a missing cluster.", "Context ‘dangling’ refers to a missing cluster."])
    }

    func testAuthenticationSummaryNamesTheStrongestMethod() throws {
        let cases: [(fields: String, summary: String)] = [
            ("{exec: {command: aws}, token: t}", "Credential plugin"),
            ("{auth-provider: {name: oidc}}", "Authentication provider"),
            ("{tokenFile: /t}", "Token"),
            ("{client-certificate-data: abc}", "Client certificate"),
            ("{username: u}", "Username & password"),
            ("{}", "No credentials"),
        ]
        for (fields, summary) in cases {
            let doc = try KubeDocument(yaml: "users: [{name: u, user: \(fields)}]")
            XCTAssertEqual(doc.entry(.users, named: "u")?.authenticationSummary, summary, fields)
        }
    }

    func testServerMayLeaveOutTheScheme() throws {
        for server in ["127.0.0.1:6443", "localhost:6443", "cluster.example.invalid"] {
            var document = try Fixtures.document()
            try document.update(.clusters, originalName: "dev", name: "dev", fields: ["server": server])
            XCTAssertEqual(document.validationIssues, [], server)
        }
        for server in ["ftp://cluster.example.invalid", "https://", "two words"] {
            var document = try Fixtures.document()
            try document.update(.clusters, originalName: "dev", name: "dev", fields: ["server": server])
            XCTAssertEqual(document.validationIssues.count, 1, server)
        }
    }

    func testServerSchemeIgnoresCase() throws {
        let yaml = Fixtures.yaml.replacingOccurrences(of: "https://dev.example.invalid", with: "HTTPS://dev.example.invalid")
        XCTAssertEqual(try KubeDocument(yaml: yaml).validationIssues, [])
    }

    func testRelativePathsLeaveAnUnfamiliarExecFieldOnAClusterAlone() throws {
        let yaml = Fixtures.yaml.replacingOccurrences(of: "certificate-authority: certs/ca.pem", with: "exec: {command: ./vendor-field}")
        let document = try KubeDocument(yaml: yaml)
        XCTAssertFalse(document.hasRelativePaths)
        var resolved = document
        XCTAssertEqual(resolved.resolveRelativePaths(relativeTo: URL(fileURLWithPath: "/test")), [])
        XCTAssertEqual(resolved, document)
    }

    func testRelativePathDetectionCoversFilesAndPluginsButNotBareCommands() throws {
        XCTAssertTrue(try KubeDocument(yaml: "clusters: [{name: c, cluster: {certificate-authority: ca.pem}}]").hasRelativePaths)
        XCTAssertTrue(try KubeDocument(yaml: "users: [{name: u, user: {exec: {command: ./plugin}}}]").hasRelativePaths)
        XCTAssertFalse(try KubeDocument(yaml: "users: [{name: u, user: {tokenFile: /t, exec: {command: aws}}}]").hasRelativePaths)
    }

    func testSizeNestingAndMergeKeyLimitsAreEnforced() {
        XCTAssertThrowsError(try KubeDocument(yaml: "a: " + String(repeating: "x", count: KubeDocument.maximumByteCount)))
        XCTAssertThrowsError(try KubeDocument(yaml: String(repeating: "[", count: 70) + String(repeating: "]", count: 70)))
        XCTAssertThrowsError(try KubeDocument(yaml: "base: &base {a: 1}\nother:\n  <<: *base\n"))
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

    func testAliasesCannotExpandBeyondTheNodeLimit() {
        var yaml = "a0: &a0 [x, x]\n"
        for level in 1...26 { yaml += "a\(level): &a\(level) [*a\(level - 1), *a\(level - 1)]\n" }
        XCTAssertThrowsError(try KubeDocument(yaml: yaml)) { XCTAssertTrue($0.localizedDescription.contains("values")) }
    }

    func testSyntaxErrorLinesAreOneBased() {
        XCTAssertThrowsError(try KubeDocument(yaml: "a: 1\nb: 2\n  c: 3\n")) { error in
            guard case ConfigError.syntax(let line, _) = error else { return XCTFail("Expected a syntax error, got \(error)") }
            XCTAssertEqual(line, 3)
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

    func testKeptSerializedTextDiffsLikeTheFileItCameFrom() throws {
        let before = "# a comment\n" + Fixtures.yaml
        let doc = try Fixtures.changed()
        let kept = try Fixtures.document().serialized()
        XCTAssertEqual(try ConfigurationDiff.lines(serializedBefore: kept, after: doc), try ConfigurationDiff.lines(before: before, after: doc))
        XCTAssertEqual(try ConfigurationDiff.changeCount(serializedBefore: kept, after: doc), 1)
    }

    func testDiffShowsCredentialsAndIgnoresFormattingOnly() throws {
        var doc = try Fixtures.document()
        try doc.update(.users, originalName: "developer", name: "developer", fields: ["token": "new-secret"])
        let lines = try ConfigurationDiff.lines(before: "# a comment\n" + Fixtures.yaml, after: doc)
        XCTAssertTrue(lines.contains { $0.change == .removed && $0.text.contains("fixture-secret-token") })
        XCTAssertTrue(lines.contains { $0.change == .added && $0.text.contains("new-secret") })
        XCTAssertEqual(lines.filter { $0.change != .unchanged }.count, 2)
    }

    func testDiffAgainstAnInvalidOriginalShowsItsText() throws {
        let lines = try ConfigurationDiff.lines(before: "contexts: [broken", after: Fixtures.document())
        XCTAssertTrue(lines.contains { $0.change == .removed && $0.text == "contexts: [broken" })
    }

    func testDiffAgainstAMissingFileAddsEveryLine() throws {
        let doc = try Fixtures.document()
        let lines = try ConfigurationDiff.lines(before: "", after: doc)
        XCTAssertEqual(lines.filter { $0.change == .added }.map(\.text).joined(separator: "\n") + "\n", try doc.serialized())
    }

    func testChangesGroupNeighboringLinesIntoSteps() throws {
        var doc = try Fixtures.document()
        try doc.update(.users, originalName: "developer", name: "developer", fields: ["token": "new"])
        try doc.update(.contexts, originalName: "development", name: "development", fields: ["namespace": "other"])
        let lines = try ConfigurationDiff.lines(before: Fixtures.yaml, after: doc)
        let changes = ConfigurationDiff.changes(in: lines)
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes.map(\.count), [2, 2])
        XCTAssertTrue(changes.allSatisfy { run in run.allSatisfy { lines[$0].change != .unchanged } })
        XCTAssertEqual(ConfigurationDiff.changes(in: []), [])
        let trailing = [DiffLine(id: 0, change: .unchanged, text: "a"), DiffLine(id: 1, change: .added, text: "b")]
        XCTAssertEqual(ConfigurationDiff.changes(in: trailing), [1..<2])
    }

    func testDiffKeepsBothSidesInOrder() throws {
        let before = "apiVersion: v1\nkind: Config\nclusters: []\nusers: []\ncontexts: []\ncurrent-context: ''\n"
        var doc = try KubeDocument(yaml: before)
        try doc.update(.clusters, originalName: nil, name: "one", fields: ["server": "https://one.invalid"])
        try doc.update(.clusters, originalName: nil, name: "two", fields: ["server": "https://two.invalid"])
        let lines = try ConfigurationDiff.lines(before: before, after: doc)
        let old = lines.filter { $0.change != .added }.map(\.text).joined(separator: "\n")
        let new = lines.filter { $0.change != .removed }.map(\.text).joined(separator: "\n")
        XCTAssertEqual(old, try KubeDocument(yaml: before).serialized())
        XCTAssertEqual(new, try doc.serialized())
        XCTAssertEqual(lines.map(\.id), Array(lines.indices))
    }

    func testFormValuesThatLookLikeOtherTypesStayStringsOnDisk() throws {
        for value in ["1234", "1.5", "0x10", "true", "yes", "null", "~", "2001-01-01"] {
            var doc = try Fixtures.document()
            try doc.update(.users, originalName: "developer", name: "developer", fields: ["password": value])
            let reloaded = try KubeDocument(yaml: doc.serialized())
            XCTAssertEqual(reloaded, doc, value)
            XCTAssertEqual(reloaded.entry(.users, named: "developer")?.value("password"), value)
            XCTAssertTrue(reloaded.validationIssues.isEmpty, value)
        }
    }

    func testNamesThatLookLikeOtherTypesSurviveAReload() throws {
        var doc = try Fixtures.document()
        try doc.update(.clusters, originalName: "dev", name: "123", fields: [:])
        try doc.update(.users, originalName: "developer", name: "true", fields: [:])
        try doc.update(.contexts, originalName: "development", name: "null", fields: [:])
        let reloaded = try KubeDocument(yaml: doc.serialized())
        XCTAssertEqual(reloaded.currentContext, "null")
        XCTAssertEqual(reloaded.entry(.contexts, named: "null")?.value("cluster"), "123")
        XCTAssertEqual(reloaded.entry(.contexts, named: "null")?.value("user"), "true")
        XCTAssertTrue(reloaded.validationIssues.isEmpty)
    }

    func testYAMLNullsReadAsAbsentInsteadOfAsText() throws {
        for current in ["null", "~", ""] {
            let doc = try KubeDocument(yaml: "current-context: \(current)\n")
            XCTAssertEqual(doc.currentContext, "", current)
            XCTAssertTrue(doc.validationIssues.isEmpty, current)
        }
        let doc = try KubeDocument(yaml: """
        clusters: [{name: c, cluster: {server: 'https://c.invalid', certificate-authority: null}}]
        users: [{name: u, user: {client-key: ~, token: null, username: u}}]
        contexts: [{name: x, context: {cluster: c, user: null, namespace: ~}}]
        """)
        XCTAssertEqual(doc.entry(.contexts, named: "x")?.value("user"), "")
        XCTAssertEqual(doc.entry(.contexts, named: "x")?.value("namespace"), "")
        XCTAssertEqual(doc.entry(.users, named: "u")?.authenticationSummary, "Username & password")
        XCTAssertFalse(doc.hasRelativePaths)
        XCTAssertTrue(doc.validationIssues.isEmpty)
    }

    func testAQuotedNullIsAnOrdinaryName() throws {
        let doc = try KubeDocument(yaml: "clusters: [{name: c, cluster: {server: 'https://c.invalid'}}]\ncontexts: [{name: 'null', context: {cluster: c}}]\ncurrent-context: 'null'\n")
        XCTAssertEqual(doc.currentContext, "null")
        XCTAssertTrue(doc.validationIssues.isEmpty)
    }

    func testPlainMergeKeysGetTheirOwnExplanation() {
        XCTAssertThrowsError(try KubeDocument(yaml: "base: &base {a: 1}\nother:\n  <<: *base\n")) {
            XCTAssertTrue($0.localizedDescription.contains("merge keys"), $0.localizedDescription)
        }
    }

    func testDuplicateKeysNameTheKeyAndItsLine() {
        XCTAssertThrowsError(try KubeDocument(yaml: "users:\n- name: u\n  user:\n    token: fixture-secret\n    \"token\": two\n")) { error in
            XCTAssertEqual(error as? ConfigError, .duplicateKey("token", line: 4))
            XCTAssertEqual((error as? ConfigError)?.line, 4)
            XCTAssertFalse(error.localizedDescription.contains("fixture-secret"))
        }
    }

    func testOnlyLocatedErrorsCarryALine() {
        XCTAssertEqual(ConfigError.syntax(line: 3, column: 1).line, 3)
        XCTAssertNil(ConfigError.invalid("x").line)
        XCTAssertNil(ConfigError.externalChange.line)
    }

    func testSeveralNewFieldsLandInAStableOrder() throws {
        var doc = KubeDocument.empty
        try doc.update(.contexts, originalName: nil, name: "c", fields: ["user": "u", "namespace": "n", "cluster": "k"])
        XCTAssertEqual(doc.entry(.contexts, named: "c")?.fields.mapping?.keys.compactMap(\.string), ["cluster", "namespace", "user"])
    }

    func testEditingAnEntryThatIsGoneReportsIt() throws {
        var doc = try Fixtures.document()
        XCTAssertThrowsError(try doc.update(.users, originalName: "nobody", name: "nobody", fields: [:])) {
            XCTAssertEqual($0 as? ConfigError, .missingEntry("nobody"))
        }
        XCTAssertThrowsError(try doc.delete(.users, name: "nobody")) {
            XCTAssertEqual($0 as? ConfigError, .missingEntry("nobody"))
        }
    }

    func testNamesAreTrimmedBeforeTheyAreCheckedAndStored() throws {
        var doc = try Fixtures.document()
        XCTAssertNil(doc.nameIssue(.clusters, name: "dev", originalName: "dev"))
        XCTAssertEqual(doc.nameIssue(.clusters, name: "  dev ", originalName: nil), "A cluster named ‘dev’ already exists.")
        try doc.update(.clusters, originalName: "dev", name: "  spaced  ", fields: [:])
        XCTAssertNotNil(doc.entry(.clusters, named: "spaced"))
        XCTAssertEqual(doc.entry(.contexts, named: "development")?.value("cluster"), "spaced")
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
