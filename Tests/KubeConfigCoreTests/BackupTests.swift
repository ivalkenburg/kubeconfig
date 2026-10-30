import XCTest
@testable import KubeConfigCore

final class BackupTests: FileTestCase {
    func testRollingRetentionKeepsNewestVersionsPerFile() throws {
        let other = directory.appendingPathComponent("other")
        for number in 0..<7 {
            _ = try backups.savePrevious(Data("version-\(number)".utf8), for: config, retention: 3, now: Date(timeIntervalSince1970: Double(number)))
        }
        _ = try backups.savePrevious(Data("other-file".utf8), for: other, retention: 3)
        let records = try backups.records(for: config)
        XCTAssertEqual(records.map { String(data: $0.contents, encoding: .utf8)! }, ["version-6", "version-5", "version-4"])
        XCTAssertEqual(try backups.records(for: other).count, 1)
    }

    func testReducedRetentionTakesEffectOnNextSuccessfulApply() throws {
        try writeInitial()
        var snapshot = try store.load(config)
        for namespace in ["one", "two", "three", "four"] {
            snapshot = try store.apply(Fixtures.changed(namespace: namespace), over: snapshot, retention: 10).snapshot
        }
        XCTAssertEqual(try backups.records(for: config).count, 4)
        _ = try store.apply(Fixtures.changed(namespace: "five"), over: snapshot, retention: 2)
        let records = try backups.records(for: config)
        XCTAssertEqual(records.count, 2)
        let namespaces = try records.map { try backups.rollbackDocument($0, for: config).entry(.contexts, named: "development")!.value("namespace") }
        XCTAssertEqual(namespaces, ["four", "three"])
    }

    func testZeroDisablesBackupsAndPrunesAfterApply() throws {
        try writeInitial()
        let first = try store.apply(Fixtures.changed(namespace: "one"), over: store.load(config), retention: 10)
        XCTAssertEqual(try backups.records(for: config).count, 1)
        let second = try store.apply(Fixtures.changed(namespace: "two"), over: first.snapshot, retention: 0)
        XCTAssertNil(second.backup)
        XCTAssertTrue(try backups.records(for: config).isEmpty)
        XCTAssertEqual(try KubeDocument(yaml: diskText()).entry(.contexts, named: "development")!.value("namespace"), "two")
    }

    func testRollbackIsOnlyADraftUntilAppliedAndCanBeUndone() throws {
        try writeInitial()
        let first = try store.apply(Fixtures.changed(namespace: "changed"), over: store.load(config), retention: 10)
        let backup = try XCTUnwrap(first.backup)
        let rollback = try backups.rollbackDocument(backup, for: config)
        XCTAssertEqual(rollback, try Fixtures.document())
        XCTAssertEqual(try KubeDocument(yaml: diskText()), try Fixtures.changed(namespace: "changed"))
        let restored = try store.apply(rollback, over: first.snapshot, retention: 10)
        XCTAssertEqual(try KubeDocument(yaml: diskText()), try Fixtures.document())
        let undoRollback = try backups.rollbackDocument(XCTUnwrap(restored.backup), for: config)
        XCTAssertEqual(undoRollback, try Fixtures.changed(namespace: "changed"))
        _ = try store.apply(undoRollback, over: restored.snapshot, retention: 10)
        XCTAssertEqual(try KubeDocument(yaml: diskText()), try Fixtures.changed(namespace: "changed"))
    }

    func testRollbackRejectsBackupForAnotherFile() throws {
        let record = BackupRecord(configurationPath: config.path, contents: Data(Fixtures.yaml.utf8))
        XCTAssertThrowsError(try backups.rollbackDocument(record, for: directory.appendingPathComponent("different")))
    }

    func testCorruptBackupCannotBeUsedOrSilentlyPruned() throws {
        let record = try XCTUnwrap(backups.savePrevious(Data(Fixtures.yaml.utf8), for: config, retention: 10))
        let url = backups.location(for: config).appendingPathComponent(record.id + ".json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        json["contents"] = Data("tampered".utf8).base64EncodedString()
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        XCTAssertThrowsError(try backups.records(for: config))
        XCTAssertThrowsError(try backups.savePrevious(nil, for: config, retention: 0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testNegativeRetentionIsRejectedWithoutChangingConfiguration() throws {
        try writeInitial()
        XCTAssertThrowsError(try store.apply(Fixtures.changed(), over: store.load(config), retention: -1))
        XCTAssertEqual(try diskText(), Fixtures.yaml)
    }
}
