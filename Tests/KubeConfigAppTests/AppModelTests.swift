import XCTest
import KubeConfigCore
@testable import KubeConfig

final class AppModelTests: XCTestCase {
    private static let fixture = """
    apiVersion: v1
    kind: Config
    clusters:
    - name: dev
      cluster: {server: 'https://dev.invalid'}
    users: []
    contexts:
    - name: dev
      context: {cluster: dev, namespace: default}
    - name: other
      context: {cluster: dev}
    current-context: dev
    """ + "\n"

    private func withModel(initial: String? = fixture, backupFiles: any FileAccess = LocalFileAccess(), _ body: @MainActor (AppModel, URL) throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KubeConfigAppTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config")
        if let initial { try Data(initial.utf8).write(to: url) }
        let suite = "KubeConfigTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = ConfigurationStore(backups: BackupStore(directory: directory.appendingPathComponent("backups"), files: backupFiles))
        try await MainActor.run {
            let defaults = UserDefaults(suiteName: suite)!
            let model = AppModel(store: store, defaults: defaults, initialURL: url)
            try body(model, url)
        }
    }

    func testFormEditsRemainPendingUntilApplyAndThenCreateBackup() async throws {
        try await withModel { model, url in
            XCTAssertFalse(model.hasPendingChanges)
            model.editor?.fields["namespace"] = "payments"
            XCTAssertTrue(model.hasPendingChanges)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), Self.fixture)
            try model.flushEditor()
            XCTAssertTrue(model.hasPendingChanges)
            XCTAssertEqual(model.document?.entry(.contexts, named: "dev")?.value("namespace"), "payments")
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), Self.fixture)
            model.commit()
            XCTAssertFalse(model.hasPendingChanges)
            XCTAssertEqual(model.records.count, 1)
            XCTAssertEqual(model.records[0].contents, Data(Self.fixture.utf8))
        }
    }

    func testSelectionFlushesFormWithoutActivatingContext() async throws {
        try await withModel { model, _ in
            model.editor?.fields["namespace"] = "payments"
            model.selectEntry("other")
            XCTAssertEqual(model.document?.entry(.contexts, named: "dev")?.value("namespace"), "payments")
            XCTAssertEqual(model.document?.currentContext, "dev")
            XCTAssertEqual(model.selectedName, "other")
        }
    }

    func testInvalidRenamePreventsNavigationAndKeepsFormEdits() async throws {
        try await withModel { model, _ in
            model.editor?.name = "other"
            model.selectSection(.clusters)
            XCTAssertEqual(model.section, .contexts)
            XCTAssertEqual(model.editor?.name, "other")
            XCTAssertNotNil(model.errorMessage)
            XCTAssertTrue(model.hasPendingChanges)
        }
    }

    func testRawSyntaxFailureBlocksReviewWithoutDiscardingDraft() async throws {
        try await withModel { model, url in
            model.editRaw("contexts: [broken")
            XCTAssertNil(model.document)
            model.requestReview()
            XCTAssertFalse(model.showReview)
            XCTAssertTrue(model.hasPendingChanges)
            XCTAssertEqual(model.draftText, "contexts: [broken")
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), Self.fixture)
        }
    }

    func testMissingFileIsNotDirtyUntilCreate() async throws {
        try await withModel(initial: nil) { model, url in
            XCTAssertTrue(model.missingFile)
            XCTAssertFalse(model.hasPendingChanges)
            model.createConfiguration()
            XCTAssertFalse(model.missingFile)
            XCTAssertTrue(model.hasPendingChanges)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            model.commit()
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertTrue(model.records.isEmpty)
        }
    }

    func testRollbackStagesThenApplyCreatesUndoForRollback() async throws {
        try await withModel { model, url in
            model.editor?.fields["namespace"] = "changed"
            try model.flushEditor()
            model.commit()
            model.rollbackSelected()
            XCTAssertTrue(model.hasPendingChanges)
            XCTAssertEqual(model.document?.entry(.contexts, named: "dev")?.value("namespace"), "default")
            let live = try KubeDocument(yaml: String(contentsOf: url, encoding: .utf8))
            XCTAssertEqual(live.entry(.contexts, named: "dev")?.value("namespace"), "changed")
            model.commit()
            XCTAssertEqual(model.records.count, 2)
            let undo = try model.store.backups.rollbackDocument(model.records[0], for: url)
            XCTAssertEqual(undo.entry(.contexts, named: "dev")?.value("namespace"), "changed")
        }
    }

    func testExternalConflictKeepsPendingEditsAndDoesNotOpenReview() async throws {
        try await withModel { model, url in
            model.editor?.fields["namespace"] = "draft"
            try Data(("# external\n" + Self.fixture).utf8).write(to: url)
            model.requestReview()
            XCTAssertFalse(model.showReview)
            XCTAssertTrue(model.hasPendingChanges)
            XCTAssertNotNil(model.errorMessage)
            XCTAssertEqual(model.document?.entry(.contexts, named: "dev")?.value("namespace"), "draft")
        }
    }

    func testReviewDoesNotRunContinuationUntilApply() async throws {
        try await withModel { model, _ in
            model.editor?.fields["namespace"] = "changed"
            var continued = false
            model.requestReview { continued = true }
            XCTAssertTrue(model.showReview)
            XCTAssertFalse(continued)
            model.commit()
            XCTAssertTrue(continued)
            XCTAssertFalse(model.showReview)
        }
    }

    func testDiscardRemovesBothBufferedFormAndStagedChanges() async throws {
        try await withModel { model, url in
            model.editor?.fields["namespace"] = "first"
            try model.flushEditor()
            model.editor?.name = "renamed"
            XCTAssertTrue(model.hasPendingChanges)
            model.discardDraft()
            XCTAssertFalse(model.hasPendingChanges)
            XCTAssertEqual(model.draftText, Self.fixture)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), Self.fixture)
        }
    }

    func testPasteCannotSilentlyReplaceABrokenConfiguration() async throws {
        try await withModel(initial: "contexts: [broken") { model, url in
            XCTAssertThrowsError(try model.prepareImport(yaml: Self.fixture, directory: nil))
            XCTAssertEqual(model.draftText, "contexts: [broken")
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "contexts: [broken")
        }
    }

    func testRollbackOfBrokenOriginalCanBeStagedAndRepaired() async throws {
        try await withModel(initial: "contexts: [broken") { model, url in
            model.editRaw(Self.fixture)
            model.commit()
            model.rollbackSelected()
            XCTAssertTrue(model.hasPendingChanges)
            XCTAssertNotNil(model.parseIssue)
            XCTAssertEqual(model.draftText, "contexts: [broken")
            XCTAssertNotEqual(try String(contentsOf: url, encoding: .utf8), "contexts: [broken")
            model.requestReview()
            XCTAssertFalse(model.showReview)
        }
    }

    func testBackupFailureRetainsRecoveryAndPreventsAutomaticContinuation() async throws {
        try await withModel(backupFiles: UnwritableBackups()) { model, url in
            model.editor?.fields["namespace"] = "changed"
            var continued = false
            model.requestReview { continued = true }
            model.commit()
            XCTAssertFalse(continued)
            XCTAssertFalse(model.hasPendingChanges)
            XCTAssertTrue(model.needsAttentionBeforeLeaving)
            XCTAssertEqual(model.recoveryContents, Data(Self.fixture.utf8))
            XCTAssertNotNil(model.backupWarning)
            let applied = try KubeDocument(yaml: String(contentsOf: url, encoding: .utf8))
            XCTAssertEqual(applied.entry(.contexts, named: "dev")?.value("namespace"), "changed")
        }
    }

    func testBackupSearchFiltersDatesAndSupportsEmptyResultsAndClearing() async throws {
        try await withModel { model, url in
            let older = BackupRecord(configurationPath: url.path, contents: Data(Self.fixture.utf8), createdAt: Date(timeIntervalSince1970: 1_577_880_000))
            let newer = BackupRecord(configurationPath: url.path, contents: Data(Self.fixture.utf8), createdAt: Date(timeIntervalSince1970: 1_704_110_400))
            model.records = [newer, older]
            model.selectedBackupID = older.id
            model.search = "2020"
            XCTAssertEqual(model.visibleBackups.map(\.id), [older.id])
            model.search = "no-matching-date"
            XCTAssertTrue(model.visibleBackups.isEmpty)
            XCTAssertNil(model.selectedBackup)
            model.search = ""
            XCTAssertEqual(model.visibleBackups.count, 2)
            XCTAssertEqual(model.selectedBackup?.id, older.id)
        }
    }

    func testLaterApplyCannotOverwriteUnresolvedRecoveryContents() async throws {
        try await withModel(backupFiles: UnwritableBackups()) { model, url in
            model.editor?.fields["namespace"] = "first-change"
            try model.flushEditor()
            model.commit()
            let appliedContents = try Data(contentsOf: url)
            XCTAssertEqual(model.recoveryContents, Data(Self.fixture.utf8))

            model.editor?.fields["namespace"] = "second-change"
            model.requestReview()
            XCTAssertFalse(model.showReview)
            XCTAssertTrue(model.hasPendingChanges)
            XCTAssertNotNil(model.errorMessage)
            try model.flushEditor()
            model.commit()
            XCTAssertEqual(try Data(contentsOf: url), appliedContents)
            XCTAssertEqual(model.recoveryContents, Data(Self.fixture.utf8))
            XCTAssertNotNil(model.backupWarning)
        }
    }

    func testAppliedContextChangesOnlyAfterSuccessfulApply() async throws {
        try await withModel { model, _ in
            XCTAssertEqual(model.appliedContext, "dev")
            model.selectEntry("other")
            model.makeActive()
            XCTAssertEqual(model.document?.currentContext, "other")
            XCTAssertEqual(model.appliedContext, "dev")
            model.commit()
            XCTAssertEqual(model.appliedContext, "other")
        }
    }

    func testFailedStageKeepsThePreviousDraftAndBufferedForm() async throws {
        let value = String(repeating: "x", count: KubeDocument.maximumByteCount / 2 + 100)
        let first = try KubeDocument(yaml: "vendor-one: \(value)\n")
        let second = try KubeDocument(yaml: "vendor-two: \(value)\n")
        let oversized = try ImportPlan(target: first, incoming: second, sourceDirectory: nil).merged(into: first)
        try await withModel { model, _ in
            let original = model.document
            model.editor?.fields["namespace"] = "buffered"
            XCTAssertThrowsError(try model.stage(oversized))
            XCTAssertEqual(model.document, original)
            XCTAssertEqual(model.draftText, Self.fixture)
            XCTAssertEqual(model.editor?.fields["namespace"], "buffered")
            XCTAssertTrue(model.formIsDirty)
        }
    }

    func testImportMergeErrorsRemainAvailableToTheSheetWithoutChangingDraft() async throws {
        try await withModel { model, _ in
            let incoming = try KubeDocument(yaml: "contexts: [{name: broken, context: {cluster: missing}}]")
            let plan = try ImportPlan(target: model.document!, incoming: incoming, sourceDirectory: nil)
            XCTAssertThrowsError(try model.acceptImport(plan))
            XCTAssertEqual(model.draftText, Self.fixture)
            XCTAssertFalse(model.hasPendingChanges)
        }
    }
}

private struct UnwritableBackups: FileAccess {
    func read(_ url: URL) throws -> Data? { try LocalFileAccess().read(url) }
    func writeAtomically(_ data: Data, to url: URL) throws { throw CocoaError(.fileWriteNoPermission) }
}
