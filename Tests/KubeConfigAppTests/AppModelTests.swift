import XCTest
import KubeConfigCore
import SwiftUI
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

    @MainActor fileprivate func withModel(initial: String? = fixture, backupFiles: any FileAccess = LocalFileAccess(), immediate: Bool? = false, _ body: @MainActor (AppModel, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KubeConfigAppTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config")
        if let initial { try Data(initial.utf8).write(to: url) }
        let suite = "KubeConfigTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = ConfigurationStore(backups: BackupStore(directory: directory.appendingPathComponent("backups"), files: backupFiles))
        let defaults = UserDefaults(suiteName: suite)!
        if let immediate { defaults.set(immediate, forKey: ContextSwitching.immediateKey) }
        try await body(AppModel(store: store, defaults: defaults, initialURL: url), url)
    }

    @MainActor private func reviewed(_ model: AppModel) throws -> Int {
        ConfigurationDiff.changes(in: try ConfigurationDiff.lines(before: model.snapshot?.text ?? "", after: XCTUnwrap(model.document))).count
    }

    @MainActor private func exportedDocument(_ model: AppModel) throws -> KubeDocument {
        try KubeDocument(yaml: XCTUnwrap(model.contextExportPlan).yaml)
    }

    func testApplyCountMatchesReviewForARenamedActiveContext() async throws {
        try await withModel { model, _ in
            model.editor?.name = "renamed"
            XCTAssertEqual(model.reviewCount, 2, "Counted while the name is still being typed")
            try model.flushEditor()
            XCTAssertEqual(model.reviewCount, 2)
            XCTAssertEqual(try reviewed(model), 2)
            XCTAssertEqual(model.pendingChanges?.count(.contexts), 1)
        }
    }

    func testApplyCountMatchesReviewWhenOneEntryHasSeparateChanges() async throws {
        try await withModel(initial: Self.fixture.replacingOccurrences(of: "cluster: {server: 'https://dev.invalid'}", with: "cluster: {server: 'https://dev.invalid', tls-server-name: a, proxy-url: 'http://p.invalid'}")) { model, _ in
            model.selectSection(.clusters)
            model.editor?.fields["server"] = "https://new.invalid"
            model.editor?.fields["proxy-url"] = "http://new.invalid"
            try model.flushEditor()
            XCTAssertEqual(model.reviewCount, 2)
            XCTAssertEqual(try reviewed(model), 2)
            XCTAssertEqual(model.pendingChanges?.count(.clusters), 1)
        }
    }

    func testImmediateSwitchingIsOnByDefault() async throws {
        try await withModel(immediate: nil) { model, _ in
            XCTAssertTrue(model.switchesContextsImmediately)
        }
    }

    func testImmediateSwitchWritesOnlyTheFileWithoutReviewOrBackup() async throws {
        let commented = "# keep me\n" + Self.fixture.replacingOccurrences(of: "current-context: dev", with: "current-context: dev  # active")
        try await withModel(initial: commented, immediate: true) { model, url in
            model.makeActive("other")
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), commented.replacingOccurrences(of: "current-context: dev", with: "current-context: other"))
            XCTAssertEqual(model.document?.currentContext, "other")
            XCTAssertFalse(model.hasPendingChanges)
            XCTAssertNil(model.draftStatus)
            XCTAssertFalse(model.showReview)
            model.refreshBackups()
            XCTAssertTrue(model.records.isEmpty)
            XCTAssertFalse(try model.store.hasChanged(XCTUnwrap(model.snapshot)))
            XCTAssertFalse(model.canUndo)
        }
    }

    func testImmediateSwitchKeepsPendingEditsInTheDraftAndOutOfTheFile() async throws {
        try await withModel(immediate: true) { model, url in
            model.editor?.fields["namespace"] = "payments"
            model.makeActive("other")
            let disk = try KubeDocument(yaml: String(contentsOf: url, encoding: .utf8))
            XCTAssertEqual(disk.currentContext, "other")
            XCTAssertEqual(disk.entry(.contexts, named: "dev")?.value("namespace"), "default")
            XCTAssertEqual(model.document?.entry(.contexts, named: "dev")?.value("namespace"), "payments")
            XCTAssertEqual(model.document?.currentContext, "other")
            XCTAssertEqual(model.pendingChanges?.count, 1)
            XCTAssertEqual(model.pendingChanges?.activeContextChanged, false)
            model.commit()
            let applied = try KubeDocument(yaml: String(contentsOf: url, encoding: .utf8))
            XCTAssertEqual(applied.currentContext, "other")
            XCTAssertEqual(applied.entry(.contexts, named: "dev")?.value("namespace"), "payments")
            XCTAssertEqual(model.records.count, 1)
        }
    }

    func testUndoAndRedoAfterImmediateSwitchKeepTheNewContext() async throws {
        try await withModel(immediate: true) { model, _ in
            model.editor?.fields["namespace"] = "payments"
            try model.flushEditor()
            model.makeActive("other")
            model.undo()
            XCTAssertEqual(model.document?.currentContext, "other")
            XCTAssertEqual(model.document?.entry(.contexts, named: "dev")?.value("namespace"), "default")
            XCTAssertFalse(model.hasPendingChanges)
            model.redo()
            XCTAssertEqual(model.document?.currentContext, "other")
            XCTAssertEqual(model.document?.entry(.contexts, named: "dev")?.value("namespace"), "payments")
            XCTAssertEqual(model.pendingChanges?.activeContextChanged, false)
        }
    }

    func testRedoAfterImmediateSwitchKeepsTheNewContext() async throws {
        try await withModel(immediate: true) { model, _ in
            model.editor?.fields["namespace"] = "payments"
            try model.flushEditor()
            model.undo()
            model.makeActive("other")
            model.redo()
            XCTAssertEqual(model.document?.currentContext, "other")
            XCTAssertEqual(model.document?.entry(.contexts, named: "dev")?.value("namespace"), "payments")
            XCTAssertEqual(model.pendingChanges?.activeContextChanged, false)
        }
    }

    func testImmediateSwitchLeavesABrokenDraftInTheHistoryAlone() async throws {
        try await withModel(immediate: true) { model, _ in
            model.editRaw("broken: [")
            model.undo()
            model.makeActive("other")
            model.redo()
            XCTAssertEqual(model.draftText, "broken: [")
            XCTAssertNotNil(model.parseIssue)
        }
    }

    func testImmediateClearEmptiesTheActiveContextInTheFile() async throws {
        try await withModel(immediate: true) { model, url in
            model.clearActive()
            XCTAssertEqual(try KubeDocument(yaml: String(contentsOf: url, encoding: .utf8)).currentContext, "")
            XCTAssertEqual(model.document?.currentContext, "")
            XCTAssertFalse(model.hasPendingChanges)
            XCTAssertNil(model.draftStatus)
        }
    }

    func testImmediateSwitchReplacesAnEarlierStagedSwitch() async throws {
        try await withModel(immediate: false) { model, url in
            model.makeActive("other")
            XCTAssertEqual(model.pendingChanges?.activeContextChanged, true)
            model.defaults.set(true, forKey: ContextSwitching.immediateKey)
            XCTAssertEqual(model.pendingChanges?.activeContextChanged, true)
            model.makeActive("dev")
            XCTAssertEqual(model.document?.currentContext, "dev")
            XCTAssertFalse(model.hasPendingChanges)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), Self.fixture)
            XCTAssertTrue(model.canUndo)
            model.undo()
            XCTAssertEqual(model.document?.currentContext, "dev")
            XCTAssertFalse(model.hasPendingChanges)
        }
    }

    func testContextMissingFromTheFileIsStagedInstead() async throws {
        try await withModel(immediate: true) { model, url in
            model.addEntry()
            let name = try XCTUnwrap(model.selectedName)
            model.makeActive()
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), Self.fixture)
            XCTAssertEqual(model.document?.currentContext, name)
            XCTAssertEqual(model.pendingChanges?.activeContextChanged, true)
            XCTAssertEqual(model.draftStatus, "Staged: ‘\(name)’ isn't on disk yet")
        }
    }

    func testFileThatCannotBePatchedStagesTheSwitch() async throws {
        let json = #"{"apiVersion": "v1", "kind": "Config", "clusters": [], "users": [], "contexts": [{"name": "dev", "context": {}}, {"name": "other", "context": {}}], "current-context": "dev"}"#
        try await withModel(initial: json, immediate: true) { model, url in
            model.makeActive("other")
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), json)
            XCTAssertEqual(model.document?.currentContext, "other")
            XCTAssertEqual(model.pendingChanges?.activeContextChanged, true)
            XCTAssertNil(model.errorMessage)
        }
    }

    func testImmediateSwitchRefusesAnExternallyChangedFile() async throws {
        try await withModel(immediate: true) { model, url in
            let external = Self.fixture + "# external\n"
            try Data(external.utf8).write(to: url)
            model.makeActive("other")
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), external)
            XCTAssertEqual(model.document?.currentContext, "dev")
            XCTAssertTrue(model.fileChangedOnDisk)
            XCTAssertNotNil(model.errorMessage)
        }
    }

    func testImmediateSwitchWaitsForRecoveryToBeResolved() async throws {
        try await withModel(immediate: true) { model, url in
            model.recoveryContents = Data(Self.fixture.utf8)
            model.makeActive("other")
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), Self.fixture)
            XCTAssertEqual(model.document?.currentContext, "dev")
            XCTAssertNotNil(model.errorMessage)
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
            XCTAssertEqual(try model.store.backups.record(model.records[0], for: url).contents, Data(Self.fixture.utf8))
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
            XCTAssertTrue(model.hasNoConfiguration)
            XCTAssertFalse(model.hasPendingChanges)
            model.createConfiguration()
            XCTAssertFalse(model.hasNoConfiguration)
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
            let undo = try KubeDocument(yaml: model.store.backups.rollbackText(model.store.backups.record(model.records[0], for: url), for: url))
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
            let older = BackupRecord(configurationPath: url.path, contents: Data(Self.fixture.utf8), createdAt: Date(timeIntervalSince1970: 1_577_880_000)).summary
            let newer = BackupRecord(configurationPath: url.path, contents: Data(Self.fixture.utf8), createdAt: Date(timeIntervalSince1970: 1_704_110_400)).summary
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

    func testContextSwitchStaysPendingUntilApply() async throws {
        try await withModel { model, url in
            model.selectEntry("other")
            model.makeActive()
            XCTAssertEqual(model.document?.currentContext, "other")
            XCTAssertEqual(model.pendingChanges?.activeContextChanged, true)
            XCTAssertEqual(try KubeDocument(yaml: String(contentsOf: url, encoding: .utf8)).currentContext, "dev")
            model.commit()
            XCTAssertEqual(try KubeDocument(yaml: String(contentsOf: url, encoding: .utf8)).currentContext, "other")
            XCTAssertEqual(model.pendingChanges?.activeContextChanged, false)
        }
    }

    func testYAMLEditorOpensWithoutConfirmationAndReturnsToForms() async throws {
        try await withModel { model, _ in
            model.toggleRawEditor()
            XCTAssertTrue(model.showRaw)
            XCTAssertNil(model.editor)
            model.toggleRawEditor()
            XCTAssertFalse(model.showRaw)
            XCTAssertEqual(model.selectedName, "dev")
        }
    }

    func testIssuesClearWhenTheEntryCausingThemIsRemoved() async throws {
        try await withModel { model, _ in
            model.addEntry()
            model.editor?.fields["cluster"] = ""
            model.commitForm()
            XCTAssertFalse(model.validationIssues.isEmpty)
            XCTAssertFalse(model.canApply)
            model.deleteEntry()
            XCTAssertTrue(model.validationIssues.isEmpty)
            XCTAssertFalse(model.hasPendingChanges)
        }
    }

    func testLineWrappingIsRemembered() async throws {
        try await withModel { model, _ in
            XCTAssertFalse(model.wrapsYAML)
            model.wrapsYAML = true
            XCTAssertTrue(model.defaults.bool(forKey: "wrapsYAML"))
            XCTAssertTrue(AppModel(store: model.store, defaults: model.defaults, initialURL: model.snapshot?.url).wrapsYAML)
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

    func testUndoAndRedoStepThroughFinishedActions() async throws {
        try await withModel { model, _ in
            XCTAssertFalse(model.canUndo)
            model.editor?.fields["namespace"] = "first"
            model.commitForm()
            model.selectEntry("other")
            model.makeActive()
            XCTAssertEqual(model.document?.currentContext, "other")

            model.undo()
            XCTAssertEqual(model.document?.currentContext, "dev")
            XCTAssertEqual(model.document?.entry(.contexts, named: "dev")?.value("namespace"), "first")
            model.undo()
            XCTAssertEqual(model.draftText, Self.fixture)
            XCTAssertFalse(model.hasPendingChanges)
            XCTAssertFalse(model.canUndo)
            XCTAssertEqual(model.selectedName, "dev", "Undo selects the entry it changed")
            XCTAssertEqual(model.editor?.fields["namespace"], "default")

            model.redo()
            model.redo()
            XCTAssertEqual(model.document?.currentContext, "other")
            XCTAssertFalse(model.canRedo)
        }
    }

    func testNewChangeClearsRedo() async throws {
        try await withModel { model, _ in
            model.addEntry()
            model.undo()
            XCTAssertTrue(model.canRedo)
            model.addEntry()
            XCTAssertFalse(model.canRedo)
        }
    }

    func testUndoRevertsAFormEditThatCannotBeCommitted() async throws {
        try await withModel { model, _ in
            model.editor?.name = "other"
            XCTAssertNotNil(model.nameError)
            model.undo()
            XCTAssertEqual(model.editor?.name, "dev")
            XCTAssertFalse(model.hasPendingChanges)
            XCTAssertNil(model.errorMessage)
        }
    }

    func testBadNameStaysInTheFormWithItsErrorInsteadOfAnAlert() async throws {
        try await withModel { model, _ in
            model.editor?.name = "   "
            XCTAssertEqual(model.nameError, "Enter a name.")
            model.commitForm()
            XCTAssertNil(model.errorMessage)
            XCTAssertEqual(model.draftText, Self.fixture)
            model.editor?.name = "other"
            XCTAssertEqual(model.nameError, "A context named ‘other’ already exists.")
            model.editor?.name = "renamed"
            XCTAssertNil(model.nameError)
            model.commitForm()
            XCTAssertNotNil(model.document?.entry(.contexts, named: "renamed"))
        }
    }

    func testDiscardIsOneUndoableStep() async throws {
        try await withModel { model, _ in
            model.editor?.fields["namespace"] = "first"
            model.commitForm()
            model.selectEntry("other")
            model.makeActive()
            let draft = model.draftText
            model.discardDraft()
            XCTAssertFalse(model.hasPendingChanges)
            model.undo()
            XCTAssertEqual(model.draftText, draft)
            XCTAssertEqual(model.pendingChanges?.count, 2)
        }
    }

    func testApplyClearsHistory() async throws {
        try await withModel { model, _ in
            model.addEntry()
            XCTAssertTrue(model.canUndo)
            model.commit()
            XCTAssertFalse(model.canUndo)
            XCTAssertFalse(model.canRedo)
            XCTAssertEqual(model.statusMessage, "Applied")
        }
    }

    func testReloadClearsHistory() async throws {
        try await withModel { model, url in
            model.addEntry()
            model.discardDraft()
            model.load(url)
            XCTAssertFalse(model.canUndo)
            XCTAssertFalse(model.canRedo)
        }
    }

    func testYAMLSessionIsOneUndoStep() async throws {
        try await withModel { model, _ in
            model.addEntry()
            let before = model.draftText
            model.editRaw(before + "# one\n")
            model.editRaw(before + "# one\n# two\n")
            model.endRawSession()
            model.undo()
            XCTAssertEqual(model.draftText, before)
            model.redo()
            XCTAssertEqual(model.draftText, before + "# one\n# two\n")
            model.undo()
            model.undo()
            XCTAssertEqual(model.draftText, Self.fixture)
        }
    }

    func testChangingAValueBackLeavesNothingToApply() async throws {
        try await withModel { model, _ in
            model.editor?.fields["namespace"] = "changed"
            model.commitForm()
            XCTAssertEqual(model.pendingChanges?.count, 1)
            model.editor?.fields["namespace"] = "default"
            model.commitForm()
            XCTAssertEqual(model.pendingChanges?.count, 0)
            XCTAssertFalse(model.hasPendingChanges)
            XCTAssertEqual(model.draftText, Self.fixture)
        }
    }

    func testChangeMarkersFollowEditsBeforeTheyAreCommitted() async throws {
        try await withModel { model, _ in
            model.editor?.fields["namespace"] = "typing"
            XCTAssertEqual(model.pendingChanges?.count, 1)
            XCTAssertTrue(model.isFieldChanged("namespace"))
            XCTAssertFalse(model.isFieldChanged("cluster"))
            XCTAssertFalse(model.isNameChanged)
            model.editor?.name = "renamed"
            XCTAssertTrue(model.isNameChanged)
        }
    }

    func testApplyIsUnavailableWhileTheConfigurationHasIssues() async throws {
        try await withModel { model, _ in
            model.editor?.fields["cluster"] = ""
            XCTAssertTrue(model.hasPendingChanges)
            XCTAssertFalse(model.validationIssues.isEmpty)
            XCTAssertFalse(model.canApply)
            model.editor?.fields["cluster"] = "dev"
            XCTAssertFalse(model.canApply, "Back to the original value, so there is nothing to apply")
            model.editor?.fields["namespace"] = "fixed"
            XCTAssertTrue(model.canApply)
        }
    }

    func testDeleteNeedsNoConfirmationAndCanBeUndone() async throws {
        try await withModel { model, _ in
            model.ask = { _, _, _ in XCTFail("Only the active context confirms"); return 1 }
            model.deleteEntry("other")
            XCTAssertNil(model.document?.entry(.contexts, named: "other"))
            XCTAssertEqual(model.selectedName, "dev", "Deleting another row keeps the selection")
            XCTAssertEqual(model.pendingChanges?.count, 1)
            model.undo()
            XCTAssertNotNil(model.document?.entry(.contexts, named: "other"))
        }
    }

    func testDeletingTheActiveContextAsksAndClearsIt() async throws {
        try await withModel { model, _ in
            var asked = false
            model.ask = { _, _, _ in asked = true; return 1 }
            model.deleteEntry("dev")
            XCTAssertTrue(asked)
            XCTAssertNotNil(model.document?.entry(.contexts, named: "dev"))
            model.ask = { _, _, _ in 0 }
            model.deleteEntry("dev")
            XCTAssertNil(model.document?.entry(.contexts, named: "dev"))
            XCTAssertEqual(model.document?.currentContext, "")
            XCTAssertEqual(model.selectedName, "other")
        }
    }

    func testEntriesInUseReportWhyTheyCannotBeDeleted() async throws {
        try await withModel { model, _ in
            model.selectSection(.clusters)
            XCTAssertEqual(model.deleteBlockReason("dev"), "Used by 2 contexts")
            model.deleteEntry("dev")
            XCTAssertNotNil(model.errorMessage)
            XCTAssertNotNil(model.document?.entry(.clusters, named: "dev"))
        }
    }

    func testDuplicateSelectsTheCopyAndIsOneStep() async throws {
        try await withModel { model, _ in
            model.duplicateEntry("dev")
            XCTAssertEqual(model.selectedName, "dev-copy")
            XCTAssertEqual(model.editor?.fields["namespace"], "default")
            model.undo()
            XCTAssertNil(model.document?.entry(.contexts, named: "dev-copy"))
            XCTAssertEqual(model.draftText, Self.fixture)
        }
    }

    func testActionsOnARenamedRowUseItsNewName() async throws {
        try await withModel { model, _ in
            model.editor?.name = "renamed"
            model.makeActive("dev")
            XCTAssertEqual(model.document?.currentContext, "renamed")
            XCTAssertNil(model.errorMessage)
        }
    }

    func testParseErrorsExposeTheirLine() async throws {
        try await withModel { model, _ in
            XCTAssertNil(model.parseIssueLine)
            model.editRaw("clusters:\n  - name: dev\n bad: [\n")
            XCTAssertNotNil(model.parseIssueLine)
            model.editRaw(Self.fixture)
            XCTAssertNil(model.parseIssueLine)
        }
    }

    func testRemovingTheOnlyEntryOfAKindTheFileLeftOutLeavesNothingToApply() async throws {
        let text = "apiVersion: v1\nkind: Config\nclusters:\n- name: dev\n  cluster: {server: 'https://dev.invalid'}\ncontexts:\n- name: dev\n  context: {cluster: dev}\n"
        try await withModel(initial: text) { model, _ in
            model.selectSection(.users)
            model.addEntry()
            XCTAssertTrue(model.hasPendingChanges)
            model.deleteEntry()
            XCTAssertFalse(model.hasPendingChanges)
            XCTAssertEqual(model.draftText, text)

            model.selectSection(.contexts)
            model.makeActive("dev")
            model.clearActive()
            XCTAssertFalse(model.hasPendingChanges)
        }
    }

    func testFailedApplyClosesReviewSoItsErrorCanAppear() async throws {
        try await withModel { model, url in
            model.editor?.fields["namespace"] = "draft"
            var continued = false
            model.requestReview { continued = true }
            XCTAssertTrue(model.showReview)
            try Data(("# external\n" + Self.fixture).utf8).write(to: url)
            model.commit()
            XCTAssertFalse(model.showReview)
            XCTAssertNotNil(model.errorMessage)
            XCTAssertTrue(model.hasPendingChanges)

            try Data(Self.fixture.utf8).write(to: url)
            model.requestReview()
            model.commit()
            XCTAssertFalse(continued, "The abandoned Apply's continuation must not run later")
        }
    }

    func testEverySheetCountsAsOpen() async throws {
        try await withModel { model, _ in
            XCTAssertFalse(model.sheetIsOpen)
            model.showImportSource = true
            XCTAssertTrue(model.sheetIsOpen)
            try model.prepareImport(yaml: Self.fixture, directory: nil)
            XCTAssertTrue(model.sheetIsOpen, "The import source sheet hands over to the import review")
            model.showImport = false
            model.addEntry()
            model.requestReview()
            XCTAssertTrue(model.sheetIsOpen)
            model.cancelReview()
            XCTAssertFalse(model.sheetIsOpen)
        }
    }

    func testRollbackDropsTheBackupSearch() async throws {
        try await withModel { model, _ in
            model.editor?.fields["namespace"] = "changed"
            model.commitForm()
            model.commit()
            model.selectSection(.backups)
            model.search = String(Calendar.current.component(.year, from: model.records[0].createdAt))
            XCTAssertNotNil(model.selectedBackup)
            model.rollbackSelected()
            XCTAssertEqual(model.section, .contexts)
            XCTAssertEqual(model.search, "")
            XCTAssertEqual(model.visibleEntries.count, 2)
            XCTAssertEqual(model.selectedName, "dev")
            XCTAssertEqual(model.statusMessage, "Rollback staged")
        }
    }

    func testRollbackMatchingTheFileLeavesNoStatus() async throws {
        let canonical = try KubeDocument(yaml: Self.fixture).serialized()
        try await withModel(initial: canonical) { model, _ in
            model.editor?.fields["namespace"] = "changed"
            model.commitForm()
            model.commit()
            model.editor?.fields["namespace"] = "default"
            model.commitForm()
            model.commit()
            XCTAssertEqual(model.draftText, canonical)
            model.selectSection(.backups)
            model.selectedBackupID = model.records.last?.id
            model.rollbackSelected()
            XCTAssertFalse(model.hasPendingChanges)
            XCTAssertNil(model.statusMessage)
        }
    }

    func testImportDropsASearchFromAnotherSection() async throws {
        try await withModel { model, _ in
            model.selectSection(.clusters)
            model.search = "extra"
            let incoming = try KubeDocument(yaml: "clusters: [{name: extra, cluster: {server: 'https://extra.invalid'}}]")
            try model.acceptImport(ImportPlan(target: model.document!, incoming: incoming, sourceDirectory: nil))
            XCTAssertEqual(model.section, .contexts)
            XCTAssertEqual(model.search, "")
            XCTAssertEqual(model.selectedName, "dev")
            XCTAssertEqual(model.statusMessage, "Import staged")
            model.undo()
            XCTAssertNil(model.document?.entry(.clusters, named: "extra"))
        }
    }

    func testSearchFindsContextsByUser() async throws {
        let yaml = Self.fixture.replacingOccurrences(of: "context: {cluster: dev}", with: "context: {cluster: dev, user: deployer}")
            .replacingOccurrences(of: "users: []", with: "users:\n- name: deployer\n  user: {token: t}")
        try await withModel(initial: yaml) { model, _ in
            model.search = "deployer"
            XCTAssertEqual(model.visibleEntries.map(\.name), ["other"])
        }
    }

    func testLoadingAConfigurationDropsTheSearch() async throws {
        try await withModel { model, url in
            model.search = "no-such-context"
            model.load(url)
            XCTAssertEqual(model.search, "")
            XCTAssertEqual(model.selectedName, "dev")
        }
    }

    func testAddAndDuplicateDropASearchThatWouldHideTheNewRow() async throws {
        try await withModel { model, _ in
            model.search = "other"
            model.addEntry()
            XCTAssertEqual(model.search, "")
            XCTAssertEqual(model.selectedName, "new-context")
            model.search = "dev"
            model.duplicateEntry("dev")
            XCTAssertEqual(model.search, "dev", "The copy's name matches, so the search stays")
            model.search = "other"
            model.duplicateEntry("dev")
            XCTAssertEqual(model.search, "")
            XCTAssertEqual(model.selectedName, "dev-copy-2")
        }
    }

    func testACommittedEditOfAnyKindDropsASearchThatWouldHideItsRow() async throws {
        try await withModel { model, _ in
            model.selectSection(.clusters)
            model.search = "dev"
            model.editor?.name = "staging"
            model.editor?.fields["server"] = "https://staging.invalid"
            try model.flushEditor()
            XCTAssertEqual(model.search, "")
            XCTAssertEqual(model.visibleEntries.map(\.name), ["staging"])
        }
    }

    func testReturningFromYAMLKeepsTheSelectedEntry() async throws {
        try await withModel { model, _ in
            model.selectEntry("other")
            model.toggleRawEditor()
            model.toggleRawEditor()
            XCTAssertEqual(model.selectedName, "other")
            XCTAssertEqual(model.editor?.originalName, "other")
        }
    }

    func testReturningFromYAMLFallsBackWhenTheEntryWasRemoved() async throws {
        try await withModel { model, _ in
            model.selectEntry("other")
            model.toggleRawEditor()
            model.editRaw(Self.fixture.replacingOccurrences(of: "- name: other\n  context: {cluster: dev}\n", with: ""))
            model.toggleRawEditor()
            XCTAssertEqual(model.selectedName, "dev")
            XCTAssertEqual(model.editor?.originalName, "dev")
        }
    }

    func testRedoCommitsAnUnfinishedFormEdit() async throws {
        try await withModel { model, _ in
            model.addEntry()
            model.undo()
            XCTAssertTrue(model.canRedo)
            model.editor?.fields["namespace"] = "typed"
            model.redo()
            XCTAssertEqual(model.document?.entry(.contexts, named: "dev")?.value("namespace"), "typed")
            XCTAssertNil(model.document?.entry(.contexts, named: "new-context"))
            XCTAssertFalse(model.canRedo)
        }
    }

    func testRedoLeavesABadNameInTheForm() async throws {
        try await withModel { model, _ in
            model.addEntry()
            model.undo()
            model.editor?.name = "other"
            model.redo()
            XCTAssertEqual(model.editor?.name, "other")
            XCTAssertTrue(model.canRedo)
        }
    }

    func testStatusClearsWhenAnActionLeavesNothingToApply() async throws {
        try await withModel { model, _ in
            model.makeActive("other")
            XCTAssertEqual(model.statusMessage, "Context switch staged")
            model.makeActive("dev")
            XCTAssertFalse(model.hasPendingChanges)
            XCTAssertNil(model.statusMessage)
        }
    }

    func testDiscardDuringAYAMLSessionKeepsTheSessionAsItsOwnStep() async throws {
        try await withModel { model, _ in
            model.toggleRawEditor()
            model.editRaw(Self.fixture + "# edited\n")
            model.discardDraft()
            XCTAssertEqual(model.draftText, Self.fixture)
            model.undo()
            XCTAssertEqual(model.draftText, Self.fixture + "# edited\n")
            model.undo()
            XCTAssertEqual(model.draftText, Self.fixture)
            XCTAssertFalse(model.canUndo)
        }
    }

    func testLeavingYAMLForASectionEndsTheSession() async throws {
        try await withModel { model, _ in
            model.toggleRawEditor()
            model.editRaw(Self.fixture + "# edited\n")
            model.selectSection(.clusters)
            XCTAssertFalse(model.showRaw)
            model.undo()
            XCTAssertEqual(model.draftText, Self.fixture)
        }
    }

    func testAYAMLSessionWithNoNetChangeLeavesNoStep() async throws {
        try await withModel { model, _ in
            model.toggleRawEditor()
            model.editRaw(Self.fixture + "# edited\n")
            model.editRaw(Self.fixture)
            model.toggleRawEditor()
            XCTAssertFalse(model.canUndo)
        }
    }

    func testApplyDuringAYAMLSessionClearsItsHistory() async throws {
        try await withModel { model, _ in
            model.toggleRawEditor()
            model.editRaw(Self.fixture.replacingOccurrences(of: "namespace: default", with: "namespace: edited"))
            XCTAssertTrue(model.canUndo)
            model.commit()
            XCTAssertFalse(model.canUndo)
            XCTAssertFalse(model.hasPendingChanges)
        }
    }

    func testHistoryKeepsTheLatestHundredSteps() async throws {
        try await withModel { model, _ in
            for step in 0..<110 {
                model.editor?.fields["namespace"] = "step-\(step)"
                model.commitForm()
            }
            for _ in 0..<100 { model.undo() }
            XCTAssertFalse(model.canUndo)
            XCTAssertEqual(model.document?.entry(.contexts, named: "dev")?.value("namespace"), "step-9")
        }
    }

    func testUndoingCreationReturnsToTheMissingFilePrompt() async throws {
        try await withModel(initial: nil) { model, _ in
            model.createConfiguration()
            model.undo()
            XCTAssertTrue(model.hasNoConfiguration)
            XCTAssertNil(model.document)
            model.redo()
            XCTAssertFalse(model.hasNoConfiguration)
            XCTAssertNotNil(model.document)
        }
    }

    func testClearActiveIsStagedAndUndoable() async throws {
        try await withModel { model, _ in
            model.clearActive()
            XCTAssertEqual(model.document?.currentContext, "")
            XCTAssertEqual(model.pendingChanges?.activeContextChanged, true)
            XCTAssertEqual(model.statusMessage, "Active context cleared")
            model.undo()
            XCTAssertEqual(model.document?.currentContext, "dev")
        }
    }

    func testAddEntryPicksAFreeNameAndDefaultsItsReferences() async throws {
        try await withModel { model, _ in
            model.addEntry()
            model.addEntry()
            XCTAssertEqual(model.selectedName, "new-context-2")
            XCTAssertEqual(model.editor?.fields["cluster"], "dev")
            XCTAssertEqual(model.editor?.fields["user"], "")
        }
    }

    func testDeletingARowRenamedInTheFormUsesItsNewName() async throws {
        try await withModel { model, _ in
            model.selectEntry("other")
            model.editor?.name = "renamed"
            model.deleteEntry("other")
            XCTAssertNil(model.document?.entry(.contexts, named: "renamed"))
            XCTAssertNil(model.document?.entry(.contexts, named: "other"))
            XCTAssertEqual(model.selectedName, "dev")
        }
    }

    func testDeleteBlockReasonCountsReferencingContexts() async throws {
        try await withModel { model, _ in
            model.deleteEntry("other")
            model.selectSection(.clusters)
            XCTAssertEqual(model.deleteBlockReason("dev"), "Used by 1 context")
            model.selectSection(.contexts)
            XCTAssertNil(model.deleteBlockReason("dev"))
            model.selectSection(.backups)
            XCTAssertEqual(model.deleteBlockReason("dev"), "Nothing to delete")
        }
    }

    func testVisibleEntriesSortNaturallyAndSearchSeveralFields() async throws {
        let yaml = """
        clusters:
        - {name: c10, cluster: {server: 'https://ten.invalid'}}
        - {name: c9, cluster: {server: 'https://nine.invalid'}}
        contexts:
        - {name: b, context: {cluster: c10, namespace: payments}}
        - {name: a, context: {cluster: c9}}
        """
        try await withModel(initial: yaml) { model, _ in
            XCTAssertEqual(model.visibleEntries.map(\.name), ["a", "b"])
            model.search = "PAYMENTS"
            XCTAssertEqual(model.visibleEntries.map(\.name), ["b"])
            model.search = "c9"
            XCTAssertEqual(model.visibleEntries.map(\.name), ["a"])
            model.selectSection(.clusters)
            XCTAssertEqual(model.visibleEntries.map(\.name), ["c9", "c10"])
            model.search = "ten.invalid"
            XCTAssertEqual(model.visibleEntries.map(\.name), ["c10"])
        }
    }

    func testReviewIsRefusedWhileTheConfigurationHasIssues() async throws {
        try await withModel { model, _ in
            model.editor?.fields["cluster"] = ""
            model.requestReview()
            XCTAssertFalse(model.showReview)
            XCTAssertNotNil(model.errorMessage)
        }
    }

    func testUndoAndRedoCommandsReachTheModelWithoutAFocusedField() async throws {
        try await withModel { model, _ in
            _ = NSApplication.shared
            model.addEntry()
            model.undoCommand()
            XCTAssertNil(model.document?.entry(.contexts, named: "new-context"))
            XCTAssertTrue(model.canRedoCommand)
            model.redoCommand()
            XCTAssertNotNil(model.document?.entry(.contexts, named: "new-context"))
        }
    }

    @MainActor private final class EditorHarness {
        let coordinator: YAMLEditor.Coordinator
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [], backing: .buffered, defer: true)
        let ruler: LineNumberRuler

        init(model: AppModel) {
            coordinator = YAMLEditor.Coordinator(model: model)
            textView.allowsUndo = true
            textView.textContainerInset = NSSize(width: 6, height: 10)
            textView.delegate = coordinator
            scrollView.documentView = textView
            window.contentView = scrollView
            window.makeFirstResponder(textView)
            ruler = LineNumberRuler(textView: textView, scrollView: scrollView)
            scrollView.verticalRulerView = ruler
            coordinator.attach(textView, scrollView: scrollView, ruler: ruler)
            coordinator.sync(text: model.draftText, errorLine: model.parseIssueLine)
            model.rawEditor = textView
        }

        func type(_ text: String) {
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            textView.insertText(text, replacementRange: textView.selectedRange())
            // Undo groups close between events, so let the run loop turn as it would after a keystroke.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }

        /// The running app gets this from AppKit after an undo, but a window that was never shown doesn't.
        func deliverChange() { textView.didChangeText() }
    }

    func testEditorTypingReachesTheModelAndItsUndoStepsBackThroughIt() async throws {
        try await withModel { model, _ in
            model.toggleRawEditor()
            let editor = EditorHarness(model: model)
            editor.type("# typed\n")
            XCTAssertEqual(model.draftText, Self.fixture + "# typed\n")
            XCTAssertTrue(model.rawCanUndo)
            model.undo()
            editor.deliverChange()
            XCTAssertEqual(model.draftText, Self.fixture)
            XCTAssertEqual(editor.textView.string, Self.fixture)
            XCTAssertTrue(model.rawCanRedo)
            model.redo()
            editor.deliverChange()
            XCTAssertEqual(model.draftText, Self.fixture + "# typed\n")
        }
    }

    func testEditorUndoFallsThroughToMainHistoryOnceItsTypingIsGone() async throws {
        try await withModel { model, _ in
            model.addEntry()
            let staged = model.draftText
            model.toggleRawEditor()
            let editor = EditorHarness(model: model)
            editor.type("# typed\n")
            model.undo()
            editor.deliverChange()
            XCTAssertEqual(model.draftText, staged)
            XCTAssertFalse(model.rawCanUndo)
            model.undo()
            XCTAssertEqual(model.draftText, Self.fixture)
            editor.coordinator.sync(text: model.draftText, errorLine: nil)
            XCTAssertEqual(editor.textView.string, Self.fixture)
        }
    }

    func testEditorSyncReplacesTextAndStartsItsUndoOver() async throws {
        try await withModel { model, _ in
            model.toggleRawEditor()
            let editor = EditorHarness(model: model)
            editor.type("# typed\n")
            XCTAssertEqual(editor.textView.undoManager?.canUndo, true)
            editor.coordinator.sync(text: "replaced: true\n", errorLine: 1)
            XCTAssertEqual(editor.textView.string, "replaced: true\n")
            XCTAssertEqual(editor.textView.undoManager?.canUndo, false)
            XCTAssertEqual(editor.ruler.errorLine, 1)
        }
    }

    func testEditorDetachClearsItsUndoState() async throws {
        try await withModel { model, _ in
            model.toggleRawEditor()
            let editor = EditorHarness(model: model)
            editor.type("# typed\n")
            editor.coordinator.detach()
            XCTAssertNil(model.rawEditor)
            XCTAssertFalse(model.rawCanUndo)
            XCTAssertFalse(model.rawCanRedo)
        }
    }

    func testWrappingFitsTheTextBetweenItsInsets() async throws {
        try await withModel { model, _ in
            model.toggleRawEditor()
            let editor = EditorHarness(model: model)
            editor.coordinator.setWrapping(true)
            editor.coordinator.setWrapping(false)
            XCTAssertEqual(editor.textView.textContainer?.widthTracksTextView, false)
            editor.coordinator.setWrapping(true)
            let container = try XCTUnwrap(editor.textView.textContainer)
            XCTAssertTrue(container.widthTracksTextView)
            XCTAssertEqual(container.containerSize.width, editor.textView.frame.width - 12, "The inset applies on both sides")
        }
    }

    func testLongLinesOpenWithTheirStartClearOfTheGutter() async throws {
        let long = "kind: Config\nnote: " + String(repeating: "QUJD", count: 800) + "\n"
        try await withModel(initial: long) { model, _ in
            model.toggleRawEditor()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: YAMLEditor(model: model).frame(width: 500, height: 200))
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            // Suspends, since the editor's main-queue work can't run from inside this test's own turn.
            try await Task.sleep(for: .milliseconds(300))
            let scrollView = try XCTUnwrap(Self.scrollView(in: host))
            let clip = scrollView.contentView
            XCTAssertGreaterThan(clip.contentInsets.left, 0)
            XCTAssertEqual(clip.bounds.minX, -clip.contentInsets.left)
        }
    }

    @MainActor private static func scrollView(in view: NSView) -> NSScrollView? {
        view.subviews.lazy.compactMap { ($0 as? NSScrollView) ?? scrollView(in: $0) }.first
    }

    func testAnEmptyFileOffersTheSamePathAsAMissingOne() async throws {
        for blank in ["", "  \n\n"] {
            try await withModel(initial: blank) { model, url in
                XCTAssertTrue(model.hasNoConfiguration)
                XCTAssertNil(model.parseIssue)
                XCTAssertFalse(model.hasPendingChanges)
                XCTAssertTrue(model.canImport)
                model.createConfiguration()
                XCTAssertFalse(model.hasNoConfiguration)
                model.commit()
                XCTAssertNil(model.errorMessage)
                XCTAssertNotNil(try KubeDocument(yaml: String(contentsOf: url, encoding: .utf8)))
            }
        }
    }

    func testAnEmptyFileCanTakeAnImport() async throws {
        try await withModel(initial: "") { model, _ in
            try model.prepareImport(yaml: Self.fixture, directory: nil)
            try model.acceptImport(XCTUnwrap(model.importPlan))
            XCTAssertEqual(model.document?.entries(.contexts).count, 2)
            XCTAssertTrue(model.canApply)
        }
    }

    func testClearingAFileInTheEditorIsARepairNotAnEmptyFile() async throws {
        try await withModel { model, _ in
            model.editRaw("")
            XCTAssertFalse(model.hasNoConfiguration)
            XCTAssertNotNil(model.parseIssue)
            XCTAssertFalse(model.canImport)
        }
    }

    func testANumericValueSurvivesApplyReloadAndUndo() async throws {
        try await withModel { model, url in
            model.selectSection(.users)
            model.addEntry()
            model.editor?.fields["password"] = "1234"
            model.commitForm()
            model.undo()
            model.redo()
            XCTAssertEqual(model.validationIssues, [])
            XCTAssertTrue(model.canApply)
            model.commit()
            model.load(url)
            XCTAssertEqual(model.document?.entry(.users, named: "new-user")?.value("password"), "1234")
            XCTAssertEqual(model.validationIssues, [])
        }
    }

    func testClearingAFieldAndTypingItBackLeavesTheFileAlone() async throws {
        try await withModel { model, _ in
            model.editor?.fields["namespace"] = ""
            model.commitForm()
            XCTAssertTrue(model.hasPendingChanges)
            model.editor?.fields["namespace"] = "default"
            model.commitForm()
            XCTAssertFalse(model.hasPendingChanges)
            XCTAssertEqual(model.draftText, Self.fixture)
        }
    }

    func testIssuesAndCountsFollowEveryWayTheDraftChanges() async throws {
        try await withModel { model, _ in
            XCTAssertEqual(model.pendingChanges?.count, 0)
            model.editor?.fields["cluster"] = "gone"
            XCTAssertEqual(model.validationIssues.count, 1)
            XCTAssertEqual(model.pendingChanges?.count, 1)
            model.commitForm()
            XCTAssertEqual(model.validationIssues.count, 1)
            model.undo()
            XCTAssertEqual(model.validationIssues, [])
            XCTAssertEqual(model.pendingChanges?.count, 0)
            model.editRaw("contexts: [broken")
            XCTAssertEqual(model.validationIssues.count, 1)
            XCTAssertNil(model.pendingChanges)
            model.editRaw(Self.fixture.replacingOccurrences(of: "namespace: default", with: "namespace: applied"))
            XCTAssertEqual(model.pendingChanges?.count, 1)
            model.commit()
            XCTAssertEqual(model.pendingChanges?.count, 0, "Apply moves the comparison to the new file")
        }
    }

    func testDuplicateKeysMarkTheirLineInTheEditor() async throws {
        try await withModel { model, _ in
            model.editRaw("a: 1\nb: 2\nb: 3\n")
            XCTAssertEqual(model.parseIssueLine, 2)
            XCTAssertEqual(model.parseIssue?.contains("‘b’"), true)
        }
    }

    func testLeavingWithNothingPendingNeedsNoQuestion() async throws {
        try await withModel { model, _ in
            model.ask = { _, _, _ in XCTFail("Nothing to ask about"); return 2 }
            var continued = false
            model.resolvePendingChanges { continued = true }
            XCTAssertTrue(continued)
        }
    }

    func testLeavingCanCancelDiscardOrReview() async throws {
        try await withModel { model, _ in
            var continued = 0
            model.editor?.fields["namespace"] = "pending"
            model.ask = { _, _, _ in 2 }
            model.resolvePendingChanges { continued += 1 }
            XCTAssertEqual(continued, 0)
            XCTAssertTrue(model.hasPendingChanges)

            model.ask = { _, _, _ in 0 }
            model.resolvePendingChanges { continued += 1 }
            XCTAssertTrue(model.showReview)
            XCTAssertEqual(continued, 0)
            model.cancelReview()

            model.ask = { _, _, _ in 1 }
            model.resolvePendingChanges { continued += 1 }
            XCTAssertEqual(continued, 1)
            XCTAssertFalse(model.hasPendingChanges)
            XCTAssertEqual(model.draftText, Self.fixture)
        }
    }

    func testLeavingAfterAFailedBackupExportsThePreviousContents() async throws {
        try await withModel(backupFiles: UnwritableBackups()) { model, url in
            model.editor?.fields["namespace"] = "changed"
            model.requestReview()
            model.commit()
            let export = url.deletingLastPathComponent().appendingPathComponent("previous.yaml")
            var continued = false

            model.ask = { _, _, _ in 0 }
            model.chooseExportURL = { _, _ in nil }
            model.resolvePendingChanges { continued = true }
            XCTAssertFalse(continued, "Cancelling the save panel keeps the bytes and stays put")
            XCTAssertNotNil(model.recoveryContents)

            model.chooseExportURL = { _, _ in export }
            model.resolvePendingChanges { continued = true }
            XCTAssertTrue(continued)
            XCTAssertNil(model.recoveryContents)
            XCTAssertNil(model.backupWarning)
            XCTAssertEqual(try String(contentsOf: export, encoding: .utf8), Self.fixture)
        }
    }

    func testLeavingAfterAFailedBackupCanBeCancelled() async throws {
        try await withModel(backupFiles: UnwritableBackups()) { model, _ in
            model.editor?.fields["namespace"] = "changed"
            model.requestReview()
            model.commit()
            model.ask = { _, _, _ in 2 }
            var continued = false
            model.resolvePendingChanges { continued = true }
            XCTAssertFalse(continued)
            XCTAssertNotNil(model.recoveryContents)
            XCTAssertNotNil(model.backupWarning)
        }
    }

    func testPreviousContentsCannotBeExportedOverTheOpenFile() async throws {
        try await withModel(backupFiles: UnwritableBackups()) { model, url in
            model.editor?.fields["namespace"] = "changed"
            model.requestReview()
            model.commit()
            model.chooseExportURL = { _, _ in url }
            model.exportRecovery()
            XCTAssertNotNil(model.errorMessage)
            XCTAssertNotNil(model.recoveryContents)
        }
    }

    func testQuittingWithPendingChangesAsksFirst() async throws {
        try await withModel { model, _ in
            let delegate = ApplicationDelegate()
            delegate.model = model
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
            model.editor?.fields["namespace"] = "changed"
            var asked = false
            model.ask = { _, _, _ in asked = true; return 2 }
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
            XCTAssertTrue(asked)
            XCTAssertTrue(model.hasPendingChanges)
        }
    }

    func testLeavingAfterAFailedBackupCanDiscardThePreviousContents() async throws {
        try await withModel(backupFiles: UnwritableBackups()) { model, _ in
            model.editor?.fields["namespace"] = "changed"
            model.requestReview()
            model.commit()
            var continued = false
            model.ask = { _, _, _ in 1 }
            model.resolvePendingChanges { continued = true }
            XCTAssertTrue(continued)
            XCTAssertFalse(model.needsAttentionBeforeLeaving)
        }
    }

    func testExportWritesTheDraftButNeverTheOpenFile() async throws {
        try await withModel { model, url in
            model.editor?.fields["namespace"] = "exported"
            let export = url.deletingLastPathComponent().appendingPathComponent("draft.yaml")
            model.chooseExportURL = { _, _ in export }
            model.exportDraft()
            XCTAssertEqual(try KubeDocument(yaml: String(contentsOf: export, encoding: .utf8)).entry(.contexts, named: "dev")?.value("namespace"), "exported")

            model.chooseExportURL = { _, _ in url }
            model.exportDraft()
            XCTAssertNotNil(model.errorMessage)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), Self.fixture)
        }
    }

    func testContextMultiSelectionCommitsTheFormAndDisablesSingleEntryActions() async throws {
        try await withModel { model, _ in
            model.editor?.fields["namespace"] = "pending"
            model.selectContexts(["dev", "other"])
            XCTAssertTrue(model.hasMultipleContextSelection)
            XCTAssertNil(model.selectedName)
            XCTAssertNil(model.editor)
            XCTAssertEqual(model.document?.entry(.contexts, named: "dev")?.value("namespace"), "pending")
            XCTAssertTrue(model.canExportContexts)
            let draft = model.draftText
            model.makeActive("other")
            model.clearActive()
            model.duplicateEntry("dev")
            model.deleteEntry("other")
            XCTAssertEqual(model.draftText, draft)
            XCTAssertNotNil(model.deleteBlockReason("dev"))
            model.selectContexts(["other"])
            XCTAssertEqual(model.selectedName, "other")
            XCTAssertEqual(model.editor?.originalName, "other")
            XCTAssertFalse(model.hasMultipleContextSelection)
        }
    }

    func testNativeContextListSupportsMultipleSelectionAndUpdatesTheInspector() async throws {
        try await withModel { model, _ in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: MainView(model: model))
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(300))
            let table = try XCTUnwrap(Self.tables(in: host).first { $0.allowsMultipleSelection })
            table.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(model.selectedContextNames, ["dev", "other"])
            XCTAssertTrue(model.hasMultipleContextSelection)
            XCTAssertNil(model.editor)
            table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(model.selectedContextNames, ["other"])
            XCTAssertEqual(model.editor?.originalName, "other")
            model.editor?.name = "renamed"
            model.commitForm()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(model.selectedContextNames, ["renamed"])
            XCTAssertEqual(model.editor?.originalName, "renamed")
            model.selectContexts(["dev", "renamed"])
            model.toggleRawEditor()
            try await Task.sleep(for: .milliseconds(100))
            model.toggleRawEditor()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(model.selectedContextNames, ["dev", "renamed"])
            XCTAssertNil(model.editor)
        }
    }

    @MainActor private static func tables(in view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
    }

    func testQueuedNativeContextSelectionCannotReplaceSelectionAfterLoadingAnotherFile() async throws {
        try await withModel { model, url in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: MainView(model: model))
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(300))
            let table = try XCTUnwrap(Self.tables(in: host).first { $0.allowsMultipleSelection })
            let next = url.deletingLastPathComponent().appendingPathComponent("next-config")
            let yaml = Self.fixture.replacingOccurrences(of: "contexts:\n", with: "contexts:\n- name: aaa\n  context: {cluster: dev}\n")
            try Data(yaml.utf8).write(to: next)
            table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            model.load(next)
            XCTAssertEqual(model.selectedContextNames, ["aaa"])
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(model.selectedContextNames, ["aaa"])
            XCTAssertEqual(model.editor?.originalName, "aaa")
            XCTAssertEqual(model.snapshot?.url, next)
        }
    }

    func testQueuedContextSelectionsCoalesceAndExpireWhenTheWorkspaceChanges() async throws {
        try await withModel { model, _ in
            model.queueContextSelection(["other"])
            model.queueContextSelection(["dev", "other"])
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(model.selectedContextNames, ["dev", "other"], "The latest queued request wins")

            model.queueContextSelection(["other"])
            model.selectEntry("dev")
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(model.selectedContextNames, ["dev"])

            model.queueContextSelection(["other"])
            model.search = "dev"
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(model.selectedContextNames, ["dev"])
            model.search = ""

            model.queueContextSelection(["other"])
            model.toggleRawEditor()
            model.toggleRawEditor()
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(model.selectedContextNames, ["dev"])

            model.queueContextSelection(["other"])
            model.selectSection(.clusters)
            model.selectSection(.contexts)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(model.selectedContextNames, ["dev"])
        }
    }

    func testContextMultiSelectionFollowsARenameCommittedByTheSelectionChange() async throws {
        try await withModel { model, _ in
            model.editor?.name = "renamed"
            model.selectContexts(["dev", "other"])
            XCTAssertEqual(model.selectedContextNames, ["renamed", "other"])
            model.requestContextExport()
            XCTAssertEqual(Set(try exportedDocument(model).entries(.contexts).map(\.name)), ["renamed", "other"])
        }
    }

    func testFocusedContextRenameClearsAFilterThatWouldHideItsExport() async throws {
        try await withModel { model, url in
            model.search = "other"
            model.selectEntry("other")
            model.editor?.name = "renamed"
            model.editor?.fields["namespace"] = "pending"
            model.requestContextExport()
            XCTAssertNil(model.errorMessage)
            XCTAssertEqual(model.search, "")
            XCTAssertEqual(model.selectedContextNames, ["renamed"])
            let exported = try exportedDocument(model)
            XCTAssertEqual(exported.entries(.contexts).map(\.name), ["renamed"])
            XCTAssertEqual(exported.entry(.contexts, named: "renamed")?.value("namespace"), "pending")
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), Self.fixture)
            XCTAssertTrue(model.hasPendingChanges)
        }
    }

    func testInvalidFormPreventsChangingContextSelectionOrExporting() async throws {
        try await withModel { model, _ in
            model.editor?.name = ""
            model.selectContexts(["dev", "other"])
            XCTAssertEqual(model.selectedContextNames, ["dev"])
            XCTAssertEqual(model.editor?.name, "")
            model.errorMessage = nil
            model.requestContextExport()
            XCTAssertNotNil(model.errorMessage)
            XCTAssertNil(model.contextExportPlan)
        }
    }

    func testSearchRemovesHiddenContextsFromSelectionAndExport() async throws {
        try await withModel { model, _ in
            model.selectContexts(["dev", "other"])
            model.search = "other"
            XCTAssertEqual(model.selectedContextNames, ["other"])
            XCTAssertEqual(model.editor?.originalName, "other")
            model.requestContextExport()
            XCTAssertEqual(try exportedDocument(model).entries(.contexts).map(\.name), ["other"])
            model.closeContextExport()
            model.search = "no-match"
            XCTAssertTrue(model.selectedContextNames.isEmpty)
            XCTAssertNil(model.editor)
            XCTAssertFalse(model.canExportContexts)
            model.search = ""
            XCTAssertTrue(model.selectedContextNames.isEmpty, "Clearing search must not silently reselect hidden entries")
        }
    }

    func testSearchKeepsInvalidUnfinishedEditsVisible() async throws {
        try await withModel { model, _ in
            model.editor?.name = ""
            model.search = "other"
            XCTAssertEqual(model.search, "")
            XCTAssertEqual(model.selectedContextNames, ["dev"])
            XCTAssertEqual(model.editor?.name, "")
            XCTAssertNotNil(model.errorMessage)
        }
    }

    func testExportAvailabilityAndSelectionAcrossModesSectionsAndSheets() async throws {
        try await withModel { model, _ in
            model.selectContexts(["dev", "other"])
            model.toggleRawEditor()
            XCTAssertFalse(model.canExportContexts)
            model.toggleRawEditor()
            XCTAssertEqual(model.selectedContextNames, ["dev", "other"])
            XCTAssertTrue(model.hasMultipleContextSelection)
            model.showImportSource = true
            XCTAssertFalse(model.canExportContexts)
            model.requestContextExport()
            XCTAssertNil(model.contextExportPlan)
            model.showImportSource = false
            model.selectSection(.clusters)
            XCTAssertFalse(model.canExportContexts)
            XCTAssertTrue(model.selectedContextNames.isEmpty)
            model.selectSection(.contexts)
            XCTAssertEqual(model.selectedContextNames, ["dev"])
            model.requestContextExport()
            XCTAssertTrue(model.sheetIsOpen)
            XCTAssertFalse(model.canExportContexts)
            model.closeContextExport()
            XCTAssertFalse(model.sheetIsOpen)
            XCTAssertTrue(model.canExportContexts)
        }
    }

    func testSelectedContextExportUsesTheDraftAndLeavesDiskSelectionAndUndoIntact() async throws {
        try await withModel { model, url in
            model.editor?.fields["namespace"] = "exported"
            model.requestContextExport()
            let plan = try XCTUnwrap(model.contextExportPlan)
            let exported = try KubeDocument(yaml: plan.yaml)
            XCTAssertEqual(exported.entries(.contexts).map(\.name), ["dev"])
            XCTAssertEqual(exported.entry(.contexts, named: "dev")?.value("namespace"), "exported")
            let destination = url.deletingLastPathComponent().appendingPathComponent("subset.yaml")
            model.chooseExportURL = { _, _ in destination }
            try model.saveContextExport()
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), plan.yaml)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), Self.fixture)
            XCTAssertEqual(model.selectedContextNames, ["dev"])
            XCTAssertTrue(model.hasPendingChanges)
            XCTAssertNil(model.contextExportPlan)
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            model.undo()
            XCTAssertEqual(model.draftText, Self.fixture)
        }
    }

    func testCancelledOrFailedContextExportKeepsTheReviewAndSelection() async throws {
        try await withModel { model, url in
            model.selectContexts(["dev", "other"])
            model.requestContextExport()
            model.chooseExportURL = { _, _ in nil }
            try model.saveContextExport()
            XCTAssertNotNil(model.contextExportPlan)
            XCTAssertEqual(model.selectedContextNames, ["dev", "other"])
            model.chooseExportURL = { _, _ in url }
            XCTAssertThrowsError(try model.saveContextExport())
            let alias = url.deletingLastPathComponent().appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
            model.chooseExportURL = { _, _ in alias }
            XCTAssertThrowsError(try model.saveContextExport())
            XCTAssertNotNil(model.contextExportPlan)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), Self.fixture)
            XCTAssertEqual(model.selectedContextNames, ["dev", "other"])
        }
    }

    func testContextExportEmbedsAFileOnceAndCannotOverwriteItsSource() async throws {
        let yaml = Self.fixture.replacingOccurrences(of: "server: 'https://dev.invalid'", with: "server: 'https://dev.invalid', certificate-authority: ca.pem")
        try await withModel(initial: yaml) { model, url in
            let certificate = url.deletingLastPathComponent().appendingPathComponent("ca.pem")
            try Data("certificate".utf8).write(to: certificate)
            model.selectContexts(["dev", "other"])
            model.requestContextExport()
            let plan = try XCTUnwrap(model.contextExportPlan)
            XCTAssertTrue(plan.sourceFiles.contains(certificate.standardizedFileURL))
            XCTAssertTrue(plan.sourceFiles.contains(certificate.resolvingSymlinksInPath()))
            model.chooseExportURL = { _, _ in certificate }
            XCTAssertThrowsError(try model.saveContextExport())
            XCTAssertEqual(try String(contentsOf: certificate, encoding: .utf8), "certificate")
            try Data("changed externally".utf8).write(to: certificate)
            let destination = url.deletingLastPathComponent().appendingPathComponent("export.yaml")
            model.chooseExportURL = { _, _ in destination }
            try model.saveContextExport()
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), plan.yaml, "Save must use the reviewed file snapshot")
        }
    }

    func testContextExportProtectsOriginalAndCurrentTargetsOfARetargetedCredentialSymlink() async throws {
        let yaml = Self.fixture.replacingOccurrences(of: "server: 'https://dev.invalid'", with: "server: 'https://dev.invalid', certificate-authority: ca-link")
        try await withModel(initial: yaml) { model, url in
            let folder = url.deletingLastPathComponent()
            let alias = folder.appendingPathComponent("ca-link")
            let original = folder.appendingPathComponent("original.pem")
            let replacement = folder.appendingPathComponent("replacement.pem")
            try Data("original certificate".utf8).write(to: original)
            try Data("replacement certificate".utf8).write(to: replacement)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
            model.requestContextExport()
            XCTAssertNotNil(model.contextExportPlan)
            try FileManager.default.removeItem(at: alias)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: replacement)

            for destination in [original, replacement, alias] {
                model.chooseExportURL = { _, _ in destination }
                XCTAssertThrowsError(try model.saveContextExport())
                XCTAssertNotNil(model.contextExportPlan)
                XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "original certificate")
                XCTAssertEqual(try String(contentsOf: replacement, encoding: .utf8), "replacement certificate")
            }
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), replacement.path)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), yaml)
        }
    }

    func testMissingExportDependencyPreservesTheDraftAndCanBeRetried() async throws {
        let yaml = Self.fixture.replacingOccurrences(of: "server: 'https://dev.invalid'", with: "server: 'https://dev.invalid', certificate-authority: ca.pem")
        try await withModel(initial: yaml) { model, url in
            model.editor?.fields["namespace"] = "pending"
            model.requestContextExport()
            XCTAssertNil(model.contextExportPlan)
            XCTAssertNotNil(model.errorMessage)
            XCTAssertTrue(model.hasPendingChanges)
            XCTAssertEqual(model.selectedContextNames, ["dev"])
            try Data("certificate".utf8).write(to: url.deletingLastPathComponent().appendingPathComponent("ca.pem"))
            model.errorMessage = nil
            model.requestContextExport()
            XCTAssertNotNil(model.contextExportPlan)
            XCTAssertEqual(try exportedDocument(model).entry(.contexts, named: "dev")?.value("namespace"), "pending")
        }
    }

    func testUnrelatedValidationIssuesDoNotBlockContextExport() async throws {
        let yaml = Self.fixture.replacingOccurrences(of: "context: {cluster: dev}", with: "context: {cluster: missing}")
        try await withModel(initial: yaml) { model, _ in
            XCTAssertFalse(model.validationIssues.isEmpty)
            model.requestContextExport()
            XCTAssertNotNil(model.contextExportPlan)
            model.closeContextExport()
            model.selectEntry("other")
            model.requestContextExport()
            XCTAssertNil(model.contextExportPlan)
            XCTAssertNotNil(model.errorMessage)
        }
    }

    func testFileDropOpensImportReviewWithResolvedPathsAndDoesNotWrite() async throws {
        try await withModel { model, url in
            let incoming = url.deletingLastPathComponent().appendingPathComponent("provider.yaml")
            try Data("clusters: [{name: imported, cluster: {server: 'https://new.invalid', certificate-authority: ca.pem}}]".utf8).write(to: incoming)
            model.editor?.fields["namespace"] = "pending"
            XCTAssertTrue(model.importDroppedFiles([incoming]))
            XCTAssertTrue(model.showImport)
            XCTAssertFalse(model.showImportSource)
            XCTAssertEqual(model.importPlan?.incoming.entry(.clusters, named: "imported")?.value("certificate-authority"), incoming.deletingLastPathComponent().appendingPathComponent("ca.pem").standardizedFileURL.path)
            XCTAssertTrue(model.hasPendingChanges)
            XCTAssertNil(model.document?.entry(.clusters, named: "imported"))
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), Self.fixture)
            XCTAssertFalse(model.importDroppedFiles([incoming]), "Do not replace an open review")
        }
    }

    func testDropsRejectMultipleFilesURLsAndMalformedFilesWithoutChangingTheDraft() async throws {
        try await withModel { model, url in
            let initial = model.draftText
            for files in [[url, url], [URL(string: "https://example.invalid/config")!], []] {
                XCTAssertFalse(model.importDroppedFiles(files))
                XCTAssertNotNil(model.errorMessage)
                XCTAssertNil(model.importPlan)
                XCTAssertEqual(model.draftText, initial)
                model.errorMessage = nil
            }
            let malformed = url.deletingLastPathComponent().appendingPathComponent("bad")
            try Data("contexts: [".utf8).write(to: malformed)
            XCTAssertFalse(model.importDroppedFiles([malformed]))
            XCTAssertNotNil(model.errorMessage)
            XCTAssertFalse(model.showImport)
            XCTAssertEqual(model.draftText, initial)
        }
    }

    func testFileDropCanImportIntoAMissingConfiguration() async throws {
        try await withModel(initial: nil) { model, url in
            let incoming = url.deletingLastPathComponent().appendingPathComponent("provider")
            try Data(Self.fixture.utf8).write(to: incoming)
            XCTAssertTrue(model.importDroppedFiles([incoming]))
            XCTAssertTrue(model.showImport)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testRetentionStaysWithinItsRange() async throws {
        try await withModel { model, _ in
            XCTAssertEqual(model.retention, BackupRetention.defaultCount)
            model.defaults.set(-5, forKey: BackupRetention.key)
            XCTAssertEqual(model.retention, 0)
            model.defaults.set(50_000, forKey: BackupRetention.key)
            XCTAssertEqual(model.retention, 1000)
        }
    }

    func testADamagedBackupIsReportedWithoutTheApplyWarning() async throws {
        try await withModel { model, url in
            let folder = model.store.backups.location(for: model.snapshot!.resolvedURL)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("garbage".utf8).write(to: folder.appendingPathComponent("damaged.json"))
            model.editor?.fields["namespace"] = "changed"
            model.requestReview()
            model.commit()
            XCTAssertNil(model.backupWarning)
            XCTAssertNil(model.recoveryContents)
            XCTAssertNil(model.errorMessage)
            XCTAssertEqual(model.records.count, 1)
            XCTAssertEqual(model.damagedBackupCount, 1)
            XCTAssertEqual(try KubeDocument(yaml: String(contentsOf: url, encoding: .utf8)).entry(.contexts, named: "dev")?.value("namespace"), "changed")
        }
    }

    func testABackupDamagedAfterListingCannotBePreviewedOrRolledBack() async throws {
        try await withModel { model, _ in
            model.editor?.fields["namespace"] = "changed"
            model.requestReview()
            model.commit()
            let backup = try XCTUnwrap(model.records.first)
            let file = model.store.backups.location(for: model.snapshot!.resolvedURL).appendingPathComponent(backup.id + ".json")
            try Data("garbage".utf8).write(to: file)
            model.selectSection(.backups)
            XCTAssertEqual(model.records, [backup])
            XCTAssertThrowsError(try model.backupPreview(backup))
            model.rollbackSelected()
            XCTAssertNotNil(model.errorMessage)
            XCTAssertEqual(model.section, .backups)
            XCTAssertFalse(model.hasPendingChanges)
        }
    }

    func testAnOutsideChangeIsNoticedOnReturningAndClearedByReload() async throws {
        try await withModel { model, url in
            model.checkForExternalChange()
            XCTAssertFalse(model.fileChangedOnDisk)
            try Data(Self.fixture.replacingOccurrences(of: "default", with: "outside").utf8).write(to: url)
            model.checkForExternalChange()
            XCTAssertTrue(model.fileChangedOnDisk)
            XCTAssertEqual(model.document?.entry(.contexts, named: "dev")?.value("namespace"), "default", "Reloading stays explicit")
            model.reload()
            XCTAssertFalse(model.fileChangedOnDisk)
            XCTAssertEqual(model.document?.entry(.contexts, named: "dev")?.value("namespace"), "outside")
        }
    }

    func testAFailedApplyFlagsTheOutsideChange() async throws {
        try await withModel { model, url in
            model.editor?.fields["namespace"] = "changed"
            model.requestReview()
            try Data("kind: Config\n".utf8).write(to: url)
            model.commit()
            XCTAssertNotNil(model.errorMessage)
            XCTAssertTrue(model.fileChangedOnDisk)
        }
    }

    func testRecentFilesPutTheLatestFirstAndSurviveRelaunch() async throws {
        try await withModel { model, url in
            let other = url.deletingLastPathComponent().appendingPathComponent("other")
            try Data(Self.fixture.utf8).write(to: other)
            XCTAssertEqual(model.recentFiles, [url])
            model.openRecent(other)
            XCTAssertEqual(model.snapshot?.url, other)
            XCTAssertEqual(model.recentFiles, [other, url])
            model.openRecent(url)
            XCTAssertEqual(model.recentFiles, [url, other])
            XCTAssertEqual(AppModel(store: model.store, defaults: model.defaults, initialURL: url).recentFiles, [url, other])
            model.clearRecentFiles()
            XCTAssertEqual(model.recentFiles, [])
            XCTAssertNil(model.defaults.stringArray(forKey: "recentConfigurations")?.first)
        }
    }

    func testRecentFilesAreLimited() async throws {
        try await withModel { model, url in
            for number in 0..<12 {
                let file = url.deletingLastPathComponent().appendingPathComponent("config-\(number)")
                try Data(Self.fixture.utf8).write(to: file)
                model.openRecent(file)
            }
            XCTAssertEqual(model.recentFiles.count, 10)
            XCTAssertEqual(model.recentFiles.first?.lastPathComponent, "config-11")
        }
    }

    func testARecentFileThatIsGoneIsReportedAndForgotten() async throws {
        try await withModel { model, url in
            let gone = url.deletingLastPathComponent().appendingPathComponent("gone")
            try Data(Self.fixture.utf8).write(to: gone)
            model.openRecent(gone)
            try FileManager.default.removeItem(at: gone)
            model.openRecent(gone)
            XCTAssertNotNil(model.errorMessage)
            XCTAssertEqual(model.recentFiles, [url])
            XCTAssertEqual(model.snapshot?.url, gone, "The open file stays open")
        }
    }

    func testAMissingFileIsNotRememberedUntilApplyCreatesIt() async throws {
        try await withModel(initial: nil) { model, url in
            XCTAssertEqual(model.recentFiles, [])
            model.createConfiguration()
            model.requestReview()
            model.commit()
            XCTAssertEqual(model.recentFiles, [url])
        }
    }

    func testFindFocusesTheSearchOutsideTheYAMLEditor() async throws {
        try await withModel { model, _ in
            model.columnVisibility = .detailOnly
            model.find()
            XCTAssertEqual(model.searchFocusRequest, 1)
            XCTAssertEqual(model.columnVisibility, .detailOnly, "Find focuses the list without expanding the sidebar")
            model.toggleRawEditor()
            model.find()
            XCTAssertEqual(model.searchFocusRequest, 1)
        }
    }

    func testSidebarVisibilityStaysTheSameWhenTogglingTheEditor() async throws {
        try await withModel { model, _ in
            XCTAssertFalse(model.sidebarIsCollapsed)
            model.toggleSidebar()
            XCTAssertEqual(model.columnVisibility, .detailOnly)
            XCTAssertTrue(model.sidebarIsCollapsed)
            model.toggleRawEditor()
            XCTAssertEqual(model.columnVisibility, .detailOnly)
            XCTAssertTrue(model.sidebarIsCollapsed)
            model.toggleRawEditor()
            XCTAssertEqual(model.columnVisibility, .detailOnly)
            model.toggleSidebar()
            XCTAssertEqual(model.columnVisibility, .all)
            model.toggleRawEditor()
            XCTAssertEqual(model.columnVisibility, .all)
            model.toggleSidebar()
            XCTAssertEqual(model.columnVisibility, .detailOnly)
        }
    }

    func testSidebarVisibilitySurvivesRelaunchFromEitherEditorMode() async throws {
        try await withModel { model, url in
            for raw in [false, true] {
                if model.showRaw != raw { model.toggleRawEditor() }
                model.columnVisibility = .detailOnly
                let collapsed = AppModel(store: model.store, defaults: model.defaults, initialURL: url)
                XCTAssertTrue(collapsed.sidebarIsCollapsed)
                XCTAssertEqual(collapsed.columnVisibility, .detailOnly)

                model.columnVisibility = .all
                let expanded = AppModel(store: model.store, defaults: model.defaults, initialURL: url)
                XCTAssertFalse(expanded.sidebarIsCollapsed)
                XCTAssertEqual(expanded.columnVisibility, .all)
            }
        }
    }

    func testChangingSectionsAndReloadingKeepsTheSidebarCollapsed() async throws {
        try await withModel { model, url in
            model.toggleSidebar()
            model.toggleRawEditor()
            model.selectSection(.clusters)
            XCTAssertFalse(model.showRaw)
            XCTAssertTrue(model.sidebarIsCollapsed)
            model.toggleRawEditor()
            model.load(url)
            XCTAssertFalse(model.showRaw)
            XCTAssertTrue(model.sidebarIsCollapsed)
            XCTAssertTrue(AppModel(store: model.store, defaults: model.defaults, initialURL: url).sidebarIsCollapsed)
        }
    }

    func testEditorToggleKeepsTheNativeSidebarCollapsedWithoutRecreatingIt() async throws {
        try await withModel { model, _ in
            model.toggleSidebar()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: MainView(model: model))
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(300))
            let split = try XCTUnwrap(Self.splitView(in: host))
            let controller = try XCTUnwrap(split.delegate as? NSSplitViewController)
            let sidebar = try XCTUnwrap(controller.splitViewItems.first)
            XCTAssertTrue(sidebar.isCollapsed)

            for _ in 0..<4 {
                model.toggleRawEditor()
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertTrue(Self.splitView(in: host) === split, "The sidebar's native split view survives mode changes")
                XCTAssertTrue(sidebar.isCollapsed)
                XCTAssertTrue(model.sidebarIsCollapsed)
            }
        }
    }

    @MainActor private static func splitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        return view.subviews.lazy.compactMap { splitView(in: $0) }.first
    }

    func testAnUnreadableFileLeavesTheOpenDraftAlone() async throws {
        try await withModel { model, url in
            model.addEntry()
            let draft = model.draftText
            let binary = url.deletingLastPathComponent().appendingPathComponent("binary")
            try Data([0xFF, 0xFE]).write(to: binary)
            model.load(binary)
            XCTAssertNotNil(model.errorMessage)
            XCTAssertEqual(model.draftText, draft)
            XCTAssertEqual(model.snapshot?.url.lastPathComponent, "config")
        }
    }

    func testMalformedLaunchArgumentsOpenNothing() async throws {
        await MainActor.run {
            let suite = "KubeConfigTests.\(UUID().uuidString)"
            defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            let model = AppModel(defaults: UserDefaults(suiteName: suite)!, arguments: ["app", "--config"])
            XCTAssertNotNil(model.errorMessage)
            XCTAssertNil(model.snapshot)
            XCTAssertFalse(model.hasNoConfiguration)
        }
    }

    func testTypingOutranksAnEarlierStatus() async throws {
        try await withModel { model, _ in
            model.addEntry()
            model.commit()
            XCTAssertEqual(model.draftStatus, "Applied")
            model.editor?.fields["namespace"] = "typing"
            XCTAssertEqual(model.draftStatus, "Edited")
        }
    }

    func testRollbackWaitsForPendingChangesAndCancelKeepsThem() async throws {
        try await withModel { model, _ in
            model.editor?.fields["namespace"] = "applied"
            model.commitForm()
            model.commit()
            model.editor?.fields["namespace"] = "pending"
            model.commitForm()
            let draft = model.draftText
            model.selectSection(.backups)
            model.ask = { _, _, _ in 2 }
            model.rollbackSelected()
            XCTAssertEqual(model.draftText, draft)
            XCTAssertEqual(model.section, .backups)
            model.ask = { _, _, _ in 1 }
            model.rollbackSelected()
            XCTAssertEqual(model.document?.entry(.contexts, named: "dev")?.value("namespace"), "default")
            XCTAssertEqual(model.statusMessage, "Rollback staged")
        }
    }

    func testFileTitleAndSubtitleReflectDraftState() async throws {
        try await withModel { model, url in
            XCTAssertTrue(url.path.hasSuffix(model.filePath.replacingOccurrences(of: "~", with: "")))
            XCTAssertNil(model.draftStatus)
            model.addEntry()
            XCTAssertEqual(model.draftStatus, "Edited")
        }
    }
}

