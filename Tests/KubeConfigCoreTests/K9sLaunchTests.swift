import XCTest
@testable import KubeConfigCore

final class K9sLaunchTests: XCTestCase {
    private let config = URL(fileURLWithPath: "/tmp/my configs/config")

    func testTargetsTheFileAndContext() throws {
        let launch = try XCTUnwrap(K9sLaunch(kubeconfig: config, context: "prod east", loginPath: "/custom/bin", inherited: ["HOME": "/h"]) { $0 == "/custom/bin/k9s" })
        XCTAssertEqual(launch.executable, "/custom/bin/k9s")
        XCTAssertEqual(launch.arguments, ["--kubeconfig", "/tmp/my configs/config", "--context", "prod east", "--splashless", "--logoless"])
        XCTAssertTrue(launch.environment.contains("HOME=/h"))
        XCTAssertTrue(launch.environment.contains("KUBECONFIG=/tmp/my configs/config"))
        XCTAssertTrue(launch.environment.contains("COLORTERM=truecolor"))
    }

    func testLoginPathComesFirstAndReachesK9s() throws {
        let launch = try XCTUnwrap(K9sLaunch(kubeconfig: config, context: "c", loginPath: "/first:/both", inherited: ["PATH": "/both:/usr/bin"]) { _ in true })
        XCTAssertEqual(launch.executable, "/first/k9s")
        let path = try XCTUnwrap(launch.environment.first { $0.hasPrefix("PATH=") })
        XCTAssertTrue(path.hasPrefix("PATH=/first:/both:/usr/bin:/opt/homebrew/bin"))
    }

    func testFallsBackToPackageManagerFolders() throws {
        let launch = K9sLaunch(kubeconfig: config, context: "c", loginPath: nil, inherited: [:]) { $0 == "/opt/homebrew/bin/k9s" }
        XCTAssertEqual(launch?.executable, "/opt/homebrew/bin/k9s")
    }

    func testMissingK9s() {
        XCTAssertNil(K9sLaunch(kubeconfig: config, context: "c", loginPath: "/bin", inherited: ["PATH": "/usr/bin"]) { _ in false })
    }

    func testProbeOutputIgnoresWhatStartupFilesPrint() {
        XCTAssertEqual(K9sLaunch.path(fromProbeOutput: "welcome!\n__KUBECONFIG_PATH__/a:/b\n__KUBECONFIG_PATH__bye"), "/a:/b")
        XCTAssertNil(K9sLaunch.path(fromProbeOutput: "no markers"))
        XCTAssertNil(K9sLaunch.path(fromProbeOutput: "__KUBECONFIG_PATH__\n__KUBECONFIG_PATH__"))
    }

    private static let base = """
    clusters:
    - {name: a, cluster: {server: 'https://a.invalid'}}
    - {name: b, cluster: {server: 'https://b.invalid'}}
    users:
    - {name: me, user: {token: one}}
    contexts:
    - {name: ctx, context: {cluster: a, user: me}}
    - {name: other, context: {cluster: b}}
    current-context: ctx

    """

    private func change(to yaml: String) throws -> ContextConnectionChange {
        KubeDocument.connectionChange(ofContext: "ctx", from: try KubeDocument(yaml: Self.base), to: try KubeDocument(yaml: yaml))
    }

    func testUnrelatedChangesDontCount() throws {
        XCTAssertEqual(try change(to: Self.base), .unchanged)
        XCTAssertEqual(try change(to: Self.base.replacingOccurrences(of: "https://b.invalid", with: "https://c.invalid")), .unchanged)
        XCTAssertEqual(try change(to: Self.base.replacingOccurrences(of: "current-context: ctx", with: "current-context: other")), .unchanged)
    }

    func testContextClusterAndUserChangesCount() throws {
        XCTAssertEqual(try change(to: Self.base.replacingOccurrences(of: "cluster: a, user", with: "cluster: b, user")), .changed)
        XCTAssertEqual(try change(to: Self.base.replacingOccurrences(of: "https://a.invalid", with: "https://c.invalid")), .changed)
        XCTAssertEqual(try change(to: Self.base.replacingOccurrences(of: "token: one", with: "token: two")), .changed)
    }

