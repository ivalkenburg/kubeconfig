import XCTest
import Yams
@testable import KubeConfigCore

final class ImportTests: XCTestCase {
    private let source = URL(fileURLWithPath: "/test/provider", isDirectory: true)

    func testCollisionRenamesAndRewritesAllReferences() throws {
        let target = try Fixtures.document()
        let imported = try KubeDocument(yaml: Fixtures.yaml.replacingOccurrences(of: "https://dev.example.invalid", with: "https://new.example.invalid").replacingOccurrences(of: "fixture-secret-token", with: "new-token"))
        let plan = try ImportPlan(target: target, incoming: imported, sourceDirectory: source)
        let merged = try plan.merged(into: target)
        let context = merged.entry(.contexts, named: "development-imported")!
        XCTAssertEqual(context.value("cluster"), "dev-imported")
        XCTAssertEqual(context.value("user"), "developer-imported")
        XCTAssertEqual(merged.entry(.clusters, named: "dev")!.value("server"), "https://dev.example.invalid")
        XCTAssertEqual(merged.currentContext, "development")
        try merged.validate()
    }

    func testIdenticalEntriesAreReusedEvenIfMappingOrderDiffers() throws {
        let target = try KubeDocument(yaml: "clusters:\n- name: x\n  cluster: {server: 'https://x.invalid', tls-server-name: x}\n")
        let incoming = try KubeDocument(yaml: "clusters:\n- cluster: {tls-server-name: x, server: 'https://x.invalid'}\n  name: x\n")
        let plan = try ImportPlan(target: target, incoming: incoming, sourceDirectory: nil)
        XCTAssertEqual(plan.items.first?.action, .reuse)
        XCTAssertEqual(try plan.merged(into: target).entries(.clusters).count, 1)
    }

    func testContextIsNotReusedWhenClusterReferenceWillBeRenamed() throws {
        let target = try Fixtures.document()
        let incoming = try KubeDocument(yaml: Fixtures.yaml.replacingOccurrences(of: "https://dev.example.invalid", with: "https://new.invalid"))
        let plan = try ImportPlan(target: target, incoming: incoming, sourceDirectory: source)
        XCTAssertEqual(plan.items.first { $0.kind == .contexts }?.action, .rename)
    }

    func testGeneratedNamesAvoidNamesInBothFiles() throws {
        var target = try Fixtures.document()
        try target.update(.clusters, originalName: nil, name: "dev-imported", fields: ["server": "https://other.invalid"])
        let plan = try ImportPlan(target: target, incoming: Fixtures.document(), sourceDirectory: source)
        XCTAssertEqual(plan.items.first { $0.kind == .clusters }?.destinationName, "dev-imported-2")
    }

    func testReplaceUsesOriginalNameAndKeepsExistingContextReferences() throws {
        let target = try Fixtures.document()
        let incoming = try KubeDocument(yaml: "clusters:\n- name: dev\n  cluster: {server: 'https://replacement.invalid'}")
        var plan = try ImportPlan(target: target, incoming: incoming, sourceDirectory: nil)
        plan.items[0].action = .replace
        let merged = try plan.merged(into: target)
        XCTAssertEqual(merged.entries(.clusters).count, 1)
        XCTAssertEqual(merged.entry(.clusters, named: "dev")!.value("server"), "https://replacement.invalid")
        XCTAssertEqual(merged.entry(.contexts, named: "development")!.value("cluster"), "dev")
    }