extension AppModelTests {
    private static let numberedContexts = "contexts:\n- {name: item-10, context: {cluster: c}}\n- {name: item-2, context: {cluster: c}}\n"

    func testUndoSelectsTheChangedEntryInListOrder() async throws {
        try await withModel(initial: Self.numberedContexts) { model, _ in
            model.selectEntry("item-2")
            var next = try XCTUnwrap(model.document)
            try next.update(.contexts, originalName: "item-10", name: "item-10", fields: ["namespace": "one"])
            try model.stage(next)
            model.undo()
            XCTAssertEqual(model.selectedName, "item-10", "Only this one changed")

            try next.update(.contexts, originalName: "item-2", name: "item-2", fields: ["namespace": "two"])
            try model.stage(next)
            model.selectEntry("item-10")
            model.undo()
            XCTAssertEqual(model.selectedName, "item-2", "Numbers sort as numbers, so 2 comes before 10")
        }
    }

    func testImportFromAFileResolvesPathsBesideIt() async throws {
        try await withModel { model, url in
            let file = url.deletingLastPathComponent().appendingPathComponent("incoming.yaml")
            try Data("clusters: [{name: new, cluster: {server: 'https://new.invalid', certificate-authority: ca.pem}}]\n".utf8).write(to: file)
            try model.prepareImport(file: file)
            XCTAssertTrue(model.showImport)
            let path = try XCTUnwrap(model.importPlan?.incoming.entry(.clusters, named: "new")?.value("certificate-authority"))
            XCTAssertEqual(path, file.deletingLastPathComponent().appendingPathComponent("ca.pem").standardizedFileURL.path)
        }
    }

