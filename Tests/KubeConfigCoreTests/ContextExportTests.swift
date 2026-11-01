import Darwin
import XCTest
@testable import KubeConfigCore

final class ContextExportTests: FileTestCase {
    private func source() throws -> KubeDocument {
        var document = try Fixtures.document()
        try document.update(.contexts, originalName: nil, name: "second", fields: ["cluster": "dev", "user": "developer"])
        try document.update(.clusters, originalName: nil, name: "unused", fields: ["server": "invalid address"])
        try document.update(.users, originalName: nil, name: "unused", fields: ["tokenFile": "missing"])
        return document
    }

    func testSubsetKeepsSharedDependenciesAndEntryMetadataButDropsUnrelatedData() throws {
        let original = try source()
        let result = try original.selectingContexts(["development", "second"])
        XCTAssertEqual(result.entries(.contexts).map(\.name), ["development", "second"])
        XCTAssertEqual(result.entries(.clusters).map(\.name), ["dev"])
        XCTAssertEqual(result.entries(.users).map(\.name), ["developer"])
        XCTAssertEqual(result.entry(.contexts, named: "development")?.node, original.entry(.contexts, named: "development")?.node)
        XCTAssertEqual(result.entry(.clusters, named: "dev")?.fields["extensions"], original.entry(.clusters, named: "dev")?.fields["extensions"])
        XCTAssertEqual(result.entry(.users, named: "developer")?.value("vendor-field"), "retained")
        XCTAssertNil(result.root["vendor-root"])
        XCTAssertFalse(original.validationIssues.isEmpty)
        try result.validate()
    }

    func testActiveContextForSingleAndMultipleSelections() throws {
        let original = try source()
        XCTAssertEqual(try original.selectingContexts(["second"]).currentContext, "second")
        XCTAssertEqual(try original.selectingContexts(["development", "second"]).currentContext, "development")
        var other = original
        try other.update(.contexts, originalName: nil, name: "third", fields: ["cluster": "dev"])
        XCTAssertEqual(try other.selectingContexts(["second", "third"]).currentContext, "")
    }

    func testEmptyMissingAndBrokenSelectionsAreRejected() throws {
        let original = try source()
        XCTAssertThrowsError(try original.selectingContexts([]))
        XCTAssertThrowsError(try original.selectingContexts(["gone"]))
        var broken = original
        try broken.update(.contexts, originalName: nil, name: "broken", fields: ["cluster": "missing", "user": "missing"])
        XCTAssertThrowsError(try broken.selectingContexts(["broken"]))
        XCTAssertThrowsError(try broken.selectingContexts(["broken", "development"]))
    }

    func testAnonymousContextDoesNotIncludeUnrelatedUsers() throws {
        var original = try source()
        try original.update(.contexts, originalName: nil, name: "anonymous", fields: ["cluster": "dev"])
        XCTAssertTrue(try original.selectingContexts(["anonymous"]).entries(.users).isEmpty)
    }

    func testFilesAreEmbeddedRelativeToConfigurationAndSharedFilesAreReadOnce() throws {
        let original = try KubeDocument(yaml: """
        clusters:
        - name: c
          cluster: {server: 'https://c.invalid', certificate-authority: certs/ca.pem}
        users:
        - name: u
          user: {client-certificate: certs/ca.pem, client-key: /absolute/key, token: old, tokenFile: tokens/current}
        contexts:
        - name: a
          context: {cluster: c, user: u}
        - name: b
          context: {cluster: c, user: u}
        """)
        var reads: [URL] = []
        let plan = try ContextExportPlan(document: original, contextNames: ["a", "b"], sourceDirectory: directory) { url in
            reads.append(url)
            return Data((url.lastPathComponent == "current" ? "  file-token\n" : "bytes").utf8)
        }
        XCTAssertEqual(reads, [directory.appendingPathComponent("certs/ca.pem"),
                               URL(fileURLWithPath: "/absolute/key"), directory.appendingPathComponent("tokens/current")].map { $0.resolvingSymlinksInPath() })
        let result = try KubeDocument(yaml: plan.yaml)
        XCTAssertEqual(result.entry(.clusters, named: "c")?.value("certificate-authority-data"), Data("bytes".utf8).base64EncodedString())
        XCTAssertEqual(result.entry(.users, named: "u")?.value("client-certificate-data"), Data("bytes".utf8).base64EncodedString())
        XCTAssertEqual(result.entry(.users, named: "u")?.value("client-key-data"), Data("bytes".utf8).base64EncodedString())
        XCTAssertEqual(result.entry(.users, named: "u")?.value("token"), "file-token")
        XCTAssertNil(result.entry(.users, named: "u")?.fields["tokenFile"])
        XCTAssertNil(result.entry(.users, named: "u")?.fields["client-key"])
        XCTAssertNil(result.entry(.clusters, named: "c")?.fields["certificate-authority"])
        XCTAssertTrue(reads.allSatisfy { plan.sourceFiles.contains($0) })
        XCTAssertEqual(original.entry(.users, named: "u")?.value("token"), "old")
    }