    func testMixedActionsPreserveOrderAndRewriteOnlyImportedReferences() throws {
        let target = try KubeDocument(yaml: """
        clusters:
        - {name: renamed, cluster: {server: 'https://old.invalid'}}
        - {name: replaced, cluster: {server: 'https://old.invalid'}}
        - {name: shared, cluster: {server: 'https://shared.invalid'}}
        - {name: skipped, cluster: {server: 'https://kept.invalid'}}
        contexts: [{name: active, context: {cluster: shared}}]
        current-context: active
        """)
        let incoming = try KubeDocument(yaml: """
        clusters:
        - {name: renamed, cluster: {server: 'https://renamed.invalid'}}
        - {name: replaced, cluster: {server: 'https://replacement.invalid'}}
        - {name: shared, cluster: {server: 'https://shared.invalid'}}
        - {name: skipped, cluster: {server: 'https://ignored.invalid'}}
        - {name: added, cluster: {server: 'https://added.invalid'}}
        contexts:
        - {name: use-renamed, context: {cluster: renamed}}
        - {name: use-replaced, context: {cluster: replaced}}
        - {name: use-shared, context: {cluster: shared}}
        - {name: use-skipped, context: {cluster: skipped}}
        - {name: use-added, context: {cluster: added}}
        """)
        var plan = try ImportPlan(target: target, incoming: incoming, sourceDirectory: nil)
        plan.items[0].destinationName = "chosen"
        plan.items[1].action = .replace
        XCTAssertEqual(plan.items[2].action, .reuse)
        plan.items[3].action = .skip
        let merged = try plan.merged(into: target)
        XCTAssertEqual(merged.entries(.clusters).map(\.name), ["renamed", "replaced", "shared", "skipped", "chosen", "added"])
        XCTAssertEqual(merged.entry(.clusters, named: "renamed")?.value("server"), "https://old.invalid")
        XCTAssertEqual(merged.entry(.clusters, named: "replaced")?.value("server"), "https://replacement.invalid")
        XCTAssertEqual(merged.entry(.clusters, named: "skipped")?.value("server"), "https://kept.invalid")
        XCTAssertEqual(merged.entry(.contexts, named: "use-renamed")?.value("cluster"), "chosen")
        for name in ["replaced", "shared", "skipped", "added"] {
            XCTAssertEqual(merged.entry(.contexts, named: "use-" + name)?.value("cluster"), name)
        }
        XCTAssertEqual(merged.currentContext, "active")
    }

    func testSkippingRequiredNewClusterBlocksImport() throws {
        let target = KubeDocument.empty
        var plan = try ImportPlan(target: target, incoming: Fixtures.document(), sourceDirectory: source)
        plan.items[0].action = .skip
        XCTAssertThrowsError(try plan.merged(into: target))
        XCTAssertEqual(target.entries(.clusters).count, 0)
    }

    func testCustomDestinationNameKeepsActiveContextEmpty() throws {
        let target = KubeDocument.empty
        var plan = try ImportPlan(target: target, incoming: Fixtures.document(), sourceDirectory: source)
        let clusterIndex = plan.items.firstIndex { $0.kind == .clusters }!
        plan.items[clusterIndex].destinationName = "chosen"
        let result = try plan.merged(into: target)
        XCTAssertEqual(result.entry(.contexts, named: "development")!.value("cluster"), "chosen")
        XCTAssertEqual(result.currentContext, "")
    }

    func testImportResolvesFileAndRelativePluginPathsButNotBareCommands() throws {
        let yaml = """
        clusters:
        - name: x
          cluster: {server: 'https://x.invalid', certificate-authority: certs/ca}
        users:
        - name: relative
          user:
            client-key: ../key
            client-certificate: cert
            tokenFile: /absolute/token
            exec: {command: ./bin/plugin}
        - name: bare
          user:
            exec: {command: aws}
        """
        let doc = try KubeDocument(yaml: yaml)
        XCTAssertThrowsError(try ImportPlan(target: .empty, incoming: doc, sourceDirectory: nil))
        let plan = try ImportPlan(target: .empty, incoming: doc, sourceDirectory: source)
        XCTAssertEqual(plan.resolvedPaths.count, 4)
        let merged = try plan.merged(into: .empty)
        XCTAssertEqual(merged.entry(.users, named: "relative")!.value("client-key"), "/test/key")
        XCTAssertEqual(merged.entry(.users, named: "relative")!.value("tokenFile"), "/absolute/token")
        XCTAssertEqual(merged.entry(.users, named: "relative")!.fields["exec"]?["command"]?.string, "/test/provider/bin/plugin")
        XCTAssertEqual(merged.entry(.users, named: "bare")!.fields["exec"]?["command"]?.string, "aws")
    }

    func testTildePathsResolveLikeAnyOtherRelativePath() throws {
        let doc = try KubeDocument(yaml: "clusters: [{name: x, cluster: {server: 'https://x.invalid', certificate-authority: ~/ca}}]")
        XCTAssertThrowsError(try ImportPlan(target: .empty, incoming: doc, sourceDirectory: nil))
        let merged = try ImportPlan(target: .empty, incoming: doc, sourceDirectory: source).merged(into: .empty)
        XCTAssertEqual(merged.entry(.clusters, named: "x")?.value("certificate-authority"), "/test/provider/~/ca")
    }