    func testImportFileMustExistAndBeUTF8() async throws {
        try await withModel { model, url in
            let folder = url.deletingLastPathComponent()
            let binary = folder.appendingPathComponent("binary")
            try Data([0xff, 0xfe, 0x00]).write(to: binary)
            for file in [binary, folder.appendingPathComponent("absent")] {
                XCTAssertThrowsError(try model.prepareImport(file: file)) {
                    XCTAssertEqual($0 as? ConfigError, .invalid("Choose a UTF-8 kubeconfig file of at most 16 MB."))
                }
            }
            XCTAssertFalse(model.showImport)
        }
    }

    func testImportRefusesWhatItShouldNotReadInFull() async throws {
        try await withModel { model, url in
            let folder = url.deletingLastPathComponent()
            let pipe = folder.appendingPathComponent("pipe")
            XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
            let oversized = folder.appendingPathComponent("oversized")
            FileManager.default.createFile(atPath: oversized.path, contents: nil)
            let handle = try FileHandle(forWritingTo: oversized)
            try handle.truncate(atOffset: UInt64(KubeDocument.maximumByteCount) + 1)
            try handle.close()
            for file in [pipe, oversized, folder] {
                XCTAssertThrowsError(try model.prepareImport(file: file), file.lastPathComponent)
            }
            XCTAssertFalse(model.showImport)
        }
    }

