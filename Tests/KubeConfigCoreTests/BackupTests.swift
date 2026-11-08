import XCTest
@testable import KubeConfigCore

final class BackupTests: FileTestCase {
    func testRollingRetentionKeepsNewestVersionsPerFile() throws {
        let other = directory.appendingPathComponent("other")
        for number in 0..<7 {
            _ = try backups.savePrevious(Data("version-\(number)".utf8), for: config, retention: 3, now: Date(timeIntervalSince1970: Double(number)))
        }
        _ = try backups.savePrevious(Data("other-file".utf8), for: other, retention: 3)
        let records = try backups.records(for: config).records
        XCTAssertEqual(try records.map { String(data: try backups.record($0, for: config).contents, encoding: .utf8)! }, ["version-6", "version-5", "version-4"])
        XCTAssertEqual(try backups.records(for: other).records.count, 1)
    }

    func testRemovingABackupTakesItsSummaryEvenWhenTheFileIsAlreadyGone() throws {
        let first = try XCTUnwrap(backups.savePrevious(Data("one".utf8), for: config, retention: 3))
        let second = try XCTUnwrap(backups.savePrevious(Data("two".utf8), for: config, retention: 3))
        let folder = backups.location(for: config)
        try backups.remove(first.summary, for: config)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(second.id + ".json"))
        try backups.remove(second.summary, for: config)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    func testBackupRootIsTightenedToTheOwner() throws {
        try FileManager.default.createDirectory(at: backups.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        _ = try backups.savePrevious(Data("old".utf8), for: config, retention: 3)
        let attributes = try FileManager.default.attributesOfItem(atPath: backups.directory.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700)
    }

    func testABackupRenamedOnDiskIsDamaged() throws {
        let saved = try XCTUnwrap(backups.savePrevious(Data("old".utf8), for: config, retention: 3))
        let folder = backups.location(for: config)
        let renamed = UUID().uuidString
        for suffix in ["json", "meta"] {
            try FileManager.default.moveItem(at: folder.appendingPathComponent("\(saved.id).\(suffix)"),
                                             to: folder.appendingPathComponent("\(renamed).\(suffix)"))
        }
        let listing = try backups.records(for: config)
        XCTAssertEqual(listing.records, [])
        XCTAssertEqual(listing.damagedCount, 1)
    }

    func testReducedRetentionTakesEffectOnNextSuccessfulApply() throws {
        try writeInitial()
        var snapshot = try store.load(config)
        for namespace in ["one", "two", "three", "four"] {
            snapshot = try store.apply(Fixtures.changed(namespace: namespace), over: snapshot, retention: 10).snapshot
        }
        XCTAssertEqual(try backups.records(for: config).records.count, 4)
        _ = try store.apply(Fixtures.changed(namespace: "five"), over: snapshot, retention: 2)
        let records = try backups.records(for: config).records
        XCTAssertEqual(records.count, 2)
        let namespaces = try records.map { try KubeDocument(yaml: backups.rollbackText(backups.record($0, for: config), for: config)).entry(.contexts, named: "development")!.value("namespace") }
        XCTAssertEqual(namespaces, ["four", "three"])
    }

    func testZeroDisablesBackupsAndPrunesAfterApply() throws {
        try writeInitial()
        let first = try store.apply(Fixtures.changed(namespace: "one"), over: store.load(config), retention: 10)
        XCTAssertEqual(try backups.records(for: config).records.count, 1)
        let second = try store.apply(Fixtures.changed(namespace: "two"), over: first.snapshot, retention: 0)
        XCTAssertNil(second.backup)
        XCTAssertTrue(try backups.records(for: config).records.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.location(for: config).path), [])
        XCTAssertEqual(try KubeDocument(yaml: diskText()).entry(.contexts, named: "development")!.value("namespace"), "two")
    }

    func testRollbackIsOnlyADraftUntilAppliedAndCanBeUndone() throws {
        try writeInitial()
        let first = try store.apply(Fixtures.changed(namespace: "changed"), over: store.load(config), retention: 10)
        let backup = try XCTUnwrap(first.backup)
        let rollback = try KubeDocument(yaml: backups.rollbackText(backup, for: config))
        XCTAssertEqual(rollback, try Fixtures.document())
        XCTAssertEqual(try KubeDocument(yaml: diskText()), try Fixtures.changed(namespace: "changed"))
        let restored = try store.apply(rollback, over: first.snapshot, retention: 10)
        XCTAssertEqual(try KubeDocument(yaml: diskText()), try Fixtures.document())
        let undoRollback = try KubeDocument(yaml: backups.rollbackText(XCTUnwrap(restored.backup), for: config))
        XCTAssertEqual(undoRollback, try Fixtures.changed(namespace: "changed"))
        _ = try store.apply(undoRollback, over: restored.snapshot, retention: 10)
        XCTAssertEqual(try KubeDocument(yaml: diskText()), try Fixtures.changed(namespace: "changed"))
    }

    func testRollbackRejectsBackupForAnotherFile() throws {
        let record = BackupRecord(configurationPath: config.path, contents: Data(Fixtures.yaml.utf8))
        XCTAssertThrowsError(try backups.rollbackText(record, for: directory.appendingPathComponent("different")))
    }