    func testRenamingAnIdenticalEntryStartsFromAFreeName() throws {
        let doc = try KubeDocument(yaml: "clusters: [{name: dev, cluster: {server: 'https://dev.invalid'}}]")
        var plan = try ImportPlan(target: doc, incoming: doc, sourceDirectory: nil)
        XCTAssertEqual(plan.items[0].action, .reuse)
        plan.items[0].action = .rename
        XCTAssertNotNil(try plan.merged(into: doc).entry(.clusters, named: "dev-imported"))
    }

    func testAPathSharedByEntriesIsListedOnce() throws {
        let incoming = try KubeDocument(yaml: "users: [{name: a, user: {client-key: key}}, {name: b, user: {client-key: key}}]\n")
        let plan = try ImportPlan(target: .empty, incoming: incoming, sourceDirectory: source)
        XCTAssertEqual(plan.resolvedPaths, ["key → /test/provider/key"])
        XCTAssertEqual(plan.incoming.entry(.users, named: "b")?.value("client-key"), "/test/provider/key")
    }

    func testImportedOpaqueMetadataIsPreservedAndConflictsAreNotSilentlyDropped() throws {
        let target = try KubeDocument(yaml: "preferences: {one: 1}\nvendor: {value: existing}\n")
        let source = try KubeDocument(yaml: "preferences: {two: 2}\nnew-vendor: {flag: true}\n")
        let plan = try ImportPlan(target: target, incoming: source, sourceDirectory: nil)
        let result = try plan.merged(into: target)
        XCTAssertEqual(result.root["preferences"]?["one"]?.int, 1)
        XCTAssertEqual(result.root["preferences"]?["two"]?.int, 2)
        XCTAssertEqual(result.root["new-vendor"]?["flag"]?.bool, true)
        let conflicting = try KubeDocument(yaml: "vendor: {value: different}")
        XCTAssertThrowsError(try ImportPlan(target: target, incoming: conflicting, sourceDirectory: nil).merged(into: target))
    }

    func testNullMetadataNeverConflicts() throws {
        let empty = try KubeDocument(yaml: "preferences: null\n")
        let filled = try KubeDocument(yaml: "preferences: {colors: true}\n")
        XCTAssertEqual(try ImportPlan(target: empty, incoming: filled, sourceDirectory: nil).merged(into: empty).root["preferences"]?["colors"]?.bool, true)
        XCTAssertEqual(try ImportPlan(target: filled, incoming: empty, sourceDirectory: nil).merged(into: filled).root["preferences"]?["colors"]?.bool, true)
    }

    func testAContextCannotLandOnAnEntryRenamedToASkippedName() throws {
        let target = try KubeDocument(yaml: "clusters: [{name: a, cluster: {server: 'https://target.invalid'}}]")
        let incoming = try KubeDocument(yaml: """
        clusters:
        - {name: a, cluster: {server: 'https://a.invalid'}}
        - {name: b, cluster: {server: 'https://b.invalid'}}
        contexts:
        - {name: cb, context: {cluster: b}}
        """)
        var plan = try ImportPlan(target: target, incoming: incoming, sourceDirectory: nil)
        plan.items[0].destinationName = "b"
        plan.items[1].action = .skip
        XCTAssertThrowsError(try plan.merged(into: target)) {
            XCTAssertTrue(($0 as? ConfigError)?.errorDescription?.contains("cb") == true)
        }
        plan.items[2].action = .skip
        let merged = try plan.merged(into: target)
        XCTAssertEqual(merged.entry(.clusters, named: "b")?.value("server"), "https://a.invalid", "With nothing referring to it, the name is free")
    }

    func testMetadataKeysThatLookLikeOtherTypesKeepTheirIdentity() throws {
        let target = try KubeDocument(yaml: "preferences: {\"123\": 1}\n\"yes\": 1\n")
        let incoming = try KubeDocument(yaml: "preferences: {\"123\": 1, other: 2}\n\"yes\": 1\n\"456\": new\n")
        let merged = try ImportPlan(target: target, incoming: incoming, sourceDirectory: nil).merged(into: target)
        let reloaded = try KubeDocument(yaml: merged.serialized())
        XCTAssertEqual(reloaded.root.mapping?.count, merged.root.mapping?.count)
        XCTAssertEqual(reloaded.root["preferences"]?.mapping?.count, 2)
        XCTAssertEqual(reloaded.root.mapping?[Node("456", Tag(.str))]?.string, "new")
    }