    func testOpeningAFileWaitsForPendingChangesAndAPick() async throws {
        try await withModel { model, url in
            let other = url.deletingLastPathComponent().appendingPathComponent("other")
            try Data(Self.fixture.replacingOccurrences(of: "name: other", with: "name: elsewhere").utf8).write(to: other)
            var titles: [String] = []
            model.chooseFile = { titles.append($0); return nil }
            model.openConfiguration()
            XCTAssertEqual(titles, ["Open Configuration"])
            XCTAssertEqual(model.snapshot?.url, url.standardizedFileURL, "Cancelling keeps the open file")

            model.editor?.fields["namespace"] = "pending"
            model.ask = { _, _, _ in 2 }
            model.openConfiguration()
            XCTAssertEqual(titles.count, 1, "Cancelling the question never reaches the picker")

            model.ask = { _, _, _ in 1 }
            model.chooseFile = { _ in other }
            model.openConfiguration()
            XCTAssertEqual(model.snapshot?.url, other.standardizedFileURL)
            XCTAssertNotNil(model.document?.entry(.contexts, named: "elsewhere"))
        }
    }

    func testChoosingAnImportFileOpensItsReview() async throws {
        try await withModel { model, url in
            model.chooseFile = { _ in nil }
            try model.chooseImportFile()
            XCTAssertFalse(model.showImport)
            model.chooseFile = { _ in url }
            try model.chooseImportFile()
            XCTAssertTrue(model.showImport)
            XCTAssertNotNil(model.importPlan)
        }
    }

