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

    func testBulkDeleteContextsClearsSelectedActiveContextAndRetainsRelatedEntries() throws {
        var document = try KubeDocument(yaml: """
        clusters:
        - {name: shared, cluster: {server: 'https://example.invalid'}}
        users:
        - {name: shared, user: {token: example}}
        contexts:
        - {name: a, context: {cluster: shared, user: shared}}
        - {name: b, context: {cluster: shared, user: shared}}
        current-context: a
        vendor-data: {enabled: true}
        """)
        try document.delete(.contexts, names: ["a", "b"])
        XCTAssertTrue(document.entries(.contexts).isEmpty)
        XCTAssertEqual(document.currentContext, "")
        XCTAssertEqual(document.entries(.clusters).map(\.name), ["shared"])
        XCTAssertEqual(document.entries(.users).map(\.name), ["shared"])
        XCTAssertEqual(document.root["vendor-data"]?["enabled"]?.bool, true)
        try document.validate()
    }

    func testBulkDeleteIsAtomicForMissingAndReferencedEntries() throws {
        let original = try KubeDocument(yaml: """
        clusters:
        - {name: free, cluster: {server: 'https://free.invalid'}}
        - {name: used, cluster: {server: 'https://used.invalid'}}
        users:
        - {name: free, user: {}}
        - {name: used, user: {}}
        contexts:
        - {name: a, context: {cluster: used, user: used}}
        - {name: b, context: {cluster: used, user: used}}
        current-context: a
        """)
        for kind in EntryKind.referenced {
            var document = original
            XCTAssertThrowsError(try document.delete(kind, names: ["free", "used"])) { error in
                for name in ["used", "a", "b"] { XCTAssertTrue(error.localizedDescription.contains(name)) }
            }
            XCTAssertEqual(document, original)
            XCTAssertThrowsError(try document.delete(kind, names: ["free", "missing"]))
            XCTAssertEqual(document, original)
        }
        var document = original
        XCTAssertThrowsError(try document.delete(.contexts, names: ["a", "missing"]))
        XCTAssertEqual(document, original, "A missing item must not clear the active context")
        try document.delete(.contexts, names: [])
        XCTAssertEqual(document, original)
    }

    func testBulkDeleteRetainsUnselectedEntriesAndUnknownFieldsInOrder() throws {
        for kind in EntryKind.referenced {
            var document = try KubeDocument(yaml: """
            \(kind.rawValue):
            - {name: c, \(kind.singular): {vendor-setting: keep}}
            - {name: a, \(kind.singular): {}}
            - {name: b, \(kind.singular): {}}
            """)
            try document.delete(kind, names: ["a", "b"])
            XCTAssertEqual(document.entries(kind).map(\.name), ["c"])
            XCTAssertEqual(document.entry(kind, named: "c")?.value("vendor-setting"), "keep")
        }
    }

    func testBulkReferencesGroupOnlySelectedEntriesAndKeepContextOrder() throws {
        let document = try KubeDocument(yaml: """
        contexts:
        - {name: z, context: {cluster: first, user: second}}
        - {name: a, context: {cluster: first, user: first}}
        - {name: b, context: {cluster: second, user: first}}
        - {name: unrelated, context: {cluster: other}}
        - {name: anonymous, context: {cluster: first}}
        """)
        XCTAssertEqual(document.referencingContexts(.clusters, names: ["first", "second", "free"]),
                       ["first": ["z", "a", "anonymous"], "second": ["b"]])
        XCTAssertEqual(document.referencingContexts(.users, names: ["first", "second", "free"]),
                       ["first": ["a", "b"], "second": ["z"]])
        XCTAssertEqual(document.referencingContexts(.clusters, names: ["first"]), ["first": ["z", "a", "anonymous"]])
        XCTAssertTrue(document.referencingContexts(.clusters, names: ["free"]).isEmpty)
        XCTAssertTrue(document.referencingContexts(.users, names: []).isEmpty)
        XCTAssertTrue(document.referencingContexts(.contexts, names: ["first"]).isEmpty)
    }

    func testBulkDeleteReportsAllBlockingEntriesWithoutDeletingFreeEntries() throws {
        var document = try KubeDocument(yaml: """
        clusters:
        - {name: first, cluster: {server: 'https://first.invalid'}}
        - {name: second, cluster: {server: 'https://second.invalid'}}
        - {name: free, cluster: {server: 'https://free.invalid'}}
        contexts:
        - {name: context-a, context: {cluster: first}}
        - {name: context-b, context: {cluster: second}}
        """)
        let original = document
        XCTAssertThrowsError(try document.delete(.clusters, names: ["first", "second", "free"])) { error in
            for name in ["first", "second", "context-a", "context-b"] { XCTAssertTrue(error.localizedDescription.contains(name)) }
        }
        XCTAssertEqual(document, original)
    }

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

    func testAddingCurrentContextToACRLFFileKeepsItsLineBreaks() {
        let crlf = "contexts:\r\n- {name: dev, context: {}}\r\n"
        XCTAssertEqual(KubeDocument.settingCurrentContext("dev", in: crlf), crlf + "current-context: dev\r\n")
    }

    func testAFileStartingWithAByteOrderMarkParses() throws {
        let doc = try KubeDocument(yaml: "\u{FEFF}" + Fixtures.yaml)
        XCTAssertEqual(doc, try Fixtures.document())
    }

    func testExplicitStringTagsStayStringsThroughSerialization() throws {
        let doc = try KubeDocument(yaml: "users:\n- name: u\n  user:\n    password: !!str 1234\n    token: !!str true\n")
        XCTAssertEqual(doc.validationIssues, [])
        let reloaded = try KubeDocument(yaml: doc.serialized())
        XCTAssertEqual(reloaded.validationIssues, [])
        XCTAssertEqual(reloaded, doc)
        XCTAssertEqual(reloaded.entry(.users, named: "u")?.value("password"), "1234")
    }

    func testValuesKubectlReadsAsOtherTypesAreQuoted() throws {
        for value in ["y", "Y", "n", "N", "+.5", "-.5", "+.5e3", "-.5e1", "+_1", "-_1", "1_000", "0X1F", "0B11", "0O17", "-0b11", "yes", "on", "0x1F", ".5", "1e3"] {
            var doc = try Fixtures.document()
            try doc.update(.contexts, originalName: "development", name: "development", fields: ["namespace": value])
            XCTAssertTrue(try doc.serialized().contains("namespace: '\(value)'"), value)
            XCTAssertEqual(try KubeDocument(yaml: doc.serialized()).entry(.contexts, named: "development")?.value("namespace"), value)
        }
        let quoted = Fixtures.yaml + "contexts-extra: true\n"
        let renamed = quoted.replacingOccurrences(of: "- name: development", with: "- name: 'n'").replacingOccurrences(of: "current-context: development", with: "current-context: ''")
        XCTAssertTrue(try XCTUnwrap(KubeDocument.settingCurrentContext("n", in: renamed)).contains("current-context: 'n'"))
    }

    func testOrdinaryValuesStayPlain() throws {
        for value in ["prod", "yellow", "no-such", "10.0.0.1", "1a", "0xZZ", "1.2.3", "-dash", "+plus", "_under"] {
            var doc = try Fixtures.document()
            try doc.update(.contexts, originalName: "development", name: "development", fields: ["namespace": value])
            XCTAssertTrue(try doc.serialized().contains("namespace: \(value)\n"), value)
        }
    }

    private func namedContext(_ value: String) -> String {
        """
        apiVersion: v1
        kind: Config
        clusters:
        - name: \(value)
          cluster: {server: https://example.test}
        users:
        - name: \(value)
          user: {}
        contexts:
        - name: \(value)
          context: {cluster: \(value), user: \(value), namespace: \(value)}
        current-context: \(value)
        """ + "\n"
    }

    /// kubectl reads each of these as a string, where YAML 1.1 has dates and base-60 numbers.
    func testDatesAndBase60ValuesAreStringsAsKubectlReadsThem() throws {
        for value in ["2024-01-01", "2024-1-1 10:00:00", "2001-12-14t21:59:43.10-05:00", "12:30", "1:30:00", "+1:30", "-1:30", "1:30.5", "="] {
            let yaml = namedContext(value)
            let doc = try KubeDocument(yaml: yaml)
            XCTAssertEqual(doc.validationIssues, [], value)
            XCTAssertEqual(doc.currentContext, value)
            XCTAssertEqual(doc.entries(.contexts).first?.name, value)
            XCTAssertEqual(try doc.serialized().contains("current-context: \(value)\n"), true, value)
            XCTAssertEqual(try KubeDocument(yaml: doc.serialized()), doc, value)
        }
    }

    func testFormsStillQuoteDatesSoOtherParsersKeepThemStrings() throws {
        var doc = try Fixtures.document()
        try doc.update(.contexts, originalName: "development", name: "development", fields: ["namespace": "2024-01-01"])
        XCTAssertTrue(try doc.serialized().contains("namespace: '2024-01-01'\n"))
    }

    func testValuesThatAreNumbersToBothParsersStayNumbers() throws {
        let doc = try KubeDocument(yaml: "a: 12\nb: 1.5\nc: 0x1f\nd: true\ne: ~\n")
        XCTAssertEqual(doc.root["a"]?.int, 12)
        XCTAssertEqual(doc.root["b"]?.tag, Tag(.float))
        XCTAssertEqual(doc.root["c"]?.tag, Tag(.int))
        XCTAssertEqual(doc.root["d"]?.bool, true)
        XCTAssertEqual(doc.root["e"]?.tag, Tag(.null))
    }

    func testRawAmbiguousScalarsAreRejectedInStringFieldsButQuotedValuesWork() throws {
        for value in ["y", "Y", "n", "N", "0X1F", "0B11", "0O17", "+.5", "-.5", ".5e3", "+_1", "-_1"] {
            let raw = try KubeDocument(yaml: "users: [{name: u, user: {token: \(value)}}]")
            XCTAssertTrue(raw.validationIssues.contains { $0.contains("token") && $0.contains("must be a string") }, value)
            let quoted = try KubeDocument(yaml: "users: [{name: u, user: {token: '\(value)'}}]")
            XCTAssertEqual(quoted.validationIssues, [], value)
            let reloaded = try KubeDocument(yaml: quoted.serialized())
            XCTAssertEqual(reloaded.entry(.users, named: "u")?.value("token"), value)
            XCTAssertEqual(reloaded.validationIssues, [], value)
        }
    }

    func testBooleanFlagsFollowClientGoIncludingSingleLetterValues() throws {
        for (expected, values) in [(true, ["y", "Y", "yes", "Yes", "YES", "true", "on"]),
                                   (false, ["n", "N", "no", "No", "NO", "false", "off"])] {
            for value in values {
                let yaml = "clusters: [{name: c, cluster: {server: 'https://c.invalid', insecure-skip-tls-verify: \(value)}}]"
                let doc = try KubeDocument(yaml: yaml)
                XCTAssertEqual(doc.validationIssues, [], value)
                XCTAssertEqual(doc.entry(.clusters, named: "c")?.booleanValue("insecure-skip-tls-verify"), expected, value)
                let reloaded = try KubeDocument(yaml: doc.serialized())
                XCTAssertEqual(reloaded.entry(.clusters, named: "c")?.booleanValue("insecure-skip-tls-verify"), expected, value)
            }
        }
        let quoted = try KubeDocument(yaml: "clusters: [{name: c, cluster: {server: 'https://c.invalid', insecure-skip-tls-verify: 'y'}}]")
        XCTAssertNil(quoted.entry(.clusters, named: "c")?.booleanValue("insecure-skip-tls-verify"))
        XCTAssertFalse(quoted.validationIssues.isEmpty)
    }

    func testOpaqueScalarTypesFollowClientGoAndSurviveSerialization() throws {
        for (value, tag) in [("y", Tag(.bool)), ("n", Tag(.bool)), ("0X1F", Tag(.int)),
                             ("0B11", Tag(.int)), ("0O17", Tag(.int)), ("+.5", Tag(.float)), (".5e3", Tag(.float))] {
            let doc = try KubeDocument(yaml: "vendor: {value: \(value)}")
            XCTAssertEqual(doc.root["vendor"]?["value"]?.tag, tag, value)
            let reloaded = try KubeDocument(yaml: doc.serialized())
            XCTAssertEqual(reloaded.root["vendor"]?["value"]?.tag, tag, value)
            XCTAssertEqual(reloaded.root["vendor"]?["value"]?.string, value)
        }
    }

    func testTagsSerializationWouldLoseBlockApply() throws {
        for (value, tag) in [("!!binary aGVsbG8=", "!!binary"), ("!custom foo", "!custom"), ("!!int \"5\"", "!!int"), ("!!timestamp 2024-01-01", "!!timestamp")] {
            let doc = try KubeDocument(yaml: "apiVersion: v1\nkind: Config\nusers:\n- name: u\n  user:\n    extra: \(value)\n")
            XCTAssertEqual(doc.validationIssues.count, 1, value)
            XCTAssertTrue(doc.validationIssues.first?.contains(tag) == true, value)
        }
        let wrapped = try KubeDocument(yaml: "apiVersion: v1\nkind: Config\nvendor: !custom {a: 1}\nlist: !other [1]\n")
        XCTAssertEqual(wrapped.validationIssues.count, 2)
    }

    func testTagsThatSurviveSerializationPassValidation() throws {
        let yaml = """
        apiVersion: v1
        kind: Config
        vendor: !!map
          count: !!int 5
          name: !!str 5
          flag: !!bool true
          empty: !!null
          list: !!seq [!!str a]
        """ + "\n"
        XCTAssertEqual(try KubeDocument(yaml: yaml).validationIssues, [])
    }

    func testASwitchKeepsATagThatApplyWouldLose() throws {
        let yaml = """
        apiVersion: v1
        kind: Config
        contexts:
        - {name: a, context: {}}
        - {name: b, context: {}}
        users:
        - name: u
          user: {token: !!binary aGVsbG8=}
        current-context: a
        """ + "\n"
        XCTAssertEqual(KubeDocument.settingCurrentContext("b", in: yaml), yaml.replacingOccurrences(of: "current-context: a", with: "current-context: b"))
    }

    func testLongFormStringTagsStayStringsThroughSerialization() throws {
        for yaml in ["a: !<tag:yaml.org,2002:str> 123\n", "%TAG !e! tag:yaml.org,2002:\n---\na: !e!str 123\n"] {
            XCTAssertEqual(try KubeDocument(yaml: KubeDocument(yaml: yaml).serialized()).root["a"]?.tag, Tag(.str), yaml)
        }
    }

    func testAnExplicitStringTagLeavesTheOtherValuesTheirTypes() throws {
        let doc = try KubeDocument(yaml: "a: !!str 123\nb: 123\nc: true\nd: ~\n")
        let reloaded = try KubeDocument(yaml: doc.serialized())
        XCTAssertEqual(reloaded.root["a"]?.tag, Tag(.str))
        XCTAssertEqual(reloaded.root["b"]?.int, 123)
        XCTAssertEqual(reloaded.root["c"]?.bool, true)
        XCTAssertNil(reloaded.root["d"]?.text)
    }

    func testAnErrorWithoutALocationStillLeavesTheSourceOut() {
        XCTAssertThrowsError(try KubeDocument(yaml: "token: secret\u{7}\n")) {
            XCTAssertEqual($0 as? ConfigError, .invalid("Could not parse the YAML. Check its encoding and syntax."))
        }
    }

    func testANullFieldIsNotSet() throws {
        let entry = try XCTUnwrap(KubeDocument(yaml: "users: [{name: u, user: {token: null, client-key-data: abc}}]").entry(.users, named: "u"))
        XCTAssertFalse(entry.has("token"))
        XCTAssertFalse(entry.has("password"))
        XCTAssertTrue(entry.has("client-key-data"))
    }

    func testEntriesByNameFindsEveryEntry() throws {
        let doc = try KubeDocument(yaml: "clusters: [{name: a, cluster: {}}, {name: b, cluster: {}}]")
        XCTAssertEqual(doc.entriesByName(.clusters).keys.sorted(), ["a", "b"])
        XCTAssertEqual(doc.entriesByName(.clusters)["b"], doc.entry(.clusters, named: "b"))
        XCTAssertEqual(doc.entriesByName(.users).count, 0)
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

    func testRenamingAClusterAddsNoContextListTheFileLeftOut() throws {
        var document = try KubeDocument(yaml: "apiVersion: v1\nkind: Config\nclusters:\n- name: a\n  cluster: {server: 'https://a.invalid'}\n")
        try document.update(.clusters, originalName: "a", name: "b", fields: [:])
        XCTAssertNil(document.root["contexts"])
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
        XCTAssertEqual(doc.validationIssues, ["namespace in context ‘x’ must be a string."])
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
        for server in ["ftp://cluster.example.invalid", "https://", "two words", "https://a.invalid/two words"] {
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

    func testResolvingPathsAddsNoListsTheFileLeftOut() throws {
        var doc = try KubeDocument(yaml: "clusters:\n- name: c\n  cluster: {server: 'https://c.invalid', certificate-authority: ca}\n")
        XCTAssertEqual(doc.resolveRelativePaths(relativeTo: URL(fileURLWithPath: "/base")), ["ca → /base/ca"])
        XCTAssertNil(doc.root["users"])
    }

    func testSizeNestingAndMergeKeyLimitsAreEnforced() throws {
        XCTAssertThrowsError(try KubeDocument(yaml: "a: " + String(repeating: "x", count: KubeDocument.maximumByteCount))) {
            XCTAssertEqual($0 as? ConfigError, .invalid("Configuration exceeds the 16 MB size limit."))
        }
        func nested(_ levels: Int) -> String { "a: " + String(repeating: "[", count: levels) + String(repeating: "]", count: levels) }
        XCTAssertNoThrow(try KubeDocument(yaml: nested(63)))
        XCTAssertThrowsError(try KubeDocument(yaml: nested(64))) {
            XCTAssertEqual($0 as? ConfigError, .invalid("YAML nesting exceeds 64 levels."))
        }
        XCTAssertThrowsError(try KubeDocument(yaml: "base: &base {a: 1}\nother:\n  <<: *base\n"))
    }

    func testTheBundledExampleIsValid() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let example = try KubeDocument(yaml: String(contentsOf: root.appendingPathComponent("Examples/sample-config.yaml"), encoding: .utf8))
        XCTAssertEqual(example.validationIssues, [])
        // The debug UI capture selects these two by name.
        XCTAssertNotNil(example.entry(.contexts, named: "development"))
        XCTAssertNotNil(example.entry(.contexts, named: "production-eu"))
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

    func testDiffAgainstAFileThatSerializesPastTheLimitShowsItsText() throws {
        // An alias writes its value out again, so this parses but can't be serialized.
        let value = String(repeating: "x", count: KubeDocument.maximumByteCount / 2 + 1)
        let lines = try ConfigurationDiff.lines(before: "a: &a \(value)\nb: *a\n", after: Fixtures.document())
        XCTAssertTrue(lines.contains { $0.change == .removed && $0.text == "b: *a" })
    }

    func testDiffSplitsLinesAtLineFeedsAlone() throws {
        let before = "not yaml: [\r\nsecond\u{2028}part\n\nlast"
        let lines = try ConfigurationDiff.lines(before: before, after: Fixtures.document())
        XCTAssertEqual(lines.filter { $0.change == .removed }.map(\.text), ["not yaml: [\r", "second\u{2028}part", "last"])
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