    func testExistingEmbeddedDataWinsWithoutReadingShadowedFiles() throws {
        let original = try KubeDocument(yaml: """
        clusters: [{name: c, cluster: {server: 'https://c.invalid', certificate-authority: missing, certificate-authority-data: Y2E=}}]
        users: [{name: u, user: {client-certificate: missing, client-certificate-data: Y2VydA==, client-key: missing, client-key-data: a2V5}}]
        contexts: [{name: a, context: {cluster: c, user: u}}]
        """)
        let plan = try ContextExportPlan(document: original, contextNames: ["a"], sourceDirectory: directory) { _ in
            XCTFail("Shadowed file must not be read")
            return nil
        }
        let result = try KubeDocument(yaml: plan.yaml)
        XCTAssertEqual(result.entry(.clusters, named: "c")?.value("certificate-authority-data"), "Y2E=")
        XCTAssertEqual(result.entry(.users, named: "u")?.value("client-key-data"), "a2V5")
        XCTAssertNil(result.entry(.users, named: "u")?.fields["client-key"])
        XCTAssertTrue(plan.sourceFiles.isEmpty)
    }

    func testYAMLNullsCountAsAbsentRatherThanAsPathsOrEmbeddedData() throws {
        let original = try KubeDocument(yaml: """
        clusters: [{name: c, cluster: {server: 'https://c.invalid', certificate-authority: null}}]
        users: [{name: u, user: {client-certificate: cert, client-certificate-data: null, client-key: ~, tokenFile: null}}]
        contexts: [{name: a, context: {cluster: c, user: u}}]
        """)
        var read: [String] = []
        let plan = try ContextExportPlan(document: original, contextNames: ["a"], sourceDirectory: directory) {
            read.append($0.lastPathComponent)
            return Data("contents".utf8)
        }
        XCTAssertEqual(read, ["cert"], "A null is no path, and doesn't shadow one")
        let user = try XCTUnwrap(KubeDocument(yaml: plan.yaml).entry(.users, named: "u"))
        XCTAssertEqual(user.value("client-certificate-data"), Data("contents".utf8).base64EncodedString())
        XCTAssertNil(user.fields["client-certificate"])
    }

    func testTildeIsNotExpandedSoItsPathStaysRelativeToTheConfiguration() throws {
        let original = try KubeDocument(yaml: """
        clusters: [{name: c, cluster: {server: 'https://c.invalid', certificate-authority: ~/ca}}]
        contexts: [{name: a, context: {cluster: c}}]
        """)
        var read: [URL] = []
        _ = try ContextExportPlan(document: original, contextNames: ["a"], sourceDirectory: directory) {
            read.append($0)
            return Data("ca".utf8)
        }
        XCTAssertEqual(read, [directory.appendingPathComponent("~/ca").standardizedFileURL.resolvingSymlinksInPath()])
    }

    func testMissingUnreadableEmptyAndOversizedFilesBlockExportWithoutLeakingContents() throws {
        let original = try Fixtures.document()
        let failures: [(URL) throws -> Data?] = [
            { _ in nil },
            { _ in throw ConfigError.invalid("private-file-content") },
            { _ in Data() },
            { _ in Data(repeating: 65, count: KubeDocument.maximumByteCount + 1) }
        ]
        for read in failures {
            XCTAssertThrowsError(try ContextExportPlan(document: original, contextNames: ["development"], sourceDirectory: directory, readFile: read)) { error in
                XCTAssertTrue(error.localizedDescription.contains("dev"))
                XCTAssertTrue(error.localizedDescription.contains("certs/ca.pem"))
                XCTAssertFalse(error.localizedDescription.contains("private-file-content"))
            }
        }
    }