    func testRollbackKeepsItsBackupWhenApplyingFirstPrunesIt() async throws {
        try await withModel { model, _ in
            model.defaults.set(2, forKey: BackupRetention.key)
            for namespace in ["one", "two"] {
                model.editor?.fields["namespace"] = namespace
                model.requestReview()
                model.commit()
            }
            XCTAssertEqual(model.records.count, 2)
            model.editor?.fields["namespace"] = "three"
            try model.flushEditor()
            model.selectSection(.backups)
            model.selectedBackupID = model.records.last?.id
            model.ask = { _, _, _ in 0 }
            model.rollbackSelected()
            XCTAssertTrue(model.showReview)
            model.commit()
            XCTAssertNil(model.errorMessage)
            XCTAssertEqual(model.draftText, Self.fixture)
            XCTAssertEqual(model.statusMessage, "Rollback staged")
        }
    }

    func testAQueuedSelectionSurvivesACommitThatKeepsTheSelection() async throws {
        try await withModel { model, _ in
            model.editor?.fields["namespace"] = "changed"
            model.queueContextSelection(["other"])
            model.commitForm()
            await Task.yield()
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(model.selectedContextNames, ["other"])
        }
    }

    func testEditorColorsReachThePixelsAndFollowTheText() async throws {
        try await withModel { model, _ in
            model.toggleRawEditor()
            let editor = EditorHarness(model: model)
            editor.textView.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
            @MainActor func hasBlue() throws -> Bool {
                let view = editor.textView
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let rep = try XCTUnwrap(bitmap.converting(to: .sRGB, renderingIntent: .default))
                for x in stride(from: 0, to: rep.pixelsWide, by: 1) {
                    for y in stride(from: 0, to: rep.pixelsHigh, by: 1) {
                        if let color = rep.colorAt(x: x, y: y), color.blueComponent > color.redComponent + 0.35 { return true }
                    }
                }
                return false
            }
            XCTAssertTrue(try hasBlue(), "Keys are blue")
            editor.textView.appearance = NSAppearance(named: .darkAqua)
            XCTAssertTrue(try hasBlue(), "Keys are blue in dark mode too")
            editor.textView.appearance = NSAppearance(named: .aqua)
            model.editRaw("just words\n")
            editor.coordinator.sync(text: model.draftText, errorLine: nil)
            XCTAssertFalse(try hasBlue(), "Replaced text keeps no old color")
            editor.type("key: value\n")
            XCTAssertTrue(try hasBlue(), "Typing colors again")
            XCTAssertEqual(editor.textView.font, YAMLEditor.Coordinator.font)
        }
    }