    func testCorruptBackupCannotBeUsedOrSilentlyPruned() throws {
        let record = try XCTUnwrap(backups.savePrevious(Data(Fixtures.yaml.utf8), for: config, retention: 10))
        let url = backups.location(for: config).appendingPathComponent(record.id + ".json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        json["contents"] = Data("tampered".utf8).base64EncodedString()
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        XCTAssertThrowsError(try backups.record(record.summary, for: config))
        XCTAssertNoThrow(try backups.savePrevious(nil, for: config, retention: 0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testDamagedBackupIsCountedAndTheOthersStayListed() throws {
        let kept = try XCTUnwrap(backups.savePrevious(Data("kept".utf8), for: config, retention: 10))
        let damaged = backups.location(for: config).appendingPathComponent("damaged.json")
        try Data("garbage".utf8).write(to: damaged)
        let listing = try backups.records(for: config)
        XCTAssertEqual(listing.records, [kept.summary])
        XCTAssertEqual(listing.damagedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: damaged.path))
    }

    func testOversizedSummaryIsRebuiltAndOversizedRecordIsReportedDamaged() throws {
        let record = try XCTUnwrap(backups.savePrevious(Data("kept".utf8), for: config, retention: 10))
        let folder = backups.location(for: config)
        let summary = folder.appendingPathComponent(record.id + ".meta")
        let handle = try FileHandle(forWritingTo: summary)
        try handle.truncate(atOffset: 128 * 1024 * 1024)
        try handle.close()
        XCTAssertEqual(try backups.records(for: config).records, [record.summary])
        XCTAssertLessThan(try Data(contentsOf: summary).count, 64 * 1024)
        let json = folder.appendingPathComponent(record.id + ".json")
        let jsonHandle = try FileHandle(forWritingTo: json)
        try jsonHandle.truncate(atOffset: 128 * 1024 * 1024)
        try jsonHandle.close()
        XCTAssertThrowsError(try backups.record(record.summary, for: config)) {
            XCTAssertTrue($0.localizedDescription.contains("damaged"))
        }
        try FileManager.default.removeItem(at: summary)
        XCTAssertEqual(try backups.records(for: config), BackupListing(records: [], damagedCount: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: json.path))
    }

    func testLargestBackupPayloadSurvivesBase64AndJSONEscaping() throws {
        let contents = Data(repeating: 0xff, count: KubeDocument.maximumByteCount)
        let record = try XCTUnwrap(backups.savePrevious(contents, for: config, retention: 10))
        XCTAssertEqual(try backups.record(record.summary, for: config).contents, contents)
    }

    func testListingNeverReadsBackupContents() throws {
        let files = RecordingFiles()
        let store = BackupStore(directory: directory.appendingPathComponent("recorded"), files: files)
        let record = try XCTUnwrap(store.savePrevious(Data("text".utf8), for: config, retention: 10))
        files.reads = []
        XCTAssertEqual(try store.records(for: config).records, [record.summary])
        XCTAssertEqual(files.reads.map(\.pathExtension), ["meta"])
    }

    func testBackupsWithoutASummaryGetOneWhenListed() throws {
        let record = try XCTUnwrap(backups.savePrevious(Data("text".utf8), for: config, retention: 10))
        let summary = backups.location(for: config).appendingPathComponent(record.id + ".meta")
        try FileManager.default.removeItem(at: summary)
        XCTAssertEqual(try backups.records(for: config).records, [record.summary])
        XCTAssertTrue(FileManager.default.fileExists(atPath: summary.path))
    }

    func testBackupsFromTheSameInstantHaveAStableOrder() throws {
        let instant = Date(timeIntervalSince1970: 1_000)
        for number in 0..<4 { _ = try backups.savePrevious(Data("\(number)".utf8), for: config, retention: 10, now: instant) }
        let ids = try backups.records(for: config).records.map(\.id)
        XCTAssertEqual(ids, ids.sorted(by: >))
    }

    func testRollbackRejectsTamperedAndNonUTF8Contents() throws {
        let binary = BackupRecord(configurationPath: config.path, contents: Data([0xFF, 0xFE]))
        XCTAssertThrowsError(try backups.rollbackText(binary, for: config))
        let json = try JSONEncoder().encode(BackupRecord(configurationPath: config.path, contents: Data("original".utf8)))
        let tampered = String(decoding: json, as: UTF8.self).replacingOccurrences(of: Data("original".utf8).base64EncodedString(), with: Data("tampered".utf8).base64EncodedString())
        let record = try JSONDecoder().decode(BackupRecord.self, from: Data(tampered.utf8))
        XCTAssertThrowsError(try backups.rollbackText(record, for: config))
    }

    func testRecordsRejectABackupFiledUnderTheWrongConfiguration() throws {
        let other = directory.appendingPathComponent("other")
        let record = try XCTUnwrap(backups.savePrevious(Data("text".utf8), for: other, retention: 10))
        let folder = backups.location(for: config)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: backups.location(for: other).appendingPathComponent(record.id + ".json"), to: folder.appendingPathComponent(record.id + ".json"))
        XCTAssertEqual(try backups.records(for: config), BackupListing(records: [], damagedCount: 1))
    }

    func testNegativeRetentionIsRejectedWithoutChangingConfiguration() throws {
        try writeInitial()
        XCTAssertThrowsError(try store.apply(Fixtures.changed(), over: store.load(config), retention: -1))
        XCTAssertEqual(try diskText(), Fixtures.yaml)
        XCTAssertThrowsError(try backups.savePrevious(Data("old".utf8), for: config, retention: -1))
    }
}

private final class RecordingFiles: FileAccess {
    var reads: [URL] = []
    func read(_ url: URL, maximumByteCount: Int) throws -> Data? { reads.append(url); return try LocalFileAccess().read(url, maximumByteCount: maximumByteCount) }
    func writeAtomically(_ data: Data, to url: URL) throws { try LocalFileAccess().writeAtomically(data, to: url) }
}