    func testInvalidAndBlankTokenFilesAreRejected() throws {
        let original = try KubeDocument(yaml: "clusters: [{name: c, cluster: {server: 'https://c.invalid'}}]\nusers: [{name: u, user: {tokenFile: token}}]\ncontexts: [{name: a, context: {cluster: c, user: u}}]")
        for data in [Data([0xFF]), Data(" \n\t".utf8)] {
            XCTAssertThrowsError(try ContextExportPlan(document: original, contextNames: ["a"], sourceDirectory: directory) { _ in data })
        }
    }

    func testPluginsProvidersAndProxyArePreservedWithoutReadingOrExecutingThem() throws {
        let original = try KubeDocument(yaml: """
        clusters: [{name: c, cluster: {server: 'https://c.invalid', proxy-url: 'http://proxy.invalid'}}]
        users:
        - name: u
          user:
            exec: {command: ./bin/plugin, args: [--file, relative/settings], env: [{name: CONFIG, value: local-config}]}
            auth-provider: {name: example, config: {path: other-config}}
        contexts: [{name: a, context: {cluster: c, user: u}}]
        """)
        let plan = try ContextExportPlan(document: original, contextNames: ["a"], sourceDirectory: directory) { _ in
            XCTFail("Plugins and provider files must not be read or executed")
            return nil
        }
        let result = try KubeDocument(yaml: plan.yaml)
        XCTAssertEqual(result.entry(.users, named: "u")?.node, original.entry(.users, named: "u")?.node)
        XCTAssertEqual(result.entry(.clusters, named: "c")?.node, original.entry(.clusters, named: "c")?.node)
        XCTAssertTrue(plan.sourceFiles.isEmpty)
    }

    func testEmbeddingCannotProduceAnOversizedExport() throws {
        let original = try Fixtures.document()
        XCTAssertThrowsError(try ContextExportPlan(document: original, contextNames: ["development"], sourceDirectory: directory) { _ in
            Data(repeating: 65, count: KubeDocument.maximumByteCount)
        })
    }

    func testDefaultReaderRejectsSparseOversizedFilesWithEntryAndPathContext() throws {
        let folder = directory.appendingPathComponent("certs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("ca.pem")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(KubeDocument.maximumByteCount) * 8)
        try handle.close()
        XCTAssertThrowsError(try ContextExportPlan(document: Fixtures.document(), contextNames: ["development"], sourceDirectory: directory)) { error in
            XCTAssertTrue(error.localizedDescription.contains("dev"))
            XCTAssertTrue(error.localizedDescription.contains("certs/ca.pem"))
            XCTAssertTrue(error.localizedDescription.contains("16 MB"))
        }
    }

    func testDefaultReaderRejectsPipesWithoutWaitingForAWriter() throws {
        let folder = directory.appendingPathComponent("certs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("ca.pem")
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        XCTAssertThrowsError(try ContextExportPlan(document: Fixtures.document(), contextNames: ["development"], sourceDirectory: directory)) { error in
            XCTAssertTrue(error.localizedDescription.contains("regular file"))
            XCTAssertTrue(error.localizedDescription.contains("certs/ca.pem"))
        }
    }

    func testDefaultReaderEmbedsTheResolvedTargetAndProtectsBothPaths() throws {
        let folder = directory.appendingPathComponent("certs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let alias = folder.appendingPathComponent("ca.pem")
        let target = directory.appendingPathComponent("original.pem")
        try Data("certificate bytes".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let plan = try ContextExportPlan(document: Fixtures.document(), contextNames: ["development"], sourceDirectory: directory)
        let result = try KubeDocument(yaml: plan.yaml)
        XCTAssertEqual(result.entry(.clusters, named: "dev")?.value("certificate-authority-data"), Data("certificate bytes".utf8).base64EncodedString())
        XCTAssertTrue(plan.sourceFiles.contains(alias.standardizedFileURL))
        XCTAssertTrue(plan.sourceFiles.contains(target.resolvingSymlinksInPath()))
    }
}