    func testBackupPreviewShowsContentsEvenWhenTheyAreNotUTF8() async throws {
        try await withModel { model, _ in
            let snapshot = try XCTUnwrap(model.snapshot)
            let text = try XCTUnwrap(model.store.backups.savePrevious(Data("key: value\n".utf8), for: snapshot.resolvedURL, retention: 10))
            let binary = try XCTUnwrap(model.store.backups.savePrevious(Data([0x61, 0xff]), for: snapshot.resolvedURL, retention: 10))
            XCTAssertEqual(try model.backupPreview(text.summary), "key: value\n")
            XCTAssertEqual(try model.backupPreview(binary.summary), "a\u{FFFD}")
        }
    }

    func testAnUnreadableFileCountsAsChangedOutside() async throws {
        try await withModel { model, url in
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
            model.checkForExternalChange()
            XCTAssertTrue(model.fileChangedOnDisk)
        }
    }

    func testActionsReportAFormThatCannotBeCommitted() async throws {
        try await withModel { model, _ in
            let actions: [(String, @MainActor () -> Void)] = [
                ("selectEntry", { model.selectEntry("other") }),
                ("selectSection", { model.selectSection(.clusters) }),
                ("addEntry", model.addEntry),
                ("duplicateEntry", { model.duplicateEntry("dev") }),
                ("makeActive", { model.makeActive() }),
                ("clearActive", model.clearActive),
                ("deleteEntry", { model.deleteEntry() }),
                ("toggleRawEditor", model.toggleRawEditor),
                ("exportDraft", model.exportDraft)
            ]
            for (name, action) in actions {
                model.editor?.name = ""
                action()
                XCTAssertNotNil(model.errorMessage, name)
                XCTAssertEqual(model.editor?.name, "", name)
                XCTAssertEqual(model.document?.entries(.contexts).count, 2, name)
                model.errorMessage = nil
            }
        }
    }