    func testMetadataMappingsCombineKeysFromBothFiles() throws {
        let target = try KubeDocument(yaml: "preferences: {nested: {old: 1}}\n")
        let incoming = try KubeDocument(yaml: "preferences: {nested: {new: 2}}\n")
        let nested = try ImportPlan(target: target, incoming: incoming, sourceDirectory: nil).merged(into: target).root["preferences"]?["nested"]
        XCTAssertEqual(nested?["old"]?.int, 1)
        XCTAssertEqual(nested?["new"]?.int, 2)
    }

    func testImportAddsNoListsNeitherFileHas() throws {
        let target = try KubeDocument(yaml: "apiVersion: v1\nkind: Config\nclusters:\n- name: a\n  cluster: {server: 'https://a.invalid'}\n")
        let incoming = try KubeDocument(yaml: "apiVersion: v1\nkind: Config\nclusters:\n- name: b\n  cluster: {server: 'https://b.invalid'}\n")
        let merged = try ImportPlan(target: target, incoming: incoming, sourceDirectory: nil).merged(into: target)
        XCTAssertEqual(merged.entries(.clusters).map(\.name), ["a", "b"])
        XCTAssertNil(merged.root["users"])
        XCTAssertNil(merged.root["contexts"])
    }

    func testReplaceAddsTheEntryWhenItIsNoLongerInTheDraft() throws {
        let doc = try KubeDocument(yaml: "clusters: [{name: dev, cluster: {server: 'https://dev.invalid'}}]")
        let changed = try KubeDocument(yaml: "clusters: [{name: dev, cluster: {server: 'https://new.invalid'}}]")
        var plan = try ImportPlan(target: doc, incoming: changed, sourceDirectory: nil)
        plan.items[0].action = .replace
        XCTAssertEqual(try plan.merged(into: .empty).entry(.clusters, named: "dev")?.value("server"), "https://new.invalid")
    }

    func testMetadataListsMergeUnlessANamedItemDiffers() throws {
        let target = try KubeDocument(yaml: "extensions: [{name: a, value: 1}]\n")
        let added = try KubeDocument(yaml: "extensions: [{name: a, value: 1}, {name: b, value: 2}]\n")
        let merged = try ImportPlan(target: target, incoming: added, sourceDirectory: nil).merged(into: target)
        XCTAssertEqual(merged.root["extensions"]?.array().count, 2)
        let conflicting = try KubeDocument(yaml: "extensions: [{name: a, value: 9}]\n")
        XCTAssertThrowsError(try ImportPlan(target: target, incoming: conflicting, sourceDirectory: nil).merged(into: target))
    }

    func testDestinationNamesMustBeUsableAndUnique() throws {
        let target = try Fixtures.document()
        let incoming = try KubeDocument(yaml: "clusters: [{name: a, cluster: {server: 'https://a.invalid'}}, {name: b, cluster: {server: 'https://b.invalid'}}]\n")
        let plan = try ImportPlan(target: target, incoming: incoming, sourceDirectory: nil)
        var blank = plan
        blank.items[0].destinationName = "   "
        XCTAssertThrowsError(try blank.merged(into: target))
        var repeated = plan
        repeated.items[0].destinationName = "same"
        repeated.items[1].destinationName = " same "
        XCTAssertThrowsError(try repeated.merged(into: target)) { XCTAssertTrue($0.localizedDescription.contains("same")) }
        var taken = plan
        taken.items[0].destinationName = "dev"
        XCTAssertThrowsError(try taken.merged(into: target)) { XCTAssertTrue($0.localizedDescription.contains("dev")) }
    }

    func testReuseIsRefusedOnceAReferenceNoLongerMatches() throws {
        let target = try KubeDocument(yaml: "clusters: [{name: c, cluster: {server: 'https://c.invalid'}}]\ncontexts: [{name: x, context: {cluster: c}}]\n")
        var plan = try ImportPlan(target: target, incoming: target, sourceDirectory: nil)
        let cluster = plan.items.firstIndex { $0.kind == .clusters }!
        XCTAssertEqual(plan.items[cluster].action, .reuse)
        plan.items[cluster].action = .rename
        plan.items[cluster].destinationName = "elsewhere"
        XCTAssertThrowsError(try plan.merged(into: target)) { XCTAssertTrue($0.localizedDescription.contains("no longer identical")) }
    }

