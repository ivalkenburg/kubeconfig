import AppKit
import KubeConfigCore
import SwiftUI

enum AppSection: String, Identifiable {
    case contexts, clusters, users, backups
    static let configuration: [AppSection] = [.contexts, .clusters, .users]
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var kind: EntryKind? { EntryKind(rawValue: rawValue) }
    var symbol: String { kind?.symbol ?? "clock.arrow.circlepath" }
}

enum BackupRetention {
    static let key = "backupRetention"
    static let defaultCount = 10
    static let range = 0...1000
    static func clamped(_ count: Int) -> Int { min(range.upperBound, max(range.lowerBound, count)) }
}

enum ContextSwitching {
    static let immediateKey = "switchContextsImmediately"
    static let immediateByDefault = true
}

extension FormatStyle where Self == Date.FormatStyle {
    static var backupDate: Date.FormatStyle { .dateTime.month(.abbreviated).day().hour().minute().second() }
    static var backupFullDate: Date.FormatStyle { .dateTime.year().month(.wide).day().hour().minute().second() }
}

struct EntryEditor: Equatable {
    let kind: EntryKind
    let originalName: String
    var name: String
    var fields: [String: String]

    private static func keys(_ kind: EntryKind) -> [String] {
        switch kind {
        case .contexts: return ["cluster", "user", "namespace"]
        case .clusters: return ["server", "certificate-authority", "tls-server-name", "proxy-url"]
        case .users: return ["username", "password", "token", "client-certificate", "client-key"]
        }
    }