    func testAFormEditThatCannotCommitLeavesTheCountsOnTheDraft() async throws {
        try await withModel { model, _ in
            model.editor?.fields["namespace"] = "changed"
            model.editor?.name = ""
            XCTAssertEqual(model.pendingChanges?.count, 0)
            XCTAssertEqual(model.validationIssues, [])
        }
    }

    func testFormEditsAreCountedBeforeThereIsAFile() async throws {
        try await withModel(initial: nil) { model, _ in
            model.createConfiguration()
            model.addEntry()
            let before = model.pendingChanges?.count(.contexts)
            model.editor?.name = "named"
            XCTAssertEqual(model.pendingChanges?.count(.contexts), before)
            XCTAssertTrue(model.pendingChanges?.contains(.contexts, name: "named") == true)
        }
    }

    func testANewContextLeavesItsReferencesEmptyWhenThereIsNothingToPick() async throws {
        try await withModel(initial: "apiVersion: v1\nkind: Config\nclusters: []\nusers: []\ncontexts: []\n") { model, _ in
            model.addEntry()
            XCTAssertEqual(model.editor?.name, "new-context")
            XCTAssertEqual(model.editor?.fields["cluster"], "")
            XCTAssertEqual(model.validationIssues, ["Context ‘new-context’ refers to a missing cluster."])
        }
    }

    func testABlankConfigurationHasNothingToReportOrExport() async throws {
        try await withModel(initial: "\n") { model, _ in
            XCTAssertTrue(model.hasNoConfiguration)
            XCTAssertEqual(model.validationIssues, [])
            XCTAssertNil(model.pendingChanges)
            XCTAssertFalse(model.canApply)
            XCTAssertEqual(model.contextExportTitle, "Export Selected Contexts")
        }
    }

    func testUndoAndRedoWithNoHistoryChangeNothing() async throws {
        try await withModel { model, _ in
            model.undo()
            model.redo()
            XCTAssertEqual(model.draftText, Self.fixture)
            XCTAssertFalse(model.canUndo)
            XCTAssertFalse(model.canRedo)
        }
    }

    func testRemovingAWholeMultipleSelectionInYAMLFallsBackToTheFirstEntry() async throws {
        try await withModel { model, _ in
            model.selectContexts(["dev", "other"])
            model.toggleRawEditor()
            model.editRaw(Self.fixture.replacingOccurrences(of: "name: dev\n  context", with: "name: kept\n  context")
                .replacingOccurrences(of: "name: other", with: "name: another"))
            model.toggleRawEditor()
            XCTAssertEqual(model.selectedContextNames, ["another"])
            XCTAssertEqual(model.editor?.originalName, "another")
        }
    }

    func testSheetsRenderTheirContent() async throws {
        try await withModel { model, url in
            model.editor?.fields["namespace"] = "changed"
            try model.flushEditor()
            try model.prepareImport(file: url)
            let plan = try XCTUnwrap(model.importPlan)
            model.closeImport()
            try model.store.backups.savePrevious(Data("key: value\n".utf8), for: XCTUnwrap(model.snapshot).resolvedURL, retention: 10)
            model.refreshBackups()
            model.selectContexts(["dev", "other"])
            model.requestContextExport()
            let export = try XCTUnwrap(model.contextExportPlan)

            @MainActor func render(_ view: some View) async throws {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let host = NSHostingView(rootView: view)
                window.contentView = host
                window.orderFront(nil)
                defer { window.orderOut(nil) }
                try await Task.sleep(for: .milliseconds(50))
                XCTAssertGreaterThan(host.fittingSize.height, 0)
            }
            try await render(ReviewSheet(model: model))
            try await render(ImportSourceSheet(model: model))
            try await render(ImportSheet(model: model, initialPlan: plan))
            try await render(ContextExportSheet(model: model, plan: export))
            try await render(ContextSelectionSummary(model: model))
            try await render(PreferencesView())
            model.closeContextExport()
            model.selectSection(.backups)
            try await render(BackupDetailView(model: model))
            model.selectSection(.clusters)
            try await render(EntryDetailView(model: model))
            model.selectSection(.contexts)
            try await render(EntryDetailView(model: model))
        }
    }

    func testUnreadableBackupFolderEmptiesTheListAndReportsIt() async throws {
        try await withModel { model, url in
            model.addEntry()
            model.commit()
            XCTAssertEqual(model.records.count, 1)
            let folder = model.store.backups.location(for: url)
            try FileManager.default.removeItem(at: folder)
            try Data().write(to: folder)
            model.refreshBackups()
            XCTAssertEqual(model.records, [])
            XCTAssertNil(model.selectedBackupID)
            XCTAssertNotNil(model.errorMessage)
        }
    }

    func testRevealingBackupsBeforeThereAreAnySaysSo() async throws {
        try await withModel { model, _ in
            model.revealBackups()
            XCTAssertEqual(model.draftStatus, "No backups yet")
        }
    }

    func testClearingAReferenceAndChoosingItAgainLeavesNothingToApply() async throws {
        try await withModel { model, _ in
            model.editor?.fields["cluster"] = ""
            model.commitForm()
            XCTAssertTrue(model.hasPendingChanges)
            model.editor?.fields["cluster"] = "dev"
            model.commitForm()
            XCTAssertFalse(model.hasPendingChanges)
            XCTAssertEqual(model.reviewCount, 0)
            XCTAssertEqual(model.pendingChanges?.count, 0)
        }
    }

    func testAFieldSetBackDoesNotCountAlongsideAnotherPendingChange() async throws {
        try await withModel { model, _ in
            model.editor?.fields["cluster"] = ""
            model.commitForm()
            model.editor?.fields["cluster"] = "dev"
            model.commitForm()
            model.selectEntry("other")
            model.editor?.fields["namespace"] = "changed"
            model.commitForm()
            XCTAssertEqual(model.reviewCount, 1)
            XCTAssertEqual(model.pendingChanges?.count, 1)
        }
    }

    func testPreviewColoringKeepsTheTextAndStopsAtTheLimit() {
        let text = "# é😀\nkey: 'value' # note\nlist: [1, true]\n\n"
        let colored = YAMLStyle.attributed(text)
        XCTAssertEqual(String(colored.characters), text)
        XCTAssertGreaterThan(colored.runs.count, 1)

        let large = String(repeating: "k: v\n", count: YAMLStyle.highlightLimit / 5 + 1)
        let plain = YAMLStyle.attributed(large)
        XCTAssertEqual(plain.runs.count, 1)
        XCTAssertEqual(plain.characters.count, large.count)
    }
}

extension AppModelTests {
    @MainActor private func withK9s(k9sInstalled: Bool = true, immediate: Bool? = false, _ body: @MainActor (AppModel, URL, FakeK9sTerminals) async throws -> Void) async throws {
        try await withModel(immediate: immediate) { model, url in
            let terminals = FakeK9sTerminals()
            model.makeK9sTerminal = { terminals.make() }
            model.findLoginPath = { "/fake/bin" }
            model.isK9sExecutable = { k9sInstalled && $0 == "/fake/bin/k9s" }
            try await body(model, url, terminals)
        }
    }

    @MainActor private func open(_ model: AppModel, _ name: String? = nil) async {
        model.openK9s(name)
        await model.k9sLaunchTask?.value
    }

    func testK9sOpensTheSelectedContextOfTheOpenFile() async throws {
        try await withK9s { model, url, terminals in
            model.selectEntry("other")
            await self.open(model)
            XCTAssertEqual(terminals.all.first?.launch?.executable, "/fake/bin/k9s")
            XCTAssertEqual(terminals.all.first?.launch?.arguments, ["--kubeconfig", url.path, "--context", "other", "--splashless", "--logoless"])
            XCTAssertTrue(model.k9sIsVisible)
            XCTAssertEqual(model.document?.currentContext, "dev")
            XCTAssertFalse(model.hasPendingChanges)
        }
    }

    func testK9sOpensAContextOtherThanTheSelectedOne() async throws {
        try await withK9s { model, _, terminals in
            await self.open(model, "other")
            XCTAssertEqual(model.selectedName, "other")
            XCTAssertEqual(terminals.all.first?.launch?.arguments.dropFirst(3).first, "other")
        }
    }

    func testK9sKeepsRunningWhileOtherEntriesAreOnScreen() async throws {
        try await withK9s { model, _, terminals in
            await self.open(model, "dev")
            model.selectEntry("other")
            XCTAssertFalse(model.k9sIsVisible)
            XCTAssertNotNil(model.editor)
            model.selectSection(.clusters)
            XCTAssertFalse(model.k9sIsVisible)
            model.selectSection(.contexts)
            model.selectEntry("dev")
            XCTAssertTrue(model.k9sIsVisible)
            XCTAssertEqual(terminals.all.count, 1)
            XCTAssertFalse(terminals.all[0].stopped)

            await self.open(model, "dev")
            XCTAssertEqual(terminals.all.count, 1)
        }
    }

    func testOpeningAnotherContextReplacesTheSession() async throws {
        try await withK9s { model, _, terminals in
            await self.open(model, "dev")
            let first = terminals.all[0], exit = first.onExit
            await self.open(model, "other")
            XCTAssertTrue(first.stopped)
            XCTAssertEqual(model.k9sSession?.contextName, "other")
            exit?(1)
            XCTAssertEqual(model.k9sSession?.phase, .running)
        }
    }

    func testK9sIsBlockedByPendingChangesToItsConnection() async throws {
        try await withK9s { model, _, terminals in
            model.selectEntry("dev")
            model.editor?.fields["namespace"] = "edited"
            XCTAssertNotNil(model.k9sBlockReason("dev"), "A form still being typed in counts")
            XCTAssertNil(model.k9sBlockReason("other"))
            await self.open(model, "dev")
            XCTAssertTrue(terminals.all.isEmpty)
            model.commitForm()
            XCTAssertNotNil(model.k9sBlockReason("dev"))

            model.discardDraft()
            model.selectSection(.clusters)
            model.selectEntry("dev")
            model.editor?.fields["server"] = "https://edited.invalid"
            model.commitForm()
            model.selectSection(.contexts)
            XCTAssertNotNil(model.k9sBlockReason("dev"), "Both contexts use the changed cluster")
            XCTAssertNotNil(model.k9sBlockReason("other"))
        }
    }

    func testK9sIsBlockedForAContextThatIsOnlyInTheDraft() async throws {
        try await withK9s { model, _, _ in
            model.addEntry()
            XCTAssertEqual(model.k9sBlockReason(model.selectedName), "Apply changes to open in k9s")
            XCTAssertNil(model.k9sBlockReason("dev"), "An unrelated new context doesn't block")
        }
    }

    func testK9sIsBlockedForSeveralContexts() async throws {
        try await withK9s { model, _, _ in
            model.selectContexts(["dev", "other"])
            XCTAssertNotNil(model.k9sBlockReason("dev"))
        }
    }

    func testCleanK9sExitReturnsToTheForm() async throws {
        try await withK9s { model, _, terminals in
            await self.open(model, "dev")
            model.k9sIsExpanded = true
            terminals.all[0].onExit?(0)
            XCTAssertNil(model.k9sSession)
            XCTAssertFalse(model.k9sIsExpanded)
            XCTAssertNotNil(model.editor)
        }
    }

    func testFailedK9sKeepsItsOutputOnScreen() async throws {
        try await withK9s { model, _, terminals in
            await self.open(model, "dev")
            terminals.all[0].onExit?(1)
            XCTAssertEqual(model.k9sSession?.phase, .exited(1))
            XCTAssertTrue(model.k9sIsVisible)
            model.restartK9s()
            await model.k9sLaunchTask?.value
            XCTAssertEqual(terminals.all.count, 2)
            XCTAssertEqual(model.k9sSession?.phase, .running)
            XCTAssertNotNil(terminals.all[1].launch)
        }
    }

    func testMissingK9sCanBeRetriedAfterInstalling() async throws {
        try await withK9s(k9sInstalled: false) { model, _, terminals in
            await self.open(model, "dev")
            XCTAssertEqual(model.k9sSession?.phase, .missing)
            XCTAssertNil(terminals.all[0].launch)
            model.isK9sExecutable = { $0 == "/fake/bin/k9s" }
            model.restartK9s()
            await model.k9sLaunchTask?.value
            XCTAssertEqual(model.k9sSession?.phase, .running)
        }
    }

