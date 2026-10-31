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

    fileprivate func withModel(initial: String? = fixture, backupFiles: any FileAccess = LocalFileAccess(), immediate: Bool? = false, _ body: @MainActor (AppModel, URL) throws -> Void) async throws {
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
            if let immediate { defaults.set(immediate, forKey: ContextSwitching.immediateKey) }
            let model = AppModel(store: store, defaults: defaults, initialURL: url)
            try body(model, url)
        }
    }

    @MainActor private func reviewed(_ model: AppModel) throws -> Int {
        ConfigurationDiff.changes(in: try ConfigurationDiff.lines(before: model.snapshot?.text ?? "", after: XCTUnwrap(model.document))).count
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
            XCTAssertEqual(model.draftStatus, "Switched to ‘other’")
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

    func testImmediateClearEmptiesTheActiveContextInTheFile() async throws {
        try await withModel(immediate: true) { model, url in
            model.clearActive()
            XCTAssertEqual(try KubeDocument(yaml: String(contentsOf: url, encoding: .utf8)).currentContext, "")
            XCTAssertEqual(model.document?.currentContext, "")
            XCTAssertFalse(model.hasPendingChanges)
            XCTAssertEqual(model.draftStatus, "Active context cleared")
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

    func testReadOnlyColoringKeepsTheTextIntact() {
        let text = "# note\nname: 'x' # 👋\nretries: 3\nplain text\n"
        XCTAssertEqual(String(YAMLStyle.attributed(text).characters), text)
        let long = String(repeating: "a: 1\n", count: YAMLStyle.highlightLimit / 5 + 1)
        let plain = YAMLStyle.attributed(long)
        XCTAssertEqual(plain.characters.count, long.count)
        XCTAssertEqual(plain.runs.count, 1, "Past the limit the text stays uncolored")
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
            XCTAssertEqual(model.columnVisibility, .doubleColumn)
            model.toggleRawEditor()
            model.find()
            XCTAssertEqual(model.searchFocusRequest, 1)
        }
    }

    func testSidebarCollapseDependsOnTheColumnsInUse() async throws {
        try await withModel { model, _ in
            XCTAssertFalse(model.sidebarIsCollapsed)
            model.toggleSidebar()
            XCTAssertEqual(model.columnVisibility, .doubleColumn)
            XCTAssertTrue(model.sidebarIsCollapsed)
            model.toggleRawEditor()
            XCTAssertEqual(model.columnVisibility, .detailOnly, "YAML mode has no list, so two columns would include the sidebar")
            XCTAssertTrue(model.sidebarIsCollapsed)
            model.toggleRawEditor()
            XCTAssertEqual(model.columnVisibility, .doubleColumn)
            model.toggleSidebar()
            XCTAssertEqual(model.columnVisibility, .all)
            model.toggleRawEditor()
            XCTAssertEqual(model.columnVisibility, .all)
            model.toggleSidebar()
            XCTAssertEqual(model.columnVisibility, .detailOnly)
        }
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
                    XCTAssertEqual($0 as? ConfigError, .invalid("Choose a UTF-8 kubeconfig file."))
                }
            }
            XCTAssertFalse(model.showImport)
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

private struct UnwritableBackups: FileAccess {
    func read(_ url: URL) throws -> Data? { try LocalFileAccess().read(url) }
    func writeAtomically(_ data: Data, to url: URL) throws { throw CocoaError(.fileWriteNoPermission) }
}
