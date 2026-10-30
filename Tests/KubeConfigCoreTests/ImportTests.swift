import XCTest
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

    func testSkippingRequiredNewClusterBlocksImport() throws {
        let target = KubeDocument.empty
        var plan = try ImportPlan(target: target, incoming: Fixtures.document(), sourceDirectory: source)
        plan.items[0].action = .skip
        XCTAssertThrowsError(try plan.merged(into: target))
        XCTAssertEqual(target.entries(.clusters).count, 0)
    }

    func testCustomDestinationNameAndActivation() throws {
        let target = KubeDocument.empty
        var plan = try ImportPlan(target: target, incoming: Fixtures.document(), sourceDirectory: source)
        let clusterIndex = plan.items.firstIndex { $0.kind == .clusters }!
        plan.items[clusterIndex].destinationName = "chosen"
        plan.activateImportedContext = true
        let result = try plan.merged(into: target)
        XCTAssertEqual(result.entry(.contexts, named: "development")!.value("cluster"), "chosen")
        XCTAssertEqual(result.currentContext, "development")
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

    func testImportRejectsWrongConfigurationKindAndVersion() throws {
        for yaml in ["apiVersion: v2\nkind: Config", "apiVersion: v1\nkind: Pod"] {
            XCTAssertThrowsError(try ImportPlan(target: .empty, incoming: KubeDocument(yaml: yaml), sourceDirectory: nil))
        }
    }
}
