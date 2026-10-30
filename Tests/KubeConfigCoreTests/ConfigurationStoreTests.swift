import XCTest
@testable import KubeConfigCore

final class ConfigurationStoreTests: FileTestCase {
    func testOversizedMergeCannotReplaceConfigurationOrCreateBackup() throws {
        try writeInitial()
        let snapshot = try store.load(config)
        let value = String(repeating: "x", count: KubeDocument.maximumByteCount / 2 + 100)
        let first = try KubeDocument(yaml: "vendor-one: \(value)\n")
        let second = try KubeDocument(yaml: "vendor-two: \(value)\n")
        let oversized = try ImportPlan(target: first, incoming: second, sourceDirectory: nil).merged(into: first)
        XCTAssertThrowsError(try store.apply(oversized, over: snapshot, retention: 10))
        XCTAssertEqual(try Data(contentsOf: config), snapshot.data)
        XCTAssertTrue(try backups.records(for: config).isEmpty)
    }

    func testApplyWritesDraftAndBacksUpExactPreviousBytes() throws {
        try writeInitial()
        let snapshot = try store.load(config)
        let changed = try Fixtures.changed()
        let result = try store.apply(changed, over: snapshot, retention: 10)
        XCTAssertEqual(try KubeDocument(yaml: diskText()), changed)
        XCTAssertEqual(result.backup?.contents, Data(Fixtures.yaml.utf8))
        XCTAssertEqual(try backups.records(for: config).count, 1)
        XCTAssertNil(result.warning)
        XCTAssertFalse(try store.hasChanged(result.snapshot))
    }

    func testBackupIsSavedAfterConfigurationReplacement() throws {
        try writeInitial()
        let observing = ObservingFiles(config: config, expectedNamespace: "staging")
        let backupStore = BackupStore(directory: directory.appendingPathComponent("observed"), files: observing)
        let configStore = ConfigurationStore(backups: backupStore)
        _ = try configStore.apply(Fixtures.changed(), over: configStore.load(config), retention: 10)
        XCTAssertTrue(observing.observedAppliedConfig)
    }

    func testExternalEditIsNotOverwrittenAndDoesNotCreateBackup() throws {
        try writeInitial()
        let snapshot = try store.load(config)
        let external = "# edited elsewhere\n" + Fixtures.yaml
        try Data(external.utf8).write(to: config)
        XCTAssertThrowsError(try store.apply(Fixtures.changed(), over: snapshot, retention: 10)) { error in
            XCTAssertEqual(error as? ConfigError, .externalChange)
        }
        XCTAssertEqual(try diskText(), external)
        XCTAssertEqual(try backups.records(for: config).count, 0)
    }

    func testExternalDeletionAndCreationAreDetected() throws {
        try writeInitial()
        let snapshot = try store.load(config)
        try FileManager.default.removeItem(at: config)
        XCTAssertThrowsError(try store.apply(Fixtures.changed(), over: snapshot, retention: 10))
        let missing = try store.load(config)
        try writeInitial()
        XCTAssertThrowsError(try store.apply(.empty, over: missing, retention: 10))
    }

    func testInvalidDraftCannotChangeDiskOrBackups() throws {
        try writeInitial()
        var invalid = try Fixtures.document()
        try invalid.update(.contexts, originalName: "development", name: "development", fields: ["cluster": "absent"])
        XCTAssertThrowsError(try store.apply(invalid, over: store.load(config), retention: 10))
        XCTAssertEqual(try diskText(), Fixtures.yaml)
        XCTAssertTrue(try backups.records(for: config).isEmpty)
    }

    func testFailedConfigWriteNeverCreatesABackup() throws {
        try writeInitial()
        let failing = ConfigurationStore(backups: backups, files: FailingWrites())
        XCTAssertThrowsError(try failing.apply(Fixtures.changed(), over: failing.load(config), retention: 10))
        XCTAssertEqual(try diskText(), Fixtures.yaml)
        XCTAssertTrue(try backups.records(for: config).isEmpty)
    }

    func testFailedBackupStillReportsSuccessfulApplyAndRetainsRecoveryBytes() throws {
        try writeInitial()
        let failingBackups = BackupStore(directory: directory.appendingPathComponent("failure"), files: FailingWrites())
        let configStore = ConfigurationStore(backups: failingBackups)
        let result = try configStore.apply(Fixtures.changed(), over: configStore.load(config), retention: 10)
        XCTAssertNotNil(result.warning)
        XCTAssertEqual(result.recoveryContents, Data(Fixtures.yaml.utf8))
        XCTAssertEqual(try KubeDocument(yaml: diskText()), try Fixtures.changed())
        XCTAssertFalse(try configStore.hasChanged(result.snapshot))
    }