    func testK9sNoticesItsContextChangingOnDisk() async throws {
        try await withK9s { model, url, _ in
            await self.open(model, "dev")
            try Data(Self.fixture.replacingOccurrences(of: "other", with: "another").utf8).write(to: url)
            model.checkForExternalChange()
            XCTAssertEqual(model.k9sSession?.freshness, .unchanged, "Only the context, cluster and user count")

            try Data(Self.fixture.replacingOccurrences(of: "https://dev.invalid", with: "https://new.invalid").utf8).write(to: url)
            model.checkForExternalChange()
            XCTAssertEqual(model.k9sSession?.freshness, .changed)

            model.restartK9s()
            await model.k9sLaunchTask?.value
            XCTAssertEqual(model.k9sSession?.freshness, .unchanged)

            try Data(Self.fixture.replacingOccurrences(of: "name: dev\n  context", with: "name: renamed\n  context").utf8).write(to: url)
            model.checkForExternalChange()
            XCTAssertEqual(model.k9sSession?.freshness, .removed)
        }
    }

    func testApplyingAChangeMarksK9sOutOfDate() async throws {
        try await withK9s { model, _, _ in
            await self.open(model, "dev")
            model.selectEntry("other")
            model.selectSection(.clusters)
            model.selectEntry("dev")
            model.editor?.fields["server"] = "https://new.invalid"
            model.commitForm()
            model.commit()
            XCTAssertEqual(model.k9sSession?.freshness, .changed)
        }
    }

    func testOpeningAnotherFileEndsK9sButReloadingDoesNot() async throws {
        try await withK9s { model, url, terminals in
            await self.open(model, "dev")
            model.load(url)
            XCTAssertNotNil(model.k9sSession)
            XCTAssertFalse(terminals.all[0].stopped)

            let otherFile = url.deletingLastPathComponent().appendingPathComponent("second")
            try Data(Self.fixture.utf8).write(to: otherFile)
            model.load(otherFile)
            XCTAssertNil(model.k9sSession)
            XCTAssertTrue(terminals.all[0].stopped)
        }
    }

    func testExpandingK9sLeavesTheSidebarPreferenceAlone() async throws {
        try await withK9s { model, _, _ in
            await self.open(model, "dev")
            model.k9sIsExpanded = true
            XCTAssertEqual(model.displayedColumnVisibility.wrappedValue, .detailOnly)
            XCTAssertEqual(model.columnVisibility, .all)
            XCTAssertFalse(model.sidebarIsCollapsed)

            model.selectEntry("other")
            XCTAssertFalse(model.k9sFillsWindow)
            XCTAssertEqual(model.displayedColumnVisibility.wrappedValue, .all)
            model.selectEntry("dev")
            XCTAssertTrue(model.k9sFillsWindow)
            model.closeK9s()
            XCTAssertEqual(model.displayedColumnVisibility.wrappedValue, .all)
        }
    }

    func testUndoStaysOffWhileK9sIsOnScreen() async throws {
        try await withK9s { model, _, _ in
            model.selectEntry("other")
            model.editor?.fields["namespace"] = "edited"
            model.commitForm()
            XCTAssertTrue(model.canUndo)
            await self.open(model, "dev")
            XCTAssertFalse(model.canUndo)
            model.selectEntry("other")
            XCTAssertTrue(model.canUndo)
        }
    }

    func testClosingDuringLaunchNeverStartsK9s() async throws {
        try await withK9s { model, _, terminals in
            let gate = LaunchGate()
            model.findLoginPath = { await gate.wait(); return "/fake/bin" }
            model.openK9s("dev")
            let launch = model.k9sLaunchTask
            model.closeK9s()
            gate.open()
            await launch?.value
            XCTAssertNil(terminals.all[0].launch)
            XCTAssertNil(model.k9sSession)
        }
    }

    func testReplacingDuringLaunchStartsOnlyTheNewContext() async throws {
        try await withK9s { model, _, terminals in
            let gate = LaunchGate()
            model.findLoginPath = { await gate.wait(); return "/fake/bin" }
            model.openK9s("dev")
            let first = model.k9sLaunchTask
            model.openK9s("other")
            let second = model.k9sLaunchTask
            gate.open()
            await first?.value
            await second?.value
            XCTAssertNil(terminals.all[0].launch)
            XCTAssertEqual(terminals.all[1].launch?.arguments.dropFirst(3).first, "other")
        }
    }

    func testRestartDuringLaunchStartsOnce() async throws {
        try await withK9s { model, _, terminals in
            let gate = LaunchGate()
            model.findLoginPath = { await gate.wait(); return "/fake/bin" }
            model.openK9s("dev")
            let first = model.k9sLaunchTask
            model.restartK9s()
            let second = model.k9sLaunchTask
            gate.open()
            await first?.value
            await second?.value
            XCTAssertNil(terminals.all[0].launch)
            XCTAssertNotNil(terminals.all[1].launch)
        }
    }

    func testExitFromARestartedSessionIsIgnored() async throws {
        try await withK9s { model, _, terminals in
            await self.open(model, "dev")
            let exit = terminals.all[0].onExit
            model.restartK9s()
            await model.k9sLaunchTask?.value
            exit?(1)
            XCTAssertEqual(model.k9sSession?.phase, .running)
        }
    }

    func testSignalledExitKeepsTheOutput() async throws {
        try await withK9s { model, _, terminals in
            await self.open(model, "dev")
            terminals.all[0].onExit?(nil)
            XCTAssertEqual(model.k9sSession?.phase, .exited(nil))
        }
    }

    func testLoginPathIsKeptUntilTryAgain() async throws {
        try await withK9s(k9sInstalled: false) { model, _, _ in
            var lookups = 0
            model.findLoginPath = { await MainActor.run { lookups += 1 }; return "/fake/bin" }
            await self.open(model, "dev")
            await self.open(model, "other")
            XCTAssertEqual(lookups, 1)
            model.restartK9s()
            await model.k9sLaunchTask?.value
            XCTAssertEqual(lookups, 2, "Try Again might follow a change to the shell's PATH")
        }
    }

    func testK9sStaysVisibleAfterReloading() async throws {
        try await withK9s { model, url, terminals in
            await self.open(model, "other")
            model.k9sIsExpanded = true
            model.load(url)
            XCTAssertTrue(model.k9sIsVisible)
            XCTAssertTrue(model.k9sFillsWindow)
            XCTAssertFalse(terminals.all[0].stopped)
        }
    }

    func testReloadWithoutItsContextEndsK9s() async throws {
        try await withK9s { model, url, terminals in
            await self.open(model, "other")
            try Data(Self.fixture.replacingOccurrences(of: "name: other", with: "name: renamed").utf8).write(to: url)
            model.load(url)
            XCTAssertNil(model.k9sSession)
            XCTAssertTrue(terminals.all[0].stopped)
        }
    }

    func testApplyingDeletionOfK9sContextEndsTheSession() async throws {
        try await withK9s { model, _, terminals in
            await self.open(model, "other")
            model.deleteEntry("other")
            model.commit()
            XCTAssertNil(model.k9sSession)
            XCTAssertTrue(terminals.all[0].stopped)
        }
    }

    func testInvalidFileIsNotReportedAsRemoved() async throws {
        try await withK9s { model, url, _ in
            await self.open(model, "dev")
            try Data("not: [valid".utf8).write(to: url)
            model.checkForExternalChange()
            XCTAssertEqual(model.k9sSession?.freshness, .changed)
            XCTAssertNil(model.k9sRestartBlockReason)
        }
    }

    func testDeletedFileIsReportedAsRemoved() async throws {
        try await withK9s { model, url, _ in
            await self.open(model, "dev")
            try FileManager.default.removeItem(at: url)
            model.checkForExternalChange()
            XCTAssertEqual(model.k9sSession?.freshness, .removed)
            XCTAssertNotNil(model.k9sRestartBlockReason)
        }
    }

    func testBadNameBlocksK9s() async throws {
        try await withK9s { model, _, terminals in
            model.selectEntry("dev")
            model.editor?.name = "other"
            XCTAssertNotNil(model.k9sBlockReason("dev"))
            await self.open(model, "dev")
            XCTAssertTrue(terminals.all.isEmpty)
        }
    }

    func testRestartIsBlockedByPendingChanges() async throws {
        try await withK9s { model, _, terminals in
            await self.open(model, "dev")
            model.selectSection(.clusters)
            model.selectEntry("dev")
            model.editor?.fields["server"] = "https://edited.invalid"
            model.commitForm()
            model.selectSection(.contexts)
            model.selectEntry("dev")
            XCTAssertNotNil(model.k9sRestartBlockReason)
            model.restartK9s()
            XCTAssertEqual(terminals.all.count, 1)
            XCTAssertFalse(terminals.all[0].stopped)
        }
    }

    func testFailedFlushStopsOpeningK9s() async throws {
        try await withK9s { model, _, terminals in
            model.selectEntry("dev")
            model.editor?.name = "other"
            await self.open(model, "other")
            XCTAssertTrue(terminals.all.isEmpty)
            XCTAssertEqual(model.selectedName, "dev")
            XCTAssertNotNil(model.errorMessage)
        }
    }

    func testFailedLoadKeepsK9s() async throws {
        try await withK9s { model, url, terminals in
            await self.open(model, "dev")
            let broken = url.deletingLastPathComponent().appendingPathComponent("broken")
            try Data([0xFF, 0xFE, 0xFD]).write(to: broken)
            model.load(broken)
            XCTAssertNotNil(model.k9sSession)
            XCTAssertFalse(terminals.all[0].stopped)
        }
    }

    func testSameFileThroughSymlinkKeepsK9s() async throws {
        try await withK9s { model, url, terminals in
            await self.open(model, "dev")
            let link = url.deletingLastPathComponent().appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            model.load(link)
            XCTAssertNotNil(model.k9sSession)
            XCTAssertFalse(terminals.all[0].stopped)
        }
    }

    func testSwitchingContextDoesNotMarkK9sOutOfDate() async throws {
        try await withK9s(immediate: true) { model, url, _ in
            await self.open(model, "other")
            model.makeActive("other")
            XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("current-context: other"))
            model.checkForExternalChange()
            XCTAssertEqual(model.k9sSession?.freshness, .unchanged)
        }
    }

    func testBaselineIsTheFileAsK9sReadIt() async throws {
        try await withK9s { model, url, _ in
            try Data(Self.fixture.replacingOccurrences(of: "https://dev.invalid", with: "https://new.invalid").utf8).write(to: url)
            await self.open(model, "dev")
            model.checkForExternalChange()
            XCTAssertEqual(model.k9sSession?.freshness, .unchanged)
        }
    }

    func testHeaderShowsTheClusterK9sConnectedTo() async throws {
        try await withK9s { model, _, _ in
            await self.open(model, "dev")
            model.selectEntry("other")
            model.selectEntry("dev")
            XCTAssertEqual(model.k9sSession?.clusterName, "dev")
        }
    }

    func testReplacingCollapsesAndRestartKeepsExpand() async throws {
        try await withK9s { model, _, _ in
            await self.open(model, "dev")
            model.k9sIsExpanded = true
            model.restartK9s()
            await model.k9sLaunchTask?.value
            XCTAssertTrue(model.k9sIsExpanded)
            await self.open(model, "other")
            XCTAssertFalse(model.k9sIsExpanded)
        }
    }

    func testDisplayedVisibilityWritesOnlyWhenNotExpanded() async throws {
        try await withK9s { model, _, _ in
            await self.open(model, "dev")
            model.displayedColumnVisibility.wrappedValue = .detailOnly
            XCTAssertEqual(model.columnVisibility, .detailOnly)
            model.columnVisibility = .all
            model.k9sIsExpanded = true
            model.displayedColumnVisibility.wrappedValue = .automatic
            XCTAssertEqual(model.columnVisibility, .all)
        }
    }

    func testRedoStaysOffWhileK9sIsOnScreen() async throws {
        try await withK9s { model, _, _ in
            model.selectEntry("other")
            model.editor?.fields["namespace"] = "edited"
            model.commitForm()
            model.undo()
            XCTAssertTrue(model.canRedoCommand)
            await self.open(model, "dev")
            XCTAssertFalse(model.canRedoCommand)
        }
    }

    func testYAMLModeHidesK9sAndKeepsIt() async throws {
        try await withK9s { model, _, terminals in
            await self.open(model, "dev")
            model.toggleRawEditor()
            XCTAssertFalse(model.k9sIsVisible)
            XCTAssertFalse(terminals.all[0].stopped)
            XCTAssertNotNil(model.k9sBlockReason("dev"))
        }
    }

    func testOnlyAskingForK9sTakesFocus() async throws {
        try await withK9s { model, _, _ in
            await self.open(model, "dev")
            XCTAssertTrue(model.takeK9sFocusRequest())
            XCTAssertFalse(model.takeK9sFocusRequest())
            model.selectEntry("other")
            model.selectEntry("dev")
            XCTAssertFalse(model.takeK9sFocusRequest(), "Selecting the context in the list leaves focus there")
            model.selectEntry("other")
            await self.open(model, "dev")
            XCTAssertTrue(model.takeK9sFocusRequest())
        }
    }
}

/// Holds a launch at its `PATH` lookup, so a test can act while it waits.
@MainActor private final class LaunchGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

@MainActor private final class FakeK9sTerminal: K9sTerminal {
    let view = NSView()
    var onExit: ((Int32?) -> Void)?
    var launch: K9sLaunch?
    var stopped = false
    func start(_ launch: K9sLaunch) { self.launch = launch }
    func stop() { stopped = true }
}

@MainActor private final class FakeK9sTerminals {
    var all: [FakeK9sTerminal] = []
    func make() -> K9sTerminal {
        let terminal = FakeK9sTerminal()
        all.append(terminal)
        return terminal
    }
}

private struct UnwritableBackups: FileAccess {
    func read(_ url: URL) throws -> Data? { try LocalFileAccess().read(url) }
    func writeAtomically(_ data: Data, to url: URL) throws { throw CocoaError(.fileWriteNoPermission) }
}