    init(_ entry: ConfigEntry) {
        kind = entry.kind
        originalName = entry.name
        name = entry.name
        fields = Dictionary(uniqueKeysWithValues: Self.keys(entry.kind).map { ($0, entry.value($0)) })
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var section: AppSection = .contexts
    @Published var selectedName: String?
    @Published var search = ""
    @Published var editor: EntryEditor? { didSet { evaluation = nil } }
    @Published var document: KubeDocument? { didSet { evaluation = nil } }
    @Published var draftText = ""
    @Published var snapshot: FileSnapshot? {
        didSet {
            diskDocument = snapshot.flatMap { $0.exists ? try? KubeDocument(yaml: $0.text) : nil }
            serializedDisk = (try? diskDocument?.serialized()) ?? snapshot?.text ?? ""
            fileChangedOnDisk = false
        }
    }
    /// The file differs from the loaded snapshot. Reloading stays the user's choice.
    @Published var fileChangedOnDisk = false
    @Published var parseIssue: String? { didSet { evaluation = nil } }
    @Published var parseIssueLine: Int?
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var backupWarning: String?
    @Published var recoveryContents: Data?
    @Published var records: [BackupSummary] = []
    @Published var damagedBackupCount = 0
    @Published var selectedBackupID: String?
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    /// Bumped to move focus to the list's search field.
    @Published var searchFocusRequest = 0
    @Published private(set) var recentFiles: [URL]
    @Published var showRaw = false {
        // Two columns mean something else in each mode, so a collapsed sidebar has to be carried across.
        didSet { if showRaw != oldValue, sidebarIsCollapsed(raw: oldValue) { columnVisibility = hiddenSidebarColumns } }
    }
    @Published var showReview = false
    @Published var showImport = false
    @Published var importPlan: ImportPlan?
    @Published var showImportSource = false
    @Published var wrapsYAML: Bool { didSet { defaults.set(wrapsYAML, forKey: Self.wrapsYAMLKey) } }
    @Published private var undoStack: [String] = []
    @Published private var redoStack: [String] = []
    @Published var rawCanUndo = false
    @Published var rawCanRedo = false
    private var loadedEditor: EntryEditor? { didSet { evaluation = nil } }
    private var afterApply: (() -> Void)?
    private var diskDocument: KubeDocument? { didSet { evaluation = nil } }
    /// What each draft state is compared with, which is too slow to work out on every keystroke.
    private var serializedDisk = ""
    /// Views read the issues and counts several times per update, so each draft state is evaluated once.
    private var evaluation: (issues: [String], changes: DraftChanges?, reviewCount: Int)?
    /// The draft when YAML editing began. The whole session becomes one undo step.
    private var rawSessionStart: String?
    private static let historyLimit = 100
    private static let wrapsYAMLKey = "wrapsYAML"
    private static let recentFilesKey = "recentConfigurations"
    private static let recentFilesLimit = 10
    weak var rawEditor: NSTextView?
    weak var window: NSWindow?
    let store: ConfigurationStore
    let defaults: UserDefaults
    private(set) var launchOptions: LaunchOptions?

    init(store: ConfigurationStore = ConfigurationStore(), defaults: UserDefaults = .standard, initialURL: URL? = nil,
         arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.store = store
        self.defaults = defaults
        defaults.register(defaults: [BackupRetention.key: BackupRetention.defaultCount,
                                     ContextSwitching.immediateKey: ContextSwitching.immediateByDefault])
        wrapsYAML = defaults.bool(forKey: Self.wrapsYAMLKey)
        recentFiles = (defaults.stringArray(forKey: Self.recentFilesKey) ?? []).map(URL.init(fileURLWithPath:))
        do {
            let options = try LaunchOptions(arguments: arguments)
            launchOptions = options
            load(initialURL ?? options.configurationURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kube/config"))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var retention: Int { BackupRetention.clamped(defaults.integer(forKey: BackupRetention.key)) }
    var switchesContextsImmediately: Bool { defaults.bool(forKey: ContextSwitching.immediateKey) }
    var formIsDirty: Bool { editor != loadedEditor }
    var hasPendingChanges: Bool { draftText != (snapshot?.text ?? "") || formIsDirty }
    var needsAttentionBeforeLeaving: Bool { hasPendingChanges || recoveryContents != nil }
    var sheetIsOpen: Bool { showReview || showImportSource || showImport }
    /// No file, or a blank one such as `touch ~/.kube/config` leaves, so there's nothing to edit yet.
    var hasNoConfiguration: Bool {
        snapshot.map { draftText == $0.text && $0.text.allSatisfy(\.isWhitespace) } ?? false
    }
    var validationIssues: [String] { evaluated.issues }
    var canApply: Bool { hasPendingChanges && validationIssues.isEmpty }
    var pendingChanges: DraftChanges? { evaluated.changes }
    /// The changes Review will step through, which can differ from the entries that changed.
    var reviewCount: Int { evaluated.reviewCount }
    var canUndo: Bool { !undoStack.isEmpty || formIsDirty || rawCanUndo || hasRawSessionEdits }
    var canRedo: Bool { !redoStack.isEmpty || rawCanRedo }
    var canRedoCommand: Bool { canRedo || fieldCanRedo }
    private var fieldCanRedo: Bool { !showRaw && (NSApp.keyWindow?.firstResponder as? NSText)?.undoManager?.canRedo == true }
    var nameError: String? {
        guard let editor, formIsDirty else { return nil }
        return document?.nameIssue(editor.kind, name: editor.name, originalName: editor.originalName)
    }
    /// The open file's path as the toolbar shows it.
    var filePath: String { snapshot.map { displayPath($0.url) } ?? "" }
    /// A form being typed in outranks the status, which may say Applied.
    var draftStatus: String? { formIsDirty ? "Edited" : statusMessage ?? (hasPendingChanges ? "Edited" : nil) }
    func displayPath(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }
    /// With the sidebar gone, the toolbar title takes over choosing the section.
    var sidebarIsCollapsed: Bool { sidebarIsCollapsed(raw: showRaw) }
    private func sidebarIsCollapsed(raw: Bool) -> Bool {
        columnVisibility == .detailOnly || (!raw && columnVisibility == .doubleColumn)
    }
    private var hiddenSidebarColumns: NavigationSplitViewVisibility { showRaw ? .detailOnly : .doubleColumn }
    func toggleSidebar() { columnVisibility = sidebarIsCollapsed ? .all : hiddenSidebarColumns }
    private var hasRawSessionEdits: Bool { rawSessionStart.map { $0 != draftText } ?? false }
    private var evaluated: (issues: [String], changes: DraftChanges?, reviewCount: Int) {
        if let evaluation { return evaluation }
        let preview = previewDocument
        let reviewCount = preview.flatMap { try? ConfigurationDiff.changeCount(serializedBefore: serializedDisk, after: $0) } ?? 0
        let result = (parseIssue.map { [$0] } ?? preview?.validationIssues ?? [], preview?.changes(from: diskDocument), reviewCount)
        evaluation = result
        return result
    }
    /// The draft with any form edit that hasn't been committed yet, so counts stay right while typing.
    private var previewDocument: KubeDocument? {
        guard let editor, formIsDirty, var next = document else { return document }
        return (try? next.update(editor.kind, originalName: editor.originalName, name: editor.name, fields: changedFields(editor))) == nil ? document : next
    }
    private var diskEntry: ConfigEntry? {
        editor.flatMap { diskDocument?.entry($0.kind, named: $0.originalName) }
    }
    var isNameChanged: Bool {
        guard let editor, diskDocument != nil else { return false }
        return diskEntry == nil || editor.name != editor.originalName
    }
    func isFieldChanged(_ key: String) -> Bool {
        guard let editor, let diskEntry else { return false }
        return diskEntry.value(key) != editor.fields[key]
    }
    /// Why an entry can't be deleted, for disabled buttons and menu items.
    func deleteBlockReason(_ name: String) -> String? {
        guard let kind = section.kind, let document else { return "Nothing to delete" }
        let count = document.referencingContexts(kind, name: name).count
        return count == 0 ? nil : "Used by \(count) context\(count == 1 ? "" : "s")"
    }
    var selectedBackup: BackupSummary? { visibleBackups.first { $0.id == selectedBackupID } }
    var visibleBackups: [BackupSummary] {
        guard !search.isEmpty else { return records }
        return records.filter { record in
            [record.createdAt.formatted(.backupFullDate),
             record.createdAt.formatted(.backupDate),
             record.createdAt.ISO8601Format()].contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }
    var visibleEntries: [ConfigEntry] {
        guard let kind = section.kind else { return [] }
        return (document?.entries(kind) ?? []).filter { entry in
            search.isEmpty || [entry.name, entry.value("cluster"), entry.value("user"), entry.value("namespace"), entry.value("server")].contains { $0.localizedCaseInsensitiveContains(search) }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func load(_ url: URL) {
        do {
            let loaded = try store.load(url)
            snapshot = loaded
            if loaded.exists { noteRecentFile(loaded.url) }
            draftText = loaded.text
            parseDraft()
            clearEditor(); selectedName = nil; search = ""
            showRaw = false; statusMessage = nil; backupWarning = nil
            clearHistory()
            selectFirstEntry()
            refreshBackups()
        } catch { errorMessage = error.localizedDescription }
    }

    private func parseDraft() {
        parseIssueLine = nil
        if hasNoConfiguration { document = nil; parseIssue = nil; return }
        do { document = try KubeDocument(yaml: draftText); parseIssue = nil }
        catch {
            document = nil
            parseIssue = error.localizedDescription
            parseIssueLine = (error as? ConfigError)?.line
        }
    }

    func editRaw(_ text: String) {
        guard text != draftText else { return }
        if rawSessionStart == nil { rawSessionStart = draftText }
        redoStack.removeAll()
        draftText = text
        clearEditor()
        statusMessage = nil
        parseDraft()
    }

    private func clearEditor() { editor = nil; loadedEditor = nil }

    func stage(_ next: KubeDocument, message: String? = nil) throws {
        let serialized = try next.serialized()
        // Keep the file's own text when nothing differs, so changing a value back leaves nothing to apply.
        let text = diskDocument?.isEquivalent(to: next) == true ? (snapshot?.text ?? serialized) : serialized
        if text != draftText { recordStep() }
        document = next
        draftText = text
        parseIssue = nil
        parseIssueLine = nil
        statusMessage = text == snapshot?.text ? nil : message
    }

    /// Saves the current draft as the state Undo returns to. Call before changing it.
    private func recordStep() {
        endRawSession()
        pushUndo(draftText)
        redoStack.removeAll()
    }

    private func pushUndo(_ text: String) {
        undoStack.append(text)
        if undoStack.count > Self.historyLimit { undoStack.removeFirst() }
    }

    func endRawSession() {
        if hasRawSessionEdits, let rawSessionStart { pushUndo(rawSessionStart) }
        rawSessionStart = nil
    }

    private func clearHistory() {
        undoStack.removeAll(); redoStack.removeAll()
        rawSessionStart = nil
    }

    func undo() {
        if showRaw, let rawEditor, rawCanUndo {
            rawEditor.breakUndoCoalescing()
            rawEditor.undoManager?.undo()
            return
        }
        guard (try? flushEditor()) != nil else { editor = loadedEditor; return }
        endRawSession()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(draftText)
        restore(previous)
    }

    func redo() {
        if showRaw, let rawEditor, rawCanRedo {
            rawEditor.undoManager?.redo()
            return
        }
        // An unfinished form edit is a new change, so committing it empties the redo stack.
        guard (try? flushEditor()) != nil, let next = redoStack.popLast() else { return }
        endRawSession()
        pushUndo(draftText)
        restore(next)
    }

    /// Undo for the toolbar and Edit menu. Text being typed, sheets, and other windows keep their own undo.
    func undoCommand() {
        if usesResponderUndo { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } else { undo() }
    }

    func redoCommand() {
        if usesResponderUndo || fieldCanRedo { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) } else { redo() }
    }

    private var usesResponderUndo: Bool {
        guard let window, let key = NSApp.keyWindow, key === window else { return NSApp.keyWindow != nil }
        return !showRaw && formIsDirty && key.firstResponder is NSText
    }

    private func restore(_ text: String) {
        let previous = document
        draftText = text
        parseDraft()
        statusMessage = nil
        clearEditor()
        guard !showRaw else { return }
        let changed = section.kind.flatMap { kind -> String? in
            let old = Dictionary((previous?.entries(kind) ?? []).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            return document?.entries(kind).filter { old[$0.name] != $0 }.map(\.name)
                .min { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        reselect(changed)
    }

    /// Selects `preferred`, or else keeps the current entry if it still exists.
    private func reselect(_ preferred: String? = nil) {
        let current = selectedName.flatMap { name in section.kind.flatMap { document?.entry($0, named: name) }?.name }
        if let target = preferred ?? current { reveal(target) } else { selectFirstEntry() }
    }

    /// Selects an entry, clearing a search that would hide it from the list.
    private func reveal(_ name: String) {
        if !visibleEntries.contains(where: { $0.name == name }) { search = "" }
        selectEntry(name)
    }

    private func changedFields(_ editor: EntryEditor) -> [String: String] {
        editor.fields.filter { key, value in loadedEditor?.fields[key] != value }
    }

    /// Commits the form when a field is finished. A bad name stays in the form with its error beside it.
    func commitForm() {
        guard formIsDirty, nameError == nil else { return }
        do { try flushEditor() } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    func flushEditor() throws -> Bool {
        guard let editor, editor != loadedEditor else { return false }
        guard var next = document else { throw ConfigError.invalid("Repair the configuration in YAML before editing entries.") }
        try next.update(editor.kind, originalName: editor.originalName, name: editor.name, fields: changedFields(editor))
        try stage(next)
        let name = editor.name.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedName = name
        self.editor = next.entry(editor.kind, named: name).map(EntryEditor.init)
        loadedEditor = self.editor
        return true
    }

    func selectSection(_ next: AppSection) {
        do {
            try flushEditor()
            endRawSession()
            section = next; search = ""; showRaw = false
            clearEditor(); selectedName = nil
            if next == .backups { refreshBackups() } else { selectFirstEntry() }
        } catch { errorMessage = error.localizedDescription }
    }

    func selectEntry(_ name: String?) {
        do {
            try flushEditor()
            selectedName = name
            if let kind = section.kind, let name, let entry = document?.entry(kind, named: name) {
                editor = EntryEditor(entry)
                loadedEditor = editor
            } else { clearEditor() }
        } catch { errorMessage = error.localizedDescription }
    }

    func selectFirstEntry() { selectEntry(visibleEntries.first?.name) }

    func createConfiguration() {
        do { try stage(.empty); selectFirstEntry() }
        catch { errorMessage = error.localizedDescription }
    }

    func addEntry() {
        guard let kind = section.kind else { return }
        do {
            try flushEditor()
            guard var next = document else { return }
            let name = KubeDocument.uniqueName("new-\(kind.singular)") { next.entry(kind, named: $0) != nil }
            var fields: [String: String] = [:]
            if kind == .contexts {
                fields["cluster"] = next.entries(.clusters).first?.name ?? ""
                fields["user"] = next.entries(.users).first?.name ?? ""
            }
            try next.update(kind, originalName: nil, name: name, fields: fields)
            try stage(next)
            reveal(name)
        } catch { errorMessage = error.localizedDescription }
    }

    /// Flushes the form and returns the entry's current name, since the flush may have renamed it.
    private func flushed(_ name: String?) throws -> String? {
        let isEditing = name == editor?.originalName
        try flushEditor()
        return isEditing ? selectedName : name
    }

    func makeActive(_ name: String? = nil) {
        do {
            guard let name = try flushed(name ?? selectedName) else { return }
            try switchContext(to: name, stagedMessage: "Context switch staged")
        } catch { errorMessage = error.localizedDescription }
    }

    func clearActive() {
        do {
            try flushEditor()
            try switchContext(to: "", stagedMessage: "Active context cleared")
        } catch { errorMessage = error.localizedDescription }
    }

    /// Writes the switch straight to the file if the preference allows it, leaving other pending edits in the draft.
    private func switchContext(to name: String, stagedMessage: String) throws {
        guard var next = document else { return }
        try next.setCurrentContext(name)
        guard switchesContextsImmediately, let snapshot else { try stage(next, message: stagedMessage); return }
        guard name.isEmpty || diskDocument?.entry(.contexts, named: name) != nil else {
            try stage(next, message: "Staged: ‘\(name)’ isn't on disk yet")
            return
        }
        try requireRecoveryResolved()
        let text = try KubeDocument.settingCurrentContext(name, in: draftText) ?? next.serialized()
        let written: FileSnapshot?
        do { written = try store.switchContext(to: name, over: snapshot) } catch {
            checkForExternalChange()
            throw error
        }
        guard let written else { try stage(next, message: stagedMessage); return }
        // History holds whole drafts, so without this Undo would bring the old context back as a pending change.
        self.snapshot = written
        undoStack = undoStack.map { draft($0, following: name) }
        redoStack = redoStack.map { draft($0, following: name) }
        document = next
        draftText = draft(text, following: name)
        statusMessage = name.isEmpty ? stagedMessage : "Switched to ‘\(name)’"
    }

    /// Keeps the file's own text when nothing differs, as `stage` does, so a matching draft leaves nothing to apply.
    private func draft(_ text: String, following name: String) -> String {
        let patched = KubeDocument.settingCurrentContext(name, in: text) ?? text
        guard let parsed = try? KubeDocument(yaml: patched), diskDocument?.isEquivalent(to: parsed) == true else { return patched }
        return snapshot?.text ?? patched
    }

    func deleteEntry(_ requested: String? = nil) {
        do {
            guard let kind = section.kind, let name = try flushed(requested ?? selectedName), var next = document else { return }
            if kind == .contexts && next.currentContext == name {
                // Deletes are staged and undoable, so only clearing the active context asks first.
                let choice = ask("Delete the active context ‘\(name)’?", "This also clears the active context. The change takes effect after Apply.", ["Delete & Clear Active", "Cancel"])
                guard choice == 0 else { return }
                try next.setCurrentContext("")
            }
            try next.delete(kind, name: name)
            try stage(next)
            if selectedName == name {
                clearEditor(); selectedName = nil
                selectFirstEntry()
            }
        } catch { errorMessage = error.localizedDescription }
    }

    /// Shows an alert and returns the index of the chosen button.
    var ask: (_ message: String, _ detail: String, _ buttons: [String]) -> Int = { message, detail, buttons in
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    /// Asks where to save an export.
    var chooseExportURL: (_ title: String, _ name: String) -> URL? = { title, name in
        let panel = NSSavePanel()
        panel.title = title; panel.nameFieldStringValue = name
        return panel.runModal() == .OK ? panel.url : nil
    }

    func duplicateEntry(_ requested: String) {
        do {
            guard let kind = section.kind, let name = try flushed(requested), var next = document else { return }
            let copy = try next.duplicate(kind, name: name)
            try stage(next)
            reveal(copy)
        } catch { errorMessage = error.localizedDescription }
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func requestReview(afterApplying action: (() -> Void)? = nil) {
        do {
            try requireRecoveryResolved()
            try flushEditor()
            guard let document else { throw ConfigError.invalid(parseIssue ?? "Create or import a configuration first.") }
            try document.validate()
            guard let snapshot else { return }
            guard try !store.hasChanged(snapshot) else { throw ConfigError.externalChange }
            afterApply = action
            showReview = true
        } catch {
            checkForExternalChange()
            errorMessage = error.localizedDescription
        }
    }

    func cancelReview() { showReview = false; afterApply = nil }

    func commit() {
        do {
            try requireRecoveryResolved()
            guard let document, let snapshot else { return }
            let result = try store.apply(document, over: snapshot, retention: retention)
            self.snapshot = result.snapshot
            noteRecentFile(result.snapshot.url)
            draftText = result.snapshot.text
            backupWarning = result.warning
            recoveryContents = result.recoveryContents
            statusMessage = result.warning == nil ? "Applied" : nil
            showReview = false
            clearHistory()
            refreshBackups()
            let action = afterApply; afterApply = nil
            // Keep the recovery export available if writing the backup failed.
            if result.warning == nil { action?() }
        } catch {
            // The alert waits behind a sheet, so Apply would seem to do nothing with Review still open.
            cancelReview()
            checkForExternalChange()
            errorMessage = error.localizedDescription
        }
    }

    private func requireRecoveryResolved() throws {
        guard recoveryContents == nil else {
            throw ConfigError.backupFailure("Export the previous configuration using Export Previous… before applying more changes. To discard it explicitly, close or reopen the configuration and choose Discard Previous Contents.")
        }
    }

    func resolvePendingChanges(then action: @escaping () -> Void) {
        if recoveryContents != nil {
            switch ask("Save the previous configuration before leaving?",
                       "The file was applied, but saving its backup failed. Export the previous contents to retain an undo point.",
                       ["Export Previous…", "Discard Previous Contents", "Cancel"]) {
            case 0:
                exportRecovery()
                if recoveryContents == nil { resolvePendingChanges(then: action) }
            case 1:
                recoveryContents = nil; backupWarning = nil
                resolvePendingChanges(then: action)
            default: break
            }
            return
        }
        guard hasPendingChanges else { action(); return }
        switch ask("Apply your pending changes?", "Review and apply them, discard them, or keep editing.", ["Review & Apply", "Discard Changes", "Cancel"]) {
        case 0: requestReview(afterApplying: action)
        case 1: discardDraft(); action()
        default: break
        }
    }

    func discardDraft() {
        _ = try? flushEditor()
        let original = snapshot?.text ?? ""
        if draftText != original { recordStep() }
        restore(original)
    }

    func openConfiguration() {
        resolvePendingChanges { [weak self] in
            let panel = NSOpenPanel()
            panel.title = "Open Configuration"
            panel.showsHiddenFiles = true
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url { self?.load(url) }
        }
    }

    func reload() {
        guard let url = snapshot?.url else { return }
        resolvePendingChanges { [weak self] in self?.load(url) }
    }

    func openRecent(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            setRecentFiles(recentFiles.filter { $0 != url })
            errorMessage = "\(displayPath(url)) no longer exists."
            return
        }
        resolvePendingChanges { [weak self] in self?.load(url) }
    }

    func clearRecentFiles() { setRecentFiles([]) }

    private func noteRecentFile(_ url: URL) {
        setRecentFiles(Array(([url] + recentFiles.filter { $0 != url }).prefix(Self.recentFilesLimit)))
    }

    private func setRecentFiles(_ files: [URL]) {
        recentFiles = files
        defaults.set(files.map(\.path), forKey: Self.recentFilesKey)
    }

    /// Runs when the app comes forward, since nothing else notices a file changing while it's in the background.
    func checkForExternalChange() {
        guard let snapshot else { return }
        fileChangedOnDisk = (try? store.hasChanged(snapshot)) ?? true
    }

    func toggleRawEditor() {
        do {
            try flushEditor()
            if showRaw { endRawSession(); showRaw = false; reselect(); return }
            clearEditor(); showRaw = true
        } catch { errorMessage = error.localizedDescription }
    }

    /// Find for the whole app: the YAML editor's find bar, or else the list's search.
    func find() {
        if showRaw { performFind(.showFindInterface); return }
        if columnVisibility == .detailOnly { columnVisibility = .doubleColumn }
        searchFocusRequest += 1
    }

    /// The text view reads the action from its sender's tag.
    func performFind(_ action: NSTextFinder.Action) {
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        rawEditor?.performTextFinderAction(sender)
    }

    var canImport: Bool { document != nil || hasNoConfiguration }

    /// Picks a file for the import sheet, then moves on to reviewing it.
    func chooseImportFile() throws {
        let panel = NSOpenPanel()
        panel.title = "Import Kubeconfig"
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try prepareImport(file: url)
    }

    func prepareImport(file url: URL) throws {
        guard let data = try LocalFileAccess().read(url), let yaml = String(data: data, encoding: .utf8) else { throw ConfigError.invalid("Choose a UTF-8 kubeconfig file.") }
        try prepareImport(yaml: yaml, directory: url.deletingLastPathComponent())
    }

    func prepareImport(yaml: String, directory: URL?) throws {
        try flushEditor()
        guard canImport else { throw ConfigError.invalid("Repair this configuration before merging an import.") }
        importPlan = try ImportPlan(target: document ?? .empty, incoming: KubeDocument(yaml: yaml), sourceDirectory: directory)
        showImportSource = false
        showImport = true
    }

    func acceptImport(_ plan: ImportPlan) throws {
        let merged = try plan.merged(into: document ?? .empty)
        try stage(merged, message: "Import staged")
        closeImport()
        selectSection(.contexts)
    }

    func closeImport() { showImport = false; importPlan = nil }

    func refreshBackups() {
        guard let snapshot else { return }
        do {
            let listing = try store.backups.records(for: snapshot.resolvedURL)
            records = listing.records
            damagedBackupCount = listing.damagedCount
            if !records.contains(where: { $0.id == selectedBackupID }) { selectedBackupID = records.first?.id }
        } catch {
            records = []; selectedBackupID = nil; damagedBackupCount = 0
            errorMessage = error.localizedDescription
        }
    }

    /// The backup's text for its preview, which also shows a file that isn't valid UTF-8.
    func backupPreview(_ backup: BackupSummary) throws -> String {
        guard let snapshot else { return "" }
        return String(decoding: try store.backups.record(backup, for: snapshot.resolvedURL).contents, as: UTF8.self)
    }

    func rollbackSelected() {
        guard let backup = selectedBackup, let snapshot else { return }
        resolvePendingChanges { [weak self] in
            guard let self else { return }
            do {
                let record = try self.store.backups.record(backup, for: snapshot.resolvedURL)
                let restored = try self.store.backups.rollbackText(record, for: snapshot.resolvedURL)
                // Do not modify snapshot: it still represents the live file against which Apply must compare.
                if restored != self.draftText { self.recordStep() }
                self.draftText = restored
                self.parseDraft()
                self.statusMessage = self.hasPendingChanges ? "Rollback staged" : nil
                self.selectSection(.contexts)
            } catch { self.errorMessage = error.localizedDescription }
        }
    }

    func exportDraft() {
        do {
            try flushEditor()
            try export(Data(draftText.utf8), title: "Export Draft", name: "kubeconfig-draft.yaml")
        } catch { errorMessage = error.localizedDescription }
    }

    func exportRecovery() {
        guard let recoveryContents else { return }
        do {
            if try export(recoveryContents, title: "Save Previous Configuration", name: "kubeconfig-previous.yaml") {
                self.recoveryContents = nil; backupWarning = nil
            }
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    private func export(_ data: Data, title: String, name: String) throws -> Bool {
        guard let url = chooseExportURL(title, name) else { return false }
        if url.standardizedFileURL.resolvingSymlinksInPath() == snapshot?.resolvedURL {
            throw ConfigError.invalid("Export to a different file. Use Apply to update the open configuration.")
        }
        try LocalFileAccess().writeAtomically(data, to: url)
        return true
    }

    func revealBackups() {
        guard let snapshot else { return }
        let folder = store.backups.location(for: snapshot.resolvedURL)
        if FileManager.default.fileExists(atPath: folder.path) { NSWorkspace.shared.open(folder) }
        else { statusMessage = "No backups yet" }
    }
}