    func testRemovedOrRenamedContext() throws {
        XCTAssertEqual(try change(to: Self.base.replacingOccurrences(of: "name: ctx", with: "name: renamed")), .removed)
        XCTAssertEqual(KubeDocument.connectionChange(ofContext: "ctx", from: try KubeDocument(yaml: Self.base), to: nil), .removed)
    }

    func testNoOlderVersion() throws {
        XCTAssertEqual(KubeDocument.connectionChange(ofContext: "ctx", from: nil, to: try KubeDocument(yaml: Self.base)), .changed)
    }

    func testContextAddedSinceTheOlderVersion() throws {
        let old = try KubeDocument(yaml: Self.base.replacingOccurrences(of: "name: ctx", with: "name: previous"))
        XCTAssertEqual(KubeDocument.connectionChange(ofContext: "ctx", from: old, to: try KubeDocument(yaml: Self.base)), .changed)
    }

    func testReferencedUserRemovedCounts() throws {
        XCTAssertEqual(try change(to: Self.base.replacingOccurrences(of: "- {name: me, user: {token: one}}", with: "- {name: someone, user: {token: one}}")), .changed)
    }

    func testContextWithoutUser() throws {
        let document = try KubeDocument(yaml: Self.base)
        XCTAssertEqual(KubeDocument.connectionChange(ofContext: "other", from: document, to: document), .unchanged)
    }

    func testInheritedVariablesAreReplaced() throws {
        let launch = try XCTUnwrap(K9sLaunch(kubeconfig: config, context: "c", loginPath: "/b", inherited: ["KUBECONFIG": "a:b", "TERM": "dumb"]) { _ in true })
        XCTAssertEqual(launch.environment.filter { $0.hasPrefix("KUBECONFIG=") }, ["KUBECONFIG=/tmp/my configs/config"])
        XCTAssertEqual(launch.environment.filter { $0.hasPrefix("TERM=") }, ["TERM=xterm-256color"])
    }

    func testLocaleIsFilledInButNotOverridden() throws {
        let filled = try XCTUnwrap(K9sLaunch(kubeconfig: config, context: "c", loginPath: "/b", inherited: [:]) { _ in true })
        XCTAssertTrue(filled.environment.contains("LANG=en_US.UTF-8"))
        let kept = try XCTUnwrap(K9sLaunch(kubeconfig: config, context: "c", loginPath: "/b", inherited: ["LANG": "nl_NL.UTF-8"]) { _ in true })
        XCTAssertTrue(kept.environment.contains("LANG=nl_NL.UTF-8"))
    }

    func testEmptyPathSegmentsAreDropped() throws {
        var checked: [String] = []
        XCTAssertNil(K9sLaunch(kubeconfig: config, context: "c", loginPath: "::/a", inherited: [:]) { checked.append($0); return false })
        XCTAssertEqual(checked.first, "/a/k9s")
        XCTAssertFalse(checked.contains("k9s"))
    }

    func testProbeOutputWithOneMarker() {
        XCTAssertNil(K9sLaunch.path(fromProbeOutput: "__KUBECONFIG_PATH__/a:/b"))
    }

    private func fakeShell(_ script: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-shell-\(UUID().uuidString)")
        try Data("#!/bin/sh\n\(script)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testProbeReadsTheShellsPath() async throws {
        let shell = try fakeShell("PATH=/fake:$PATH; eval \"$2\"")
        let path = await LoginShell.path(shell: shell.path, timeout: 5)
        XCTAssertEqual(path?.hasPrefix("/fake:"), true)
    }

    func testProbeDoesNotWaitForAChildHoldingThePipe() async throws {
        let shell = try fakeShell("sleep 8 &\neval \"$2\"")
        let start = Date()
        let path = await LoginShell.path(shell: shell.path, timeout: 5)
        XCTAssertNotNil(path)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testProbeKillsAShellThatIgnoresTerm() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("fake-shell-pid-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: pidFile) }
        let shell = try fakeShell("trap '' TERM\necho $$ > '\(pidFile.path)'\nwhile :; do sleep 0.1; done")
        let path = await LoginShell.path(shell: shell.path, timeout: 0.5)
        XCTAssertNil(path)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let deadline = Date().addingTimeInterval(2)
        while kill(pid, 0) == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotEqual(kill(pid, 0), 0, "The hung shell should be gone")
    }

    func testProbeOfAMissingShell() async {
        let path = await LoginShell.path(shell: "/nonexistent/shell", timeout: 1)
        XCTAssertNil(path)
    }
}