    func testImportingARenamedContextKeepsTheExistingActiveContext() throws {
        let target = try KubeDocument(yaml: Fixtures.yaml.replacingOccurrences(of: "namespace: default", with: "namespace: other"))
        let plan = try ImportPlan(target: target, incoming: Fixtures.document(), sourceDirectory: source)
        let merged = try plan.merged(into: target)
        XCTAssertEqual(merged.currentContext, "development")
        XCTAssertEqual(merged.entry(.contexts, named: "development")?.value("namespace"), "other")
        XCTAssertEqual(merged.entry(.contexts, named: "development-imported")?.value("namespace"), "default")
    }

    func testSkippingTheIncomingActiveContextKeepsTheExistingActiveContext() throws {
        let target = try KubeDocument(yaml: Fixtures.yaml.replacingOccurrences(of: "namespace: default", with: "namespace: other"))
        var plan = try ImportPlan(target: target, incoming: Fixtures.document(), sourceDirectory: source)
        plan.items[plan.items.firstIndex { $0.kind == .contexts && $0.originalName == "development" }!].action = .skip
        let merged = try plan.merged(into: target)
        XCTAssertEqual(merged.currentContext, "development")
        XCTAssertNil(merged.entry(.contexts, named: "development-imported"))
    }

    func testIncomingCurrentContextIsIgnoredWhenNoContextsAreImported() throws {
        let target = try Fixtures.document()
        let incoming = try KubeDocument(yaml: "current-context: missing\n")
        let plan = try ImportPlan(target: target, incoming: incoming, sourceDirectory: nil)
        XCTAssertEqual(try plan.merged(into: target), target)
    }

    func testReusingAContextDoesNotActivateIt() throws {
        let shared = "clusters: [{name: c, cluster: {server: 'https://c.invalid'}}]\ncontexts: [{name: shared, context: {cluster: c}}]\n"
        let target = try KubeDocument(yaml: shared)
        let plan = try ImportPlan(target: target, incoming: KubeDocument(yaml: shared + "current-context: shared\n"), sourceDirectory: nil)
        XCTAssertEqual(plan.items.last?.action, .reuse)
        let merged = try plan.merged(into: target)
        XCTAssertEqual(merged.currentContext, "")
        XCTAssertNil(merged.root["current-context"])
    }

    func testANullReferenceIsNotMistakenForAnEntryNamedNull() throws {
        let target = try KubeDocument(yaml: "users: [{name: 'null', user: {token: a}}]\n")
        let incoming = try KubeDocument(yaml: """
        clusters: [{name: c, cluster: {server: 'https://c.invalid'}}]
        users: [{name: 'null', user: {token: b}}]
        contexts: [{name: x, context: {cluster: c, user: null}}]
        """)
        let merged = try ImportPlan(target: target, incoming: incoming, sourceDirectory: nil).merged(into: target)
        XCTAssertEqual(merged.entry(.contexts, named: "x")?.value("user"), "")
        XCTAssertNotNil(merged.entry(.users, named: "null-imported"))
    }

    func testImportRejectsAmbiguousPlainCredentialsAndAcceptsQuotedOnes() throws {
        for value in ["y", "n", "0X1F", "0B11", "+.5", ".5e3"] {
            let incoming = try KubeDocument(yaml: "users: [{name: u, user: {token: \(value)}}]")
            let plan = try ImportPlan(target: .empty, incoming: incoming, sourceDirectory: nil)
            XCTAssertThrowsError(try plan.merged(into: .empty)) {
                XCTAssertTrue($0.localizedDescription.contains("token"), value)
            }
            let quoted = try KubeDocument(yaml: "users: [{name: u, user: {token: '\(value)'}}]")
            let merged = try ImportPlan(target: .empty, incoming: quoted, sourceDirectory: nil).merged(into: .empty)
            XCTAssertEqual(merged.entry(.users, named: "u")?.value("token"), value)
        }
    }

    func testImportRejectsWrongConfigurationKindAndVersion() throws {
        for yaml in ["apiVersion: v2\nkind: Config", "apiVersion: v1\nkind: Pod"] {
            XCTAssertThrowsError(try ImportPlan(target: .empty, incoming: KubeDocument(yaml: yaml), sourceDirectory: nil))
        }
    }
}