    func testCreatingMissingConfigDoesNotInventAnUndoPoint() throws {
        let nested = directory.appendingPathComponent("new/.kube/config")
        let result = try store.apply(.empty, over: store.load(nested), retention: 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
        XCTAssertNil(result.backup)
        XCTAssertTrue(try backups.records(for: nested).isEmpty)
    }

    func testNoOpApplyCreatesNoBackup() throws {
        let initial = try Fixtures.document().serialized()
        try Data(initial.utf8).write(to: config)
        let result = try store.apply(Fixtures.document(), over: store.load(config), retention: 10)
        XCTAssertNil(result.backup)
        XCTAssertEqual(try backups.records(for: config).count, 0)
    }

    func testConfigAndBackupPermissionsAreRestrictiveAndTemporaryFilesAreRemoved() throws {
        try writeInitial()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: config.path)
        let result = try store.apply(Fixtures.changed(), over: store.load(config), retention: 10)
        let permissions = try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        let backupURL = backups.location(for: config).appendingPathComponent(result.backup!.id + ".json")
        let backupPermissions = try FileManager.default.attributesOfItem(atPath: backupURL.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(backupPermissions.intValue & 0o777, 0o600)
        let folderPermissions = try FileManager.default.attributesOfItem(atPath: backups.location(for: config).path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(folderPermissions.intValue & 0o777, 0o700)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".tmp") })
    }

    func testSymlinkIsPreservedAndTargetIsUpdated() throws {
        try writeInitial()
        let link = directory.appendingPathComponent("linked-config")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: config)
        let snapshot = try store.load(link)
        _ = try store.apply(Fixtures.changed(), over: snapshot, retention: 10)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), config.path)
        XCTAssertEqual(try KubeDocument(yaml: diskText()), try Fixtures.changed())
        XCTAssertEqual(try backups.records(for: config).count, 1)
    }

    func testRetargetedSymlinkIsAnExternalConflict() throws {
        try writeInitial()
        let link = directory.appendingPathComponent("linked-config")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: config)
        let snapshot = try store.load(link)
        let alternate = directory.appendingPathComponent("alternate")
        try Data(Fixtures.yaml.utf8).write(to: alternate)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: alternate)
        XCTAssertThrowsError(try store.apply(Fixtures.changed(), over: snapshot, retention: 10))
        XCTAssertEqual(try diskText(), Fixtures.yaml)
    }

    func testConditionalAtomicReplacementRejectsUnexpectedContents() throws {
        try writeInitial()
        XCTAssertThrowsError(try LocalFileAccess().replaceIfUnchanged(Data("replacement".utf8), at: config, expectedContents: Data("stale".utf8)))
        XCTAssertEqual(try diskText(), Fixtures.yaml)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".tmp") })
    }

    func testConditionalCreationDoesNotReplaceAnUnexpectedExistingFile() throws {
        try writeInitial()
        XCTAssertThrowsError(try LocalFileAccess().replaceIfUnchanged(Data("new".utf8), at: config, expectedContents: nil))
        XCTAssertEqual(try diskText(), Fixtures.yaml)
    }
}

private struct FailingWrites: FileAccess {
    func read(_ url: URL) throws -> Data? { try LocalFileAccess().read(url) }
    func writeAtomically(_ data: Data, to url: URL) throws { throw CocoaError(.fileWriteNoPermission) }
}

private final class ObservingFiles: FileAccess {
    let config: URL
    let expectedNamespace: String
    var observedAppliedConfig = false
    init(config: URL, expectedNamespace: String) { self.config = config; self.expectedNamespace = expectedNamespace }
    func read(_ url: URL) throws -> Data? { try LocalFileAccess().read(url) }
    func writeAtomically(_ data: Data, to url: URL) throws {
        let doc = try KubeDocument(yaml: String(contentsOf: config, encoding: .utf8))
        observedAppliedConfig = doc.entry(.contexts, named: "development")?.value("namespace") == expectedNamespace
        try LocalFileAccess().writeAtomically(data, to: url)
    }
}
