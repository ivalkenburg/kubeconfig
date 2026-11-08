import XCTest
import KubeConfigCore
import SwiftUI
import SwiftTerm
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

    func testRawAmbiguousCredentialsBlockApplyUntilQuoted() async throws {
        try await withModel { model, url in
            for value in ["y", "0X1F", "+.5", ".5e3"] {
                let raw = Self.fixture.replacingOccurrences(of: "users: []", with: "users: [{name: u, user: {token: \(value)}}]")
                model.editRaw(raw)
                XCTAssertNil(model.parseIssue)
                XCTAssertTrue(model.validationIssues.contains { $0.contains("token") }, value)
                XCTAssertFalse(model.canApply, value)
                XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), Self.fixture)
                model.editRaw(raw.replacingOccurrences(of: "token: \(value)", with: "token: '\(value)'"))
                XCTAssertEqual(model.validationIssues, [], value)
                XCTAssertTrue(model.canApply, value)
            }
        }
    }

    func testImportDoesNotActivateItsCurrentContextWhenStagedOrApplied() async throws {
        let incoming = Self.fixture.replacingOccurrences(of: "name: other", with: "name: imported")
            .replacingOccurrences(of: "current-context: dev", with: "current-context: imported")
        for immediate in [true, false] {
            try await withModel(immediate: immediate) { model, url in
                try model.prepareImport(yaml: incoming, directory: nil)
                try model.acceptImport(XCTUnwrap(model.importPlan))
                XCTAssertEqual(model.document?.currentContext, "dev")
                XCTAssertNotNil(model.document?.entry(.contexts, named: "imported"))
                XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), Self.fixture)
                XCTAssertTrue(model.canApply)
                model.commit()
                XCTAssertNil(model.errorMessage)
                let saved = try KubeDocument(yaml: String(contentsOf: url, encoding: .utf8))
                XCTAssertEqual(saved.currentContext, "dev")
                XCTAssertNotNil(saved.entry(.contexts, named: "imported"))
            }
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
            model.selectEntries(["dev", "other"])
            XCTAssertTrue(model.hasMultipleSelection)
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
            XCTAssertNil(model.deleteBlockReason("dev"))
            model.selectEntries(["other"])
            XCTAssertEqual(model.selectedName, "other")
            XCTAssertEqual(model.editor?.originalName, "other")
            XCTAssertFalse(model.hasMultipleSelection)
        }
    }

    func testBulkContextDeletionConfirmsOnceStagesAndRestoresSelectionOnUndo() async throws {
        let yaml = Self.fixture.replacingOccurrences(of: "contexts:\n", with: "contexts:\n- name: remaining\n  context: {cluster: dev}\n")
        try await withModel(initial: yaml, immediate: true) { model, url in
            model.selectEntries(["dev", "other"])
            var confirmations = 0
            model.ask = { title, detail, buttons in
                confirmations += 1
                XCTAssertEqual(title, "Delete 2 contexts?")
                XCTAssertEqual(detail, "Changes take effect after Apply. You can undo this deletion.")
                XCTAssertEqual(buttons, ["Delete", "Cancel"])
                XCTAssertTrue(model.sheetIsOpen)
                XCTAssertEqual(model.draftText, yaml, "Opening confirmation must not change the draft")
                return 0
            }
            model.requestSelectionDeletion()
            XCTAssertEqual(confirmations, 1, "Deleting the active context adds no second warning")
            XCTAssertFalse(model.sheetIsOpen)
            XCTAssertEqual(model.document?.entries(.contexts).map(\.name), ["remaining"])
            XCTAssertNotNil(model.document?.entry(.clusters, named: "dev"), "Related entries are kept")
            XCTAssertEqual(model.document?.currentContext, "")
            XCTAssertEqual(model.selectedEntryNames, ["remaining"])
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), yaml, "Even immediate switching never saves deletion")
            XCTAssertTrue(model.hasPendingChanges)
            model.undo()
            XCTAssertEqual(model.draftText, yaml)
            XCTAssertEqual(model.selectedEntryNames, ["dev", "other"])
            XCTAssertNil(model.editor)
            XCTAssertFalse(model.canUndo, "The entire deletion is one Undo step")
            model.redo()
            XCTAssertEqual(model.document?.entries(.contexts).map(\.name), ["remaining"])
            XCTAssertEqual(model.selectedEntryNames, ["remaining"])
            model.undo()
            XCTAssertEqual(model.selectedEntryNames, ["dev", "other"], "Selection survives repeated Undo/Redo")
        }
    }

    func testBulkDeletionUndoInYAMLRestoresSelectionWhenReturningToForms() async throws {
        let yaml = """
        clusters:
        - {name: a, cluster: {server: 'https://a.invalid'}}
        - {name: b, cluster: {server: 'https://b.invalid'}}
        - {name: c, cluster: {server: 'https://c.invalid'}}
        users:
        - {name: a, user: {}}
        - {name: b, user: {}}
        - {name: c, user: {}}
        contexts:
        - {name: a, context: {cluster: c, user: c}}
        - {name: b, context: {cluster: c, user: c}}
        - {name: c, context: {cluster: c, user: c}}
        current-context: c
        """ + "\n"
        for section in AppSection.configuration {
            try await withModel(initial: yaml) { model, _ in
                model.selectSection(section)
                model.selectEntries(["a", "b"])
                model.ask = { _, _, _ in 0 }
                model.requestSelectionDeletion()
                XCTAssertEqual(model.selectedEntryNames, ["c"])
                model.selectSection(.contexts)
                model.toggleRawEditor()
                model.undo()
                XCTAssertTrue(model.showRaw, "Undo keeps the YAML editor open")
                XCTAssertNil(model.editor)
                XCTAssertEqual(model.draftText, yaml)
                model.toggleRawEditor()
                XCTAssertEqual(model.section, section)
                XCTAssertEqual(model.selectedEntryNames, ["a", "b"])
                XCTAssertNil(model.editor)
                model.redo()
                XCTAssertEqual(model.selectedEntryNames, ["c"])
            }
        }
    }

    func testCancellingBulkDeletionPreservesDraftSelectionAndHistory() async throws {
        try await withModel { model, _ in
            model.editor?.fields["namespace"] = "pending"
            model.selectEntries(["dev", "other"])
            let draft = model.draftText
            model.ask = { _, _, buttons in
                XCTAssertEqual(buttons, ["Delete", "Cancel"])
                XCTAssertFalse(model.canExportContexts)
                XCTAssertFalse(model.canRequestSelectionDeletion)
                return 1
            }
            model.requestSelectionDeletion()
            XCTAssertFalse(model.sheetIsOpen)
            XCTAssertEqual(model.draftText, draft)
            XCTAssertEqual(model.selectedEntryNames, ["dev", "other"])
            model.undo()
            XCTAssertEqual(model.draftText, Self.fixture, "Cancelling adds no history step")
        }
    }

    func testBulkDeletionOfClustersAndUsersStagesOneActionWithoutCleanup() async throws {
        let yaml = """
        clusters:
        - {name: a, cluster: {server: 'https://a.invalid'}}
        - {name: b, cluster: {server: 'https://b.invalid'}}
        - {name: c, cluster: {server: 'https://c.invalid'}}
        users:
        - {name: a, user: {token: example}}
        - {name: b, user: {token: example}}
        - {name: c, user: {token: example}}
        contexts: []
        """ + "\n"
        for section in [AppSection.clusters, .users] {
            try await withModel(initial: yaml) { model, url in
                let kind = try XCTUnwrap(section.kind)
                let otherKind: EntryKind = section == .clusters ? .users : .clusters
                model.selectSection(section)
                model.selectEntries(["a", "b"])
                XCTAssertTrue(model.hasMultipleSelection)
                XCTAssertNil(model.editor)
                XCTAssertFalse(model.canExportContexts)
                model.ask = { title, _, buttons in
                    XCTAssertEqual(title, "Delete 2 \(section.title.lowercased())?")
                    XCTAssertEqual(buttons, ["Delete", "Cancel"])
                    return 0
                }
                model.requestSelectionDeletion()
                XCTAssertEqual(model.document?.entries(kind).map(\.name), ["c"])
                XCTAssertEqual(model.document?.entries(otherKind).count, 3)
                XCTAssertEqual(model.selectedEntryNames, ["c"])
                XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), yaml)
                model.selectSection(.contexts)
                model.undo()
                XCTAssertEqual(model.section, section)
                XCTAssertEqual(model.selectedEntryNames, ["a", "b"])
                XCTAssertEqual(model.draftText, yaml)
                XCTAssertFalse(model.canUndo)
            }
        }
    }

    func testReferencedClustersAndUsersBlockTheWholeBulkDeletion() async throws {
        let yaml = """
        clusters:
        - {name: free, cluster: {server: 'https://free.invalid'}}
        - {name: used, cluster: {server: 'https://used.invalid'}}
        users:
        - {name: free, user: {}}
        - {name: used, user: {}}
        contexts:
        - {name: context-a, context: {cluster: used, user: used}}
        - {name: context-b, context: {cluster: used, user: used}}
        current-context: context-a
        """ + "\n"
        for section in [AppSection.clusters, .users] {
            try await withModel(initial: yaml) { model, _ in
                model.selectSection(section)
                model.selectEntries(["free", "used"])
                var alerts = 0
                model.ask = { title, detail, buttons in
                    alerts += 1
                    XCTAssertEqual(title, "Cannot delete selected items")
                    XCTAssertEqual(buttons, ["OK"])
                    for name in ["used", "context-a", "context-b"] { XCTAssertTrue(detail.contains(name)) }
                    XCTAssertTrue(model.sheetIsOpen)
                    return 0
                }
                model.requestSelectionDeletion()
                XCTAssertEqual(alerts, 1)
                XCTAssertEqual(model.draftText, yaml)
                XCTAssertEqual(model.selectedEntryNames, ["free", "used"])
                XCTAssertFalse(model.sheetIsOpen)
                XCTAssertFalse(model.canUndo)
                XCTAssertNil(model.errorMessage)
            }
        }
    }

    func testBulkContextDeletionPreservesUnselectedActiveContextAndAllRelatedEntries() async throws {
        let yaml = """
        clusters:
        - {name: unused, cluster: {server: 'https://unused.invalid'}}
        users:
        - {name: unused, user: {token: example}}
        contexts:
        - {name: a, context: {cluster: unused, user: unused}}
        - {name: b, context: {cluster: unused, user: unused}}
        - {name: keep, context: {cluster: unused}}
        current-context: keep
        """ + "\n"
        try await withModel(initial: yaml) { model, _ in
            model.selectEntries(["a", "b"])
            model.ask = { _, _, _ in 0 }
            model.requestSelectionDeletion()
            XCTAssertEqual(model.document?.currentContext, "keep")
            XCTAssertNotNil(model.document?.entry(.users, named: "unused"), "Newly orphaned users are kept")
            XCTAssertNotNil(model.document?.entry(.clusters, named: "unused"))
        }
    }

    func testMultiSelectionSearchRenameAndSectionChangesWorkForEveryEntryKind() async throws {
        let yaml = """
        clusters:
        - {name: a, cluster: {server: 'https://a.invalid'}}
        - {name: b, cluster: {server: 'https://b.invalid'}}
        users:
        - {name: a, user: {}}
        - {name: b, user: {}}
        contexts:
        - {name: a, context: {cluster: a}}
        - {name: b, context: {cluster: b}}
        """ + "\n"
        for section in AppSection.configuration {
            try await withModel(initial: yaml) { model, _ in
                model.selectSection(section)
                model.editor?.name = "renamed"
                model.selectEntries(["a", "b"])
                XCTAssertEqual(model.selectedEntryNames, ["renamed", "b"])
                model.search = "renamed"
                XCTAssertEqual(model.selectedEntryNames, ["renamed"])
                XCTAssertEqual(model.editor?.originalName, "renamed")
                model.search = "no-match"
                XCTAssertTrue(model.selectedEntryNames.isEmpty)
                model.search = ""
                XCTAssertTrue(model.selectedEntryNames.isEmpty)
                model.selectEntries(["renamed", "b"])
                model.selectSection(.backups)
                XCTAssertTrue(model.selectedEntryNames.isEmpty)
                model.selectSection(section)
                XCTAssertEqual(model.selectedEntryNames, ["b"], "Returning selects only the first visible entry")
            }
        }
    }

    func testQueuedSelectionCannotChangeTheItemsInADeletionConfirmation() async throws {
        try await withModel { model, _ in
            model.selectEntries(["dev", "other"])
            model.queueEntrySelection(["other"])
            var alerts = 0
            model.ask = { _, _, _ in
                alerts += 1
                XCTAssertEqual(model.selectedEntryNames, ["dev", "other"])
                model.queueEntrySelection(["other"])
                model.requestSelectionDeletion()
                return 1
            }
            model.requestSelectionDeletion()
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(alerts, 1, "A confirmation cannot open another confirmation")
            XCTAssertEqual(model.selectedEntryNames, ["dev", "other"])
            XCTAssertFalse(model.sheetIsOpen)
        }
    }

    func testConfirmationDoesNotApplyBulkDeletionToAnotherFile() async throws {
        try await withModel { model, url in
            let other = url.deletingLastPathComponent().appendingPathComponent("other-config")
            try Data(Self.fixture.utf8).write(to: other)
            model.selectEntries(["dev", "other"])
            model.ask = { _, _, _ in
                model.load(other)
                return 0
            }
            model.requestSelectionDeletion()
            XCTAssertEqual(model.snapshot?.url, other)
            XCTAssertEqual(model.draftText, Self.fixture)
            XCTAssertFalse(model.hasPendingChanges)
            XCTAssertFalse(model.canUndo)
            XCTAssertFalse(model.sheetIsOpen)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), Self.fixture)
            XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), Self.fixture)
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
            XCTAssertEqual(model.selectedEntryNames, ["dev", "other"])
            XCTAssertTrue(model.hasMultipleSelection)
            XCTAssertNil(model.editor)
            table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(model.selectedEntryNames, ["other"])
            XCTAssertEqual(model.editor?.originalName, "other")
            model.editor?.name = "renamed"
            model.commitForm()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(model.selectedEntryNames, ["renamed"])
            XCTAssertEqual(model.editor?.originalName, "renamed")
            model.selectEntries(["dev", "renamed"])
            model.toggleRawEditor()
            try await Task.sleep(for: .milliseconds(100))
            model.toggleRawEditor()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(model.selectedEntryNames, ["dev", "renamed"])
            XCTAssertNil(model.editor)
        }
    }

    func testNativeContextMenuHonorsItsTargetDuringMultiSelection() async throws {
        let yaml = """
        clusters:
        - {name: a, cluster: {server: 'https://a.invalid'}}
        - {name: b, cluster: {server: 'https://b.invalid'}}
        - {name: c, cluster: {server: 'https://c.invalid'}}
        - {name: shared, cluster: {server: 'https://shared.invalid'}}
        users:
        - {name: a, user: {}}
        - {name: b, user: {}}
        - {name: c, user: {}}
        - {name: shared, user: {}}
        contexts:
        - {name: a, context: {cluster: shared, user: shared}}
        - {name: b, context: {cluster: shared, user: shared}}
        - {name: c, context: {cluster: shared, user: shared}}
        current-context: a
        """ + "\n"
        for section in AppSection.configuration {
            try await withModel(initial: yaml) { model, _ in
                let kind = try XCTUnwrap(section.kind)
                model.selectSection(section)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
                                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let host = NSHostingView(rootView: MainView(model: model))
                window.contentView = host
                window.orderFront(nil)
                defer { window.orderOut(nil) }
                try await Task.sleep(for: .milliseconds(200))

                @MainActor func invokeMenuItem(_ title: String, onRow row: Int) async throws {
                    let table = try XCTUnwrap(Self.tables(in: host).first { $0.allowsMultipleSelection })
                    let point = table.convert(NSPoint(x: 25, y: table.rect(ofRow: row).midY), to: nil)
                    let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point,
                        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                    let menu = try XCTUnwrap(table.menu(for: event))
                    menu.update()
                    let index = try XCTUnwrap(menu.items.firstIndex { $0.title == title })
                    XCTAssertTrue(menu.items[index].isEnabled)
                    menu.performActionForItem(at: index)
                    try await Task.sleep(for: .milliseconds(100))
                }

                model.selectEntries(["a", "b"])
                try await Task.sleep(for: .milliseconds(100))
                var alerts = 0
                model.ask = { title, _, _ in
                    alerts += 1
                    XCTAssertEqual(title, "Delete 2 \(section.title.lowercased())?")
                    XCTAssertEqual(model.selectedEntryNames, ["a", "b"], "Right-click inside the selection targets the whole batch")
                    return 1
                }
                try await invokeMenuItem("Delete 2 Items…", onRow: 0)
                XCTAssertEqual(alerts, 1)
                XCTAssertEqual(model.draftText, yaml)
                try await invokeMenuItem("Delete", onRow: 2)
                XCTAssertNil(model.document?.entry(kind, named: "c"), "Right-click outside the selection targets only that row")
                XCTAssertNotNil(model.document?.entry(kind, named: "a"))
                XCTAssertNotNil(model.document?.entry(kind, named: "b"))
                XCTAssertNil(model.errorMessage)
                model.undo()
                model.selectEntries(["a", "b"])
                try await Task.sleep(for: .milliseconds(100))
                try await invokeMenuItem("Duplicate", onRow: 2)
                XCTAssertEqual(model.selectedEntryNames, ["c-copy"])
                XCTAssertNotNil(model.document?.entry(kind, named: "c-copy"))
                XCTAssertNil(model.document?.entry(kind, named: "a-copy"))
                model.undo()

                if section == .contexts {
                    model.selectEntries(["a", "b"])
                    try await Task.sleep(for: .milliseconds(100))
                    try await invokeMenuItem("Make Active", onRow: 2)
                    XCTAssertEqual(model.document?.currentContext, "c")
                    model.selectEntries(["a", "b"])
                    try await Task.sleep(for: .milliseconds(100))
                    try await invokeMenuItem("Clear Active Context", onRow: 2)
                    XCTAssertEqual(model.document?.currentContext, "")
                }
            }
        }
    }

    func testNativeClusterAndUserListsSupportMultipleSelection() async throws {
        let yaml = """
        clusters:
        - {name: a, cluster: {server: 'https://a.invalid'}}
        - {name: b, cluster: {server: 'https://b.invalid'}}
        users:
        - {name: a, user: {}}
        - {name: b, user: {}}
        contexts: []
        """ + "\n"
        try await withModel(initial: yaml) { model, _ in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: MainView(model: model))
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            for section in [AppSection.clusters, .users] {
                model.selectSection(section)
                try await Task.sleep(for: .milliseconds(200))
                let table = try XCTUnwrap(Self.tables(in: host).first { $0.allowsMultipleSelection })
                table.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(model.selectedEntryNames, ["a", "b"])
                XCTAssertTrue(model.hasMultipleSelection)
                XCTAssertNil(model.editor)
                var alerts = 0
                model.ask = { title, _, _ in
                    alerts += 1
                    XCTAssertEqual(title, "Delete 2 \(section.title.lowercased())?")
                    XCTAssertEqual(model.selectedEntryNames, ["a", "b"])
                    return 1
                }
                model.requestSelectionDeletion()
                XCTAssertEqual(alerts, 1)
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(model.selectedEntryNames, ["a", "b"])
            }
        }
    }

    func testBulkDeletionChoosesOnlyVisibleRemainingEntriesAndCanLeaveNoSelection() async throws {
        let yaml = """
        clusters:
        - {name: a-hidden, cluster: {server: 'https://example.invalid'}}
        - {name: b-visible, cluster: {server: 'https://example.invalid'}}
        - {name: c-visible, cluster: {server: 'https://example.invalid'}}
        - {name: d-visible, cluster: {server: 'https://example.invalid'}}
        users: []
        contexts: []
        """ + "\n"
        try await withModel(initial: yaml) { model, _ in
            model.selectSection(.clusters)
            model.search = "visible"
            model.selectEntries(["b-visible", "c-visible"])
            model.ask = { _, _, _ in 0 }
            model.requestSelectionDeletion()
            XCTAssertEqual(model.search, "visible")
            XCTAssertEqual(model.selectedEntryNames, ["d-visible"])
            XCTAssertEqual(model.editor?.originalName, "d-visible")
            model.undo()
            XCTAssertEqual(model.selectedEntryNames, ["b-visible", "c-visible"])
            model.selectEntries(Set(model.visibleEntries.map(\.name)))
            model.ask = { _, _, _ in 0 }
            model.requestSelectionDeletion()
            XCTAssertEqual(model.document?.entries(.clusters).count, 0)
            XCTAssertTrue(model.selectedEntryNames.isEmpty)
            XCTAssertNil(model.selectedName)
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
            XCTAssertEqual(model.selectedEntryNames, ["aaa"])
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(model.selectedEntryNames, ["aaa"])
            XCTAssertEqual(model.editor?.originalName, "aaa")
            XCTAssertEqual(model.snapshot?.url, next)
        }
    }

    func testQueuedContextSelectionsCoalesceAndExpireWhenTheWorkspaceChanges() async throws {
        try await withModel { model, _ in
            model.queueEntrySelection(["other"])
            model.queueEntrySelection(["dev", "other"])
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(model.selectedEntryNames, ["dev", "other"], "The latest queued request wins")

            model.queueEntrySelection(["other"])
            model.selectEntry("dev")
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(model.selectedEntryNames, ["dev"])

            model.queueEntrySelection(["other"])
            model.search = "dev"
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(model.selectedEntryNames, ["dev"])
            model.search = ""

            model.queueEntrySelection(["other"])
            model.toggleRawEditor()
            model.toggleRawEditor()
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(model.selectedEntryNames, ["dev"])

            model.queueEntrySelection(["other"])
            model.selectSection(.clusters)
            model.selectSection(.contexts)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(model.selectedEntryNames, ["dev"])
        }
    }

    func testContextMultiSelectionFollowsARenameCommittedByTheSelectionChange() async throws {
        try await withModel { model, _ in
            model.editor?.name = "renamed"
            model.selectEntries(["dev", "other"])
            XCTAssertEqual(model.selectedEntryNames, ["renamed", "other"])
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
            XCTAssertEqual(model.selectedEntryNames, ["renamed"])
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
            model.selectEntries(["dev", "other"])
            XCTAssertEqual(model.selectedEntryNames, ["dev"])
            XCTAssertEqual(model.editor?.name, "")
            model.errorMessage = nil
            model.requestContextExport()
            XCTAssertNotNil(model.errorMessage)
            XCTAssertNil(model.contextExportPlan)
        }
    }

    func testSearchRemovesHiddenContextsFromSelectionAndExport() async throws {
        try await withModel { model, _ in
            model.selectEntries(["dev", "other"])
            model.search = "other"
            XCTAssertEqual(model.selectedEntryNames, ["other"])
            XCTAssertEqual(model.editor?.originalName, "other")
            model.requestContextExport()
            XCTAssertEqual(try exportedDocument(model).entries(.contexts).map(\.name), ["other"])
            model.closeContextExport()
            model.search = "no-match"
            XCTAssertTrue(model.selectedEntryNames.isEmpty)
            XCTAssertNil(model.editor)
            XCTAssertFalse(model.canExportContexts)
            model.search = ""
            XCTAssertTrue(model.selectedEntryNames.isEmpty, "Clearing search must not silently reselect hidden entries")
        }
    }

    func testSearchKeepsInvalidUnfinishedEditsVisible() async throws {
        try await withModel { model, _ in
            model.editor?.name = ""
            model.search = "other"
            XCTAssertEqual(model.search, "")
            XCTAssertEqual(model.selectedEntryNames, ["dev"])
            XCTAssertEqual(model.editor?.name, "")
            XCTAssertNotNil(model.errorMessage)
        }
    }

    func testExportAvailabilityAndSelectionAcrossModesSectionsAndSheets() async throws {
        try await withModel { model, _ in
            model.selectEntries(["dev", "other"])
            model.toggleRawEditor()
            XCTAssertFalse(model.canExportContexts)
            model.toggleRawEditor()
            XCTAssertEqual(model.selectedEntryNames, ["dev", "other"])
            XCTAssertTrue(model.hasMultipleSelection)
            model.showImportSource = true
            XCTAssertFalse(model.canExportContexts)
            model.requestContextExport()
            XCTAssertNil(model.contextExportPlan)
            model.showImportSource = false
            model.selectSection(.clusters)
            XCTAssertFalse(model.canExportContexts)
            XCTAssertEqual(model.selectedEntryNames, ["dev"])
            model.selectSection(.contexts)
            XCTAssertEqual(model.selectedEntryNames, ["dev"])
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
            XCTAssertEqual(model.selectedEntryNames, ["dev"])
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
            model.selectEntries(["dev", "other"])
            model.requestContextExport()
            model.chooseExportURL = { _, _ in nil }
            try model.saveContextExport()
            XCTAssertNotNil(model.contextExportPlan)
            XCTAssertEqual(model.selectedEntryNames, ["dev", "other"])
            model.chooseExportURL = { _, _ in url }
            XCTAssertThrowsError(try model.saveContextExport())
            let alias = url.deletingLastPathComponent().appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
            model.chooseExportURL = { _, _ in alias }
            XCTAssertThrowsError(try model.saveContextExport())
            XCTAssertNotNil(model.contextExportPlan)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), Self.fixture)
            XCTAssertEqual(model.selectedEntryNames, ["dev", "other"])
        }
    }

    func testContextExportEmbedsAFileOnceAndCannotOverwriteItsSource() async throws {
        let yaml = Self.fixture.replacingOccurrences(of: "server: 'https://dev.invalid'", with: "server: 'https://dev.invalid', certificate-authority: ca.pem")
        try await withModel(initial: yaml) { model, url in
            let certificate = url.deletingLastPathComponent().appendingPathComponent("ca.pem")
            try Data("certificate".utf8).write(to: certificate)
            model.selectEntries(["dev", "other"])
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
            XCTAssertEqual(model.selectedEntryNames, ["dev"])
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

    @MainActor private func applyNamespaces(_ model: AppModel, _ names: [String]) {
        for name in names {
            model.editor?.fields["namespace"] = name
            model.requestReview()
            model.commit()
        }
    }

    func testDeletingABackupAsksFirstAndSelectsTheNextOne() async throws {
        try await withModel { model, _ in
            applyNamespaces(model, ["a", "b", "c"])
            model.selectSection(.backups)
            XCTAssertEqual(model.records.count, 3)
            let records = model.records
            model.selectedBackupID = records[1].id
            var asked = 0
            model.ask = { _, _, _ in asked += 1; return 1 }
            model.deleteBackup(records[1].id)
            XCTAssertEqual(model.records, records, "Cancel keeps the backup")
            model.ask = { _, _, _ in asked += 1; return 0 }
            model.deleteBackup(records[1].id)
            XCTAssertEqual(asked, 2)
            XCTAssertEqual(model.records, [records[0], records[2]])
            XCTAssertEqual(model.selectedBackupID, records[2].id)
            model.deleteBackup(records[2].id)
            XCTAssertEqual(model.selectedBackupID, records[0].id, "The last row selects the one above it")
            model.selectedBackupID = nil
            model.deleteBackup(records[0].id)
            XCTAssertTrue(model.records.isEmpty)
            XCTAssertNil(model.selectedBackupID)
            XCTAssertNil(model.errorMessage)
            let folder = model.store.backups.location(for: model.snapshot!.resolvedURL)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [], "The summary goes with it")
        }
    }

    func testDeletingAnUnselectedBackupKeepsTheSelection() async throws {
        try await withModel { model, _ in
            applyNamespaces(model, ["a", "b"])
            model.selectSection(.backups)
            let records = model.records
            model.selectedBackupID = records[0].id
            model.ask = { _, _, _ in 0 }
            model.deleteBackup(records[1].id)
            XCTAssertEqual(model.records, [records[0]])
            XCTAssertEqual(model.selectedBackupID, records[0].id)
        }
    }

    func testDeletingABackupSelectsTheNextOneTheSearchShows() async throws {
        try await withModel { model, _ in
            let resolved = try XCTUnwrap(model.snapshot).resolvedURL
            // Only ISO times contain "T10:", so the search shows the first and last and hides the middle one.
            for time in ["2024-03-03T10:00:00Z", "2024-03-04T11:00:00Z", "2024-03-05T10:00:00Z"] {
                _ = try model.store.backups.savePrevious(Data(Self.fixture.utf8), for: resolved, retention: 10, now: try Date(time, strategy: .iso8601))
            }
            model.selectSection(.backups)
            let records = model.records
            model.search = "T10:"
            XCTAssertEqual(model.visibleBackups, [records[0], records[2]])
            model.selectedBackupID = records[0].id
            model.ask = { _, _, _ in 0 }
            model.deleteBackup(records[0].id)
            XCTAssertEqual(model.selectedBackupID, records[2].id)
            XCTAssertEqual(model.selectedBackup, records[2])
        }
    }

    func testADamagedBackupCanBeDeleted() async throws {
        try await withModel { model, _ in
            applyNamespaces(model, ["a"])
            let backup = try XCTUnwrap(model.records.first)
            let file = model.store.backups.location(for: model.snapshot!.resolvedURL).appendingPathComponent(backup.id + ".json")
            try Data("garbage".utf8).write(to: file)
            model.ask = { _, _, _ in 0 }
            model.deleteBackup(backup.id)
            XCTAssertTrue(model.records.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
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
            model.queueEntrySelection(["other"])
            model.commitForm()
            await Task.yield()
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(model.selectedEntryNames, ["other"])
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
            model.selectEntries(["dev", "other"])
            model.toggleRawEditor()
            model.editRaw(Self.fixture.replacingOccurrences(of: "name: dev\n  context", with: "name: kept\n  context")
                .replacingOccurrences(of: "name: other", with: "name: another"))
            model.toggleRawEditor()
            XCTAssertEqual(model.selectedEntryNames, ["another"])
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
            model.selectEntries(["dev", "other"])
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
            try await render(EntrySelectionSummary(model: model))
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
            model.k9sEnvironment = ["K9S_CONFIG_DIR": url.deletingLastPathComponent().appendingPathComponent("k9s").path]
            model.k9sAppearance = { .dark }
            defer { model.closeAllK9s() }
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

    func testK9sLeavesASavedContextList() async throws {
        try await withK9s { model, url, terminals in
            let cluster = try XCTUnwrap(model.document?.entry(.contexts, named: "other")?.value("cluster"))
            let saved = url.deletingLastPathComponent().appendingPathComponent("k9s/clusters/\(cluster)/other")
            try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
            try "k9s:\n  view:\n    active: contexts\n".write(to: saved.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
            await self.open(model, "other")
            XCTAssertEqual(terminals.all.first?.launch?.arguments.suffix(2), ["--command", "pods"])
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

    func testOpeningAnotherContextKeepsBothSessions() async throws {
        try await withK9s { model, _, terminals in
            await self.open(model, "dev")
            let first = terminals.all[0], exit = first.onExit
            await self.open(model, "other")
            XCTAssertFalse(first.stopped)
            XCTAssertEqual(model.k9sSessions.count, 2)
            XCTAssertEqual(model.k9sSession?.contextName, "other")
            exit?(1)
            XCTAssertEqual(model.k9sSession?.phase, .running)
            XCTAssertEqual(model.k9sSessions["dev"]?.phase, .exited(1))
            model.selectEntry("dev")
            XCTAssertEqual(model.k9sSession?.terminal.view, first.view)
            XCTAssertEqual(model.k9sSession?.phase, .exited(1))
            await self.open(model, "dev")
            XCTAssertEqual(terminals.all.count, 2, "Opening an existing session focuses it")
        }
    }

    func testCloseAndRestartOnlyAffectTheSelectedSession() async throws {
        try await withK9s { model, _, terminals in
            await self.open(model, "dev")
            model.k9sIsExpanded = true
            let devID = model.k9sSession?.id
            await self.open(model, "other")
            model.restartK9s()
            await model.k9sLaunchTask?.value
            XCTAssertTrue(terminals.all[1].stopped)
            XCTAssertFalse(terminals.all[0].stopped)
            XCTAssertEqual(model.k9sSessions["dev"]?.id, devID)
            model.closeK9s()
            XCTAssertTrue(terminals.all[2].stopped)
            XCTAssertEqual(Set(model.k9sSessions.keys), ["dev"])
            model.selectEntry("dev")
            XCTAssertTrue(model.k9sFillsWindow)
        }
    }

    func testBackgroundCleanExitAndLateCallbacksLeaveOtherSessionsAlone() async throws {
        try await withK9s { model, _, terminals in
            await self.open(model, "dev")
            let oldExit = terminals.all[0].onExit
            await self.open(model, "other")
            model.k9sIsExpanded = true
            oldExit?(0)
            XCTAssertNil(model.k9sSessions["dev"])
            XCTAssertEqual(model.k9sSession?.contextName, "other")
            XCTAssertTrue(model.k9sFillsWindow)
            XCTAssertFalse(terminals.all[1].stopped)
            await self.open(model, "dev")
            oldExit?(1)
            oldExit?(0)
            XCTAssertEqual(model.k9sSessions["dev"]?.phase, .running)
            XCTAssertEqual(model.k9sSessions.count, 2)
        }
    }

    func testClosingOnePendingLaunchKeepsTheOtherLaunch() async throws {
        try await withK9s { model, _, terminals in
            let gate = LaunchGate()
            model.findLoginPath = { await gate.wait(); return "/fake/bin" }
            model.openK9s("dev")
            let first = model.k9sLaunchTask
            model.openK9s("other")
            let second = model.k9sLaunchTask
            model.selectEntry("dev")
            model.closeK9s()
            gate.open()
            await first?.value
            await second?.value
            XCTAssertNil(terminals.all[0].launch)
            XCTAssertTrue(terminals.all[0].stopped)
            XCTAssertNotNil(terminals.all[1].launch)
            XCTAssertFalse(terminals.all[1].stopped)
        }
    }

    func testReloadAndFileChangeHandleAllSessions() async throws {
        try await withK9s { model, url, terminals in
            await self.open(model, "dev")
            await self.open(model, "other")
            model.load(url)
            XCTAssertEqual(model.k9sSessions.count, 2)
            XCTAssertEqual(model.selectedName, "other")
            XCTAssertTrue(terminals.all.allSatisfy { !$0.stopped })
            try Self.fixture.replacingOccurrences(of: "name: other", with: "name: renamed")
                .write(to: url, atomically: true, encoding: .utf8)
            model.load(url)
            XCTAssertEqual(Set(model.k9sSessions.keys), ["dev"])
            XCTAssertTrue(terminals.all[1].stopped)
            XCTAssertFalse(terminals.all[0].stopped)
            await self.open(model, "renamed")
            let otherFile = url.deletingLastPathComponent().appendingPathComponent("second")
            try Self.fixture.write(to: otherFile, atomically: true, encoding: .utf8)
            model.load(otherFile)
            XCTAssertTrue(model.k9sSessions.isEmpty)
            XCTAssertTrue(terminals.all.allSatisfy(\.stopped))
        }
    }

    func testApplyingDeletionClosesOnlyTheRemovedContextsSession() async throws {
        try await withK9s { model, _, terminals in
            await self.open(model, "dev")
            await self.open(model, "other")
            model.deleteEntry("other")
            model.commit()
            XCTAssertEqual(Set(model.k9sSessions.keys), ["dev"])
            XCTAssertTrue(terminals.all[1].stopped)
            XCTAssertFalse(terminals.all[0].stopped)
        }
    }

    func testFreshnessIsTrackedForEverySession() async throws {
        try await withK9s { model, url, _ in
            await self.open(model, "dev")
            await self.open(model, "other")
            try Self.fixture.replacingOccurrences(of: "namespace: default", with: "namespace: changed")
                .write(to: url, atomically: true, encoding: .utf8)
            model.checkForExternalChange()
            XCTAssertEqual(model.k9sSessions["dev"]?.freshness, .changed)
            XCTAssertEqual(model.k9sSessions["other"]?.freshness, .unchanged)
        }
    }

    func testHiddenSessionsNoticeExternalChangesWithoutASelectedTerminal() async throws {
        try await withK9s { model, url, _ in
            await self.open(model, "dev")
            model.selectEntry("other")
            XCTAssertNil(model.k9sSession)
            try Self.fixture.replacingOccurrences(of: "namespace: default", with: "namespace: changed")
                .write(to: url, atomically: true, encoding: .utf8)
            model.checkForExternalChange()
            XCTAssertEqual(model.k9sSessions["dev"]?.freshness, .changed)

            model.selectSection(.backups)
            try Self.fixture.replacingOccurrences(of: "name: dev\n  context", with: "name: renamed\n  context")
                .write(to: url, atomically: true, encoding: .utf8)
            model.checkForExternalChange()
            XCTAssertEqual(model.k9sSessions["dev"]?.freshness, .removed)
            model.selectSection(.contexts)
            model.selectEntry("dev")
            XCTAssertTrue(model.k9sIsVisible)
            XCTAssertEqual(model.k9sSession?.freshness, .removed)
        }
    }

    func testSessionFreshnessPublishesOnlyOneUpdateWhenValuesChange() async throws {
        try await withK9s { model, url, _ in
            await self.open(model, "dev")
            await self.open(model, "other")
            var updates = 0
            let subscription = model.$k9sSessions.dropFirst().sink { _ in updates += 1 }
            defer { subscription.cancel() }

            model.checkForExternalChange()
            XCTAssertEqual(updates, 0, "Unchanged sessions need no publication")
            try Self.fixture.replacingOccurrences(of: "https://dev.invalid", with: "https://changed.invalid")
                .write(to: url, atomically: true, encoding: .utf8)
            model.checkForExternalChange()
            XCTAssertEqual(updates, 1, "Both sessions share the changed cluster and publish together")
            XCTAssertTrue(model.k9sSessions.values.allSatisfy { $0.freshness == .changed })

            model.checkForExternalChange()
            XCTAssertEqual(updates, 1, "A repeated check leaves existing warnings alone")
            try Self.fixture.write(to: url, atomically: true, encoding: .utf8)
            model.checkForExternalChange()
            XCTAssertEqual(updates, 2)
            XCTAssertTrue(model.k9sSessions.values.allSatisfy { $0.freshness == .unchanged })
        }
    }

    func testQuittingClosesAllSessionsIncludingAPendingLaunch() async throws {
        try await withK9s { model, _, terminals in
            await self.open(model, "dev")
            let gate = LaunchGate()
            model.findLoginPath = { await gate.wait(); return "/fake/bin" }
            // A missing executable makes Try Again refresh the cached login PATH.
            model.isK9sExecutable = { _ in false }
            await self.open(model, "other")
            model.restartK9s()
            let pending = model.k9sLaunchTask
            let delegate = ApplicationDelegate()
            delegate.model = model
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            gate.open()
            await pending?.value
            XCTAssertTrue(model.k9sSessions.isEmpty)
            XCTAssertTrue(terminals.all.allSatisfy(\.stopped))
            XCTAssertNil(terminals.all.last?.launch)
        }
    }

    func testSessionsUseLaunchAppearanceUntilRestarted() async throws {
        try await withK9s { model, _, terminals in
            var appearance = K9sAppearance.light
            model.k9sAppearance = { appearance }
            await self.open(model, "dev")
            let firstID = model.k9sSession?.id
            appearance = .dark
            await self.open(model, "other")
            XCTAssertEqual(terminals.all[0].launch?.appearance, .light)
            XCTAssertTrue(terminals.all[0].launch?.arguments.contains("--invert") == true)
            XCTAssertEqual(terminals.all[1].launch?.appearance, .dark)
            XCTAssertFalse(terminals.all[1].launch?.arguments.contains("--invert") == true)
            await self.open(model, "dev")
            XCTAssertEqual(model.k9sSession?.id, firstID)
            XCTAssertEqual(model.k9sSession?.appearance, .light)
            XCTAssertFalse(terminals.all[0].stopped)
            model.restartK9s()
            await model.k9sLaunchTask?.value
            XCTAssertEqual(model.k9sSession?.appearance, .dark)
            XCTAssertFalse(terminals.all[2].launch?.arguments.contains("--invert") == true)
            XCTAssertFalse(terminals.all[1].stopped)
        }
    }

    func testFocusRequestsBelongToTheirSession() async throws {
        try await withK9s { model, _, _ in
            await self.open(model, "dev")
            let devID = try XCTUnwrap(model.k9sSession?.id)
            await self.open(model, "other")
            let otherID = try XCTUnwrap(model.k9sSession?.id)
            XCTAssertFalse(model.takeK9sFocusRequest(for: devID))
            XCTAssertTrue(model.takeK9sFocusRequest(for: otherID))
            model.selectEntry("dev")
            XCTAssertTrue(model.takeK9sFocusRequest(for: devID))
            XCTAssertFalse(model.takeK9sFocusRequest(for: devID))
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
            model.selectEntries(["dev", "other"])
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
            XCTAssertEqual(model.k9sSessions["dev"]?.freshness, .changed)

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
            XCTAssertEqual(model.k9sSessions["dev"]?.freshness, .changed)
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

    func testOpeningAnotherContextDuringLaunchStartsBoth() async throws {
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
            XCTAssertEqual(terminals.all[0].launch?.arguments.dropFirst(3).first, "dev")
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
            XCTAssertNotNil(model.k9sSessions["dev"])
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

    func testSavedViewIsFoundThroughTheClusterOnDisk() async throws {
        try await withK9s { model, url, terminals in
            let moved = Self.fixture.replacingOccurrences(of: "- name: dev\n  cluster:", with: "- name: moved\n  cluster:")
                .replacingOccurrences(of: "{cluster: dev, namespace: default}", with: "{cluster: moved, namespace: default}")
            try moved.write(to: url, atomically: true, encoding: .utf8)
            let saved = url.deletingLastPathComponent().appendingPathComponent("k9s/clusters/moved/dev")
            try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
            try "k9s:\n  view:\n    active: ctx\n".write(to: saved.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
            await self.open(model, "dev")
            XCTAssertEqual(terminals.all.first?.launch?.arguments.suffix(2), ["--command", "pods"])
        }
    }

    func testReloadingADeletedFileEndsK9s() async throws {
        try await withK9s { model, url, terminals in
            await self.open(model, "dev")
            try FileManager.default.removeItem(at: url)
            model.reload()
            XCTAssertNil(model.k9sSession)
            XCTAssertEqual(terminals.all.first?.stopped, true)
        }
    }

    func testReloadingABlankedFileEndsK9s() async throws {
        try await withK9s { model, url, _ in
            await self.open(model, "dev")
            try Data().write(to: url)
            model.reload()
            XCTAssertNil(model.k9sSession)
        }
    }

    func testReloadingABrokenFileKeepsK9s() async throws {
        try await withK9s { model, url, _ in
            await self.open(model, "dev")
            try "clusters: [".write(to: url, atomically: true, encoding: .utf8)
            model.reload()
            XCTAssertNotNil(model.k9sSessions["dev"])
        }
    }

    func testRestartReasons() async throws {
        try await withK9s { model, url, _ in
            XCTAssertEqual(model.k9sRestartBlockReason, "k9s isn’t open")
            await self.open(model, "dev")
            XCTAssertNil(model.k9sRestartBlockReason)
            try FileManager.default.removeItem(at: url)
            model.checkForExternalChange()
            XCTAssertEqual(model.k9sRestartBlockReason, "This context is no longer in the file")
        }
    }

    @MainActor private func render(_ view: some View) async throws -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(50))
        return window
    }

    func testK9sPaneAdoptsTheTerminalAndTakesItsFocusRequest() async throws {
        try await withK9s { model, _, terminals in
            await self.open(model, "dev")
            let window = try await self.render(K9sDetailView(model: model, session: XCTUnwrap(model.k9sSession)))
            defer { window.orderOut(nil) }
            XCTAssertTrue(terminals.all.first?.view.superview is K9sTerminalHost.Container)
            XCTAssertFalse(model.takeK9sFocusRequest(), "The pane already used it")

            let second = try await self.render(K9sDetailView(model: model, session: XCTUnwrap(model.k9sSession)))
            defer { second.orderOut(nil) }
            XCTAssertEqual(terminals.all.first?.view.window, second, "A new pane takes the terminal from the old one")
        }
    }

    func testK9sPaneShowsAFailedOrMissingSession() async throws {
        try await withK9s { model, _, terminals in
            await self.open(model, "dev")
            terminals.all.first?.onExit?(1)
            let window = try await self.render(K9sDetailView(model: model, session: XCTUnwrap(model.k9sSession)))
            defer { window.orderOut(nil) }
            XCTAssertEqual(terminals.all.first?.view.window, window, "The output stays on screen")
        }
        try await withK9s(k9sInstalled: false) { model, _, terminals in
            await self.open(model, "dev")
            let window = try await self.render(K9sDetailView(model: model, session: XCTUnwrap(model.k9sSession)))
            defer { window.orderOut(nil) }
            XCTAssertNil(terminals.all.first?.view.window, "There's no output to show")
        }
    }

    func testTerminalRunsTheLaunchAndReportsItsExit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("k9s")
        try "#!/bin/sh\nexit 3\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let launch = try XCTUnwrap(K9sLaunch(kubeconfig: directory.appendingPathComponent("config"), context: "c", loginPath: directory.path, inherited: [:]))

        let terminal = await K9sTerminalProcess()
        await terminal.stop() // Closing during launch stops a terminal that hasn't started.
        let exited = expectation(description: "exit")
        let status = StatusBox()
        await MainActor.run {
            terminal.onExit = { status.value = $0; exited.fulfill() }
            terminal.start(launch)
        }
        await fulfillment(of: [exited], timeout: 10)
        XCTAssertEqual(status.value, 3)
    }

    @MainActor func testTerminalInsetsAndLaunchColorsSurviveResizeAndAppearanceChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("k9s")
        try "#!/bin/sh\nprintf 'Context: development\\r\\n\\r\\nNAME          READY   STATUS\\r\\napi-server    1/1     Running\\r\\n'\nexit 3\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        for appearance in [K9sAppearance.light, .dark] {
            let launch = try XCTUnwrap(K9sLaunch(kubeconfig: directory.appendingPathComponent("config"), context: "c",
                                               appearance: appearance, loginPath: directory.path, inherited: [:]))
            let terminal = K9sTerminalProcess()
            defer { terminal.stop() }
            let window = try await render(K9sTerminalHost(terminal: terminal.view, appearance: appearance, takeFocusRequest: { false }))
            defer { window.orderOut(nil) }
            let exited = expectation(description: "terminal output in \(appearance)")
            terminal.onExit = { _ in exited.fulfill() }
            terminal.start(launch)
            await fulfillment(of: [exited], timeout: 10)
            window.appearance = (appearance == .light ? K9sAppearance.dark : .light).nativeAppearance

            for size in [NSSize(width: 800, height: 600), NSSize(width: 480, height: 320)] {
                window.setContentSize(size)
                window.contentView?.layoutSubtreeIfNeeded()
                let container = try XCTUnwrap(terminal.view.superview as? K9sTerminalHost.Container)
                XCTAssertEqual(terminal.view.frame, container.bounds.insetBy(dx: 8, dy: 8))
                XCTAssertEqual(terminal.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]),
                               appearance == .light ? .aqua : .darkAqua)
                XCTAssertEqual(container.layer?.backgroundColor, terminal.view.layer?.backgroundColor)
                let terminalBackground = try XCTUnwrap(terminal.view.layer?.backgroundColor)
                let color = try XCTUnwrap(NSColor(cgColor: terminalBackground)?.usingColorSpace(.deviceRGB))
                XCTAssertEqual(color.redComponent, appearance.backgroundColor.redComponent, accuracy: 0.001)
                XCTAssertEqual(color.greenComponent, appearance.backgroundColor.greenComponent, accuracy: 0.001)
                XCTAssertEqual(color.blueComponent, appearance.backgroundColor.blueComponent, accuracy: 0.001)
            }
        }
    }

    @MainActor func testTerminalPaddingFollowsRuntimeBackgroundChangesAndReparenting() async throws {
        let terminal = K9sTerminalProcess()
        let view = try XCTUnwrap(terminal.view as? TerminalView)
        let host = K9sTerminalHost(terminal: view, appearance: .dark, takeFocusRequest: { false })
        let firstWindow = try await render(host)
        defer { firstWindow.orderOut(nil) }
        let firstContainer = try XCTUnwrap(view.superview as? K9sTerminalHost.Container)

        @MainActor func changeBackground(to color: NSColor, using sequence: String, in container: K9sTerminalHost.Container) async throws {
            let changed = expectation(description: "padding follows terminal background")
            let layer = try XCTUnwrap(container.layer)
            let expected = try XCTUnwrap(color.usingColorSpace(.sRGB))
            let observation = layer.observe(\.backgroundColor, options: [.new]) { layer, _ in
                guard let background = layer.backgroundColor,
                      let actual = NSColor(cgColor: background)?.usingColorSpace(.sRGB),
                      abs(actual.redComponent - expected.redComponent) < 0.001,
                      abs(actual.greenComponent - expected.greenComponent) < 0.001,
                      abs(actual.blueComponent - expected.blueComponent) < 0.001 else { return }
                changed.fulfill()
            }
            defer { observation.invalidate() }
            view.feed(text: sequence)
            await fulfillment(of: [changed], timeout: 5)
            XCTAssertEqual(container.layer?.backgroundColor, view.layer?.backgroundColor)
        }

        // OSC 11 is how a terminal program changes its default background.
        try await changeBackground(to: NSColor(srgbRed: 0x22 / 255.0, green: 0x44 / 255.0, blue: 0x66 / 255.0, alpha: 1),
                                   using: "\u{1b}]11;rgb:22/44/66\u{7}", in: firstContainer)
        let firstBackground = firstContainer.layer?.backgroundColor

        // A SwiftUI update must not reset the program's color to the launch appearance.
        (firstWindow.contentView as? NSHostingView<K9sTerminalHost>)?.rootView = host
        firstWindow.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(firstContainer.layer?.backgroundColor, firstBackground)

        let secondWindow = try await render(host)
        defer { secondWindow.orderOut(nil) }
        let secondContainer = try XCTUnwrap(view.superview as? K9sTerminalHost.Container)
        XCTAssertEqual(secondContainer.layer?.backgroundColor, firstBackground)
        try await changeBackground(to: NSColor(srgbRed: 0x66 / 255.0, green: 0x44 / 255.0, blue: 0x22 / 255.0, alpha: 1),
                                   using: "\u{1b}]11;rgb:66/44/22\u{7}", in: secondContainer)
        try await changeBackground(to: view.nativeForegroundColor, using: "\u{1b}[?5h", in: secondContainer)
        try await changeBackground(to: view.nativeBackgroundColor, using: "\u{1b}[?5l", in: secondContainer)
        XCTAssertEqual(firstContainer.layer?.backgroundColor, firstBackground, "The old host stops observing after reparenting")
        XCTAssertEqual(view.frame, secondContainer.bounds.insetBy(dx: 8, dy: 8))
    }

    @MainActor func testK9sCellFillsSetTheCanvasAndPaddingBackground() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("k9s")
        // Like k9s/tcell: paint true-color cells, with a differently colored selection row, without OSC 11.
        try """
        #!/bin/sh
        /bin/stty -echo
        while IFS= read -r background; do
            printf '\\033[48;2;%sm\\033[2J\\033[HContext: test' "$background"
            printf '\\033[48;2;255;165;0m\\033[1;1H\\033[2KSelected row'
        done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let process = K9sTerminalProcess()
        defer { process.stop() }
        let terminal = try XCTUnwrap(process.view as? TerminalView)
        let window = try await render(K9sTerminalHost(terminal: terminal, appearance: .dark, takeFocusRequest: { false }))
        defer { window.orderOut(nil) }
        let container = try XCTUnwrap(terminal.superview as? K9sTerminalHost.Container)
        let launch = try XCTUnwrap(K9sLaunch(kubeconfig: directory.appendingPathComponent("config"), context: "test",
                                           loginPath: directory.path, inherited: [:]))
        process.start(launch)
        let layer = try XCTUnwrap(container.layer)
        // Test the reported black/gray mismatch, a custom skin, and a live switch to a light skin.
        for rgb in [(0, 0, 0), (34, 68, 102), (238, 221, 204)] {
            let matched = expectation(description: "padding matches the cell fill \(rgb)")
            let expected = [CGFloat(rgb.0) / 255, CGFloat(rgb.1) / 255, CGFloat(rgb.2) / 255]
            let observation = layer.observe(\.backgroundColor, options: [.new]) { layer, _ in
                guard let background = layer.backgroundColor,
                      let color = NSColor(cgColor: background)?.usingColorSpace(.sRGB),
                      zip([color.redComponent, color.greenComponent, color.blueComponent], expected)
                        .allSatisfy({ abs($0 - $1) < 0.001 }) else { return }
                matched.fulfill()
            }
            terminal.send(txt: "\(rgb.0);\(rgb.1);\(rgb.2)\r")
            await fulfillment(of: [matched], timeout: 5)
            observation.invalidate()
            let color = try XCTUnwrap(terminal.nativeBackgroundColor.usingColorSpace(.sRGB))
            XCTAssertEqual(color.redComponent, expected[0], accuracy: 0.001)
            XCTAssertEqual(color.greenComponent, expected[1], accuracy: 0.001)
            XCTAssertEqual(color.blueComponent, expected[2], accuracy: 0.001)
            XCTAssertEqual(container.layer?.backgroundColor, terminal.layer?.backgroundColor)
            XCTAssertEqual(terminal.frame, container.bounds.insetBy(dx: 8, dy: 8))
            XCTAssertEqual(terminal.terminalContentSnapshot(region: .viewport)?.rows.first?.cells.first?.attribute.bg,
                           .trueColor(red: 255, green: 165, blue: 0), "A selection row must not recolor the surrounding canvas")
        }
    }

    func testExpansionIsRememberedPerContextAndSurvivesRestart() async throws {
        try await withK9s { model, _, _ in
            await self.open(model, "dev")
            model.k9sIsExpanded = true
            model.restartK9s()
            await model.k9sLaunchTask?.value
            XCTAssertTrue(model.k9sIsExpanded)
            await self.open(model, "other")
            XCTAssertFalse(model.k9sIsExpanded)
            model.selectEntry("dev")
            XCTAssertTrue(model.k9sIsExpanded)
            model.selectEntry("other")
            model.k9sIsExpanded = true
            model.closeK9s()
            model.selectEntry("dev")
            XCTAssertTrue(model.k9sIsExpanded, "Closing another session leaves this layout alone")
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

private final class StatusBox: @unchecked Sendable { var value: Int32? }

private struct UnwritableBackups: FileAccess {
    func read(_ url: URL, maximumByteCount: Int) throws -> Data? { try LocalFileAccess().read(url, maximumByteCount: maximumByteCount) }
    func writeAtomically(_ data: Data, to url: URL) throws { throw CocoaError(.fileWriteNoPermission) }
}
