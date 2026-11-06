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

/// What views read several times per update, worked out once for each draft state.
private struct DraftEvaluation {
    let issues: [String]
    let changes: DraftChanges?
    let reviewCount: Int
    let preview: KubeDocument?
}

/// A draft in the undo history, and the active context it follows once restored, since switching leaves the file ahead of it.
private struct DraftStep {
    var text: String
    var context: String?
    var selection: EntrySelection?
}

private struct EntrySelection {
    let section: AppSection
    let names: Set<String>
}

/// One context's k9s, which keeps running while other entries are on screen.
struct K9sSession {
    enum Phase: Equatable {
        case running
        case missing
        /// It ended with an error, and the terminal stays up so its output can be read.
        case exited(Int32?)
    }

    let id = UUID()
    let contextName: String
    let resolvedFileURL: URL
    let terminal: K9sTerminal
    /// The file as k9s first read it, which later versions are compared with.
    let baseline: KubeDocument?
    let appearance: K9sAppearance
    var phase = Phase.running
    var freshness = ContextConnectionChange.unchanged
    var isExpanded = false
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
    @Published private(set) var selectedEntryNames: Set<String> = [] {
        didSet { if selectedEntryNames != oldValue { entrySelectionGeneration &+= 1 } }
    }
    @Published var search = "" {
        didSet {
            guard search != oldValue else { return }
            entrySelectionGeneration &+= 1
            guard section.kind != nil else { return }
            let visible = Set(visibleEntries.map(\.name))
            guard !selectedEntryNames.isSubset(of: visible) else { return }
            do {
                try flushEditor()
                applyEntrySelection(selectedEntryNames.intersection(visibleEntries.map(\.name)))
            } catch {
                search = oldValue
                errorMessage = error.localizedDescription
            }
        }
    }
    @Published var editor: EntryEditor? { didSet { evaluation = nil } }
    @Published var document: KubeDocument? { didSet { evaluation = nil } }
    @Published var draftText = ""
    @Published var snapshot: FileSnapshot? {
        didSet {
            diskDocument = snapshot.flatMap { $0.exists ? try? KubeDocument(yaml: $0.text) : nil }
            serializedDisk = (try? diskDocument?.serialized()) ?? snapshot?.text ?? ""
            fileChangedOnDisk = false
            refreshK9sFreshness(disk: diskDocument, fileIsGone: snapshot?.exists != true)
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
    @Published var columnVisibility: NavigationSplitViewVisibility {
        didSet { defaults.set(sidebarIsCollapsed, forKey: Self.sidebarCollapsedKey) }
    }
    /// Bumped to move focus to the list's search field.
    @Published var searchFocusRequest = 0
    @Published private(set) var recentFiles: [URL]
    @Published var showRaw = false {
        didSet { if showRaw != oldValue { entrySelectionGeneration &+= 1 } }
    }
    @Published var showReview = false
    @Published var showImport = false
    @Published var importPlan: ImportPlan?
    @Published var showImportSource = false
    @Published private(set) var contextExportPlan: ContextExportPlan?
    @Published private var confirmingDeletion = false
    @Published var wrapsYAML: Bool { didSet { defaults.set(wrapsYAML, forKey: Self.wrapsYAMLKey) } }
    @Published private(set) var k9sSessions: [String: K9sSession] = [:]
    var k9sSession: K9sSession? { selectedName.flatMap { k9sSessions[$0] } }
    /// Each session remembers its layout without touching the sidebar preference.
    var k9sIsExpanded: Bool {
        get { k9sSession?.isExpanded ?? false }
        set { if let name = k9sSession?.contextName { k9sSessions[name]?.isExpanded = newValue } }
    }
    @Published private var undoStack: [DraftStep] = []
    @Published private var redoStack: [DraftStep] = []
    @Published var rawCanUndo = false
    @Published var rawCanRedo = false
    private var loadedEditor: EntryEditor? { didSet { evaluation = nil } }
    private var afterApply: (() -> Void)?
    private var diskDocument: KubeDocument? { didSet { evaluation = nil } }
    /// What each draft state is compared with, which is too slow to work out on every keystroke.
    private(set) var serializedDisk = ""
    private var evaluation: DraftEvaluation?
    /// The draft when YAML editing began. The whole session becomes one undo step.
    private var rawSessionStart: String?
    private var entrySelectionGeneration: UInt64 = 0
    private static let historyLimit = 100
    private static let wrapsYAMLKey = "wrapsYAML"
    private static let sidebarCollapsedKey = "sidebarCollapsed"
    private static let recentFilesKey = "recentConfigurations"
    private static let recentFilesLimit = 10
    weak var rawEditor: NSTextView?
    weak var window: NSWindow?
    let store: ConfigurationStore
    let defaults: UserDefaults
    private(set) var launchOptions: LaunchOptions?
    var makeK9sTerminal: () -> K9sTerminal = { K9sTerminalProcess() }
    var findLoginPath: () async -> String? = { await LoginShell.path() }
    var isK9sExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    var k9sEnvironment = ProcessInfo.processInfo.environment
    var k9sAppearance: () -> K9sAppearance = {
        NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
    private var k9sLaunchTasks: [String: Task<Void, Never>] = [:]
    var k9sLaunchTask: Task<Void, Never>? { selectedName.flatMap { k9sLaunchTasks[$0] } }
    /// Kept for the run, since each lookup starts the user's shell. Try Again looks again.
    private var k9sLoginPath: String?
    private var k9sFocusRequests: Set<UUID> = []

    init(store: ConfigurationStore = ConfigurationStore(), defaults: UserDefaults = .standard, initialURL: URL? = nil,
         arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.store = store
        self.defaults = defaults
        defaults.register(defaults: [BackupRetention.key: BackupRetention.defaultCount,
                                     ContextSwitching.immediateKey: ContextSwitching.immediateByDefault])
        wrapsYAML = defaults.bool(forKey: Self.wrapsYAMLKey)
        columnVisibility = defaults.bool(forKey: Self.sidebarCollapsedKey) ? .detailOnly : .all
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
    var sheetIsOpen: Bool { showReview || showImportSource || showImport || contextExportPlan != nil || confirmingDeletion }
    var hasMultipleSelection: Bool { section.kind != nil && selectedEntryNames.count > 1 }
    var canRequestSelectionDeletion: Bool { hasMultipleSelection && !showRaw && document != nil && !sheetIsOpen }
    var selectionDeleteTitle: String { "Delete \(selectedEntryNames.count) Items" }
    var canExportContexts: Bool {
        section == .contexts && !showRaw && document != nil && !selectedEntryNames.isEmpty && !sheetIsOpen
    }
    var contextExportTitle: String {
        let count = selectedEntryNames.count
        return count == 0 ? "Export Selected Contexts" : "Export \(count) Selected Context\(count == 1 ? "" : "s")"
    }
    /// No file, or a blank one such as `touch ~/.kube/config` leaves, so there's nothing to edit yet.
    var hasNoConfiguration: Bool {
        snapshot.map { draftText == $0.text && $0.text.allSatisfy(\.isWhitespace) } ?? false
    }
    var validationIssues: [String] { evaluated.issues }
    var canApply: Bool { hasPendingChanges && validationIssues.isEmpty }
    var pendingChanges: DraftChanges? { evaluated.changes }
    /// The changes Review will step through, which can differ from the entries that changed.
    var reviewCount: Int { evaluated.reviewCount }
    /// Undo stays off while k9s is up, since the draft it would change isn't on screen.
    var canUndo: Bool { !k9sIsVisible && (!undoStack.isEmpty || formIsDirty || rawCanUndo || hasRawSessionEdits) }
    var canRedo: Bool { !redoStack.isEmpty || rawCanRedo }
    var canRedoCommand: Bool { !k9sIsVisible && (canRedo || fieldCanRedo) }
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
    var sidebarIsCollapsed: Bool { columnVisibility == .detailOnly }
    func toggleSidebar() { columnVisibility = sidebarIsCollapsed ? .all : .detailOnly }
    var k9sIsVisible: Bool {
        guard let k9sSession else { return false }
        return section == .contexts && !showRaw && selectedName == k9sSession.contextName && document != nil
    }
    var k9sFillsWindow: Bool { k9sIsVisible && k9sIsExpanded }
    /// What the window shows, which Expand overrides without changing the preference.
    var displayedColumnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(get: { [self] in k9sFillsWindow ? .detailOnly : columnVisibility },
                set: { [self] in if !k9sFillsWindow { columnVisibility = $0 } })
    }
    private var hasRawSessionEdits: Bool { rawSessionStart.map { $0 != draftText } ?? false }
    private var evaluated: DraftEvaluation {
        if let evaluation { return evaluation }
        let preview = previewDocument
        let reviewCount = preview.flatMap { try? ConfigurationDiff.changeCount(serializedBefore: serializedDisk, after: $0) } ?? 0
        let result = DraftEvaluation(issues: parseIssue.map { [$0] } ?? preview?.validationIssues ?? [],
                                     changes: preview?.changes(from: diskDocument), reviewCount: reviewCount, preview: preview)
        evaluation = result
        return result
    }
    /// The draft with any form edit that hasn't been committed yet, so counts stay right while typing.
    private var previewDocument: KubeDocument? {
        guard let editor, formIsDirty, var next = document else { return document }
        guard (try? next.update(editor.kind, originalName: editor.originalName, name: editor.name, fields: changedFields(editor))) != nil else { return document }
        return diskDocument.map(next.adoptingKeyOrder) ?? next
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
    /// Why k9s can't open a context. It reads the file, so it would miss pending changes to what the context connects with.
    func k9sBlockReason(_ name: String?) -> String? {
        guard !sheetIsOpen, !showRaw, section == .contexts, !hasMultipleSelection, let name else { return "Select a single context" }
        // A bad name can't be previewed, and flushing it would raise an alert on every click behind the terminal.
        if nameError != nil, name == editor?.originalName { return "Fix the name to open in k9s" }
        guard let preview = evaluated.preview else { return "Repair the configuration to open in k9s" }
        return KubeDocument.connectionChange(ofContext: name, from: preview, to: diskDocument) == .unchanged ? nil : "Apply changes to open in k9s"
    }
    var k9sRestartBlockReason: String? {
        guard let k9sSession else { return "k9s isn’t open" }
        return k9sSession.freshness == .removed ? "This context is no longer in the file" : k9sBlockReason(k9sSession.contextName)
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

    /// Runs an action, showing whatever it throws in the alert.
    private func reportingErrors(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }

    func load(_ url: URL) {
        reportingErrors {
            let loaded = try store.load(url)
            if k9sSessions.values.contains(where: { $0.resolvedFileURL != loaded.resolvedURL }) { closeAllK9s() }
            let visibleK9sContext = k9sIsVisible ? k9sSession?.contextName : nil
            snapshot = loaded
            if loaded.exists { noteRecentFile(loaded.url) }
            draftText = loaded.text
            parseDraft()
            clearEditor(); selectedName = nil; selectedEntryNames = []; search = ""
            showRaw = false; statusMessage = nil; backupWarning = nil
            clearHistory()
            selectFirstEntry()
            refreshBackups()
            closeK9sForRemovedContexts()
            if let name = visibleK9sContext, k9sSessions[name] != nil { selectEntry(name) }
        }
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

    private func showEditor(for entry: ConfigEntry?) {
        // A clean form doesn't affect the evaluation, and rebuilding it took 11 ms per click at 300 entries.
        let kept = formIsDirty ? nil : evaluation
        editor = entry.map(EntryEditor.init)
        loadedEditor = editor
        evaluation = kept
    }

    private func clearEditor() { showEditor(for: nil) }

    /// The named entry in the current section, if it still exists.
    private func sectionEntry(named name: String?) -> ConfigEntry? {
        guard let name, let kind = section.kind else { return nil }
        return document?.entry(kind, named: name)
    }

    func stage(_ next: KubeDocument, message: String? = nil, undoSelection: Set<String>? = nil) throws {
        let next = diskDocument.map(next.adoptingKeyOrder) ?? next
        let serialized = try next.serialized()
        // Keep the file's own text when nothing differs, so changing a value back leaves nothing to apply.
        let unchanged = diskDocument?.isEquivalent(to: next) == true
        let text = unchanged ? (snapshot?.text ?? serialized) : serialized
        if text != draftText { recordStep(undoSelection: undoSelection) }
        document = unchanged ? diskDocument : next
        draftText = text
        parseIssue = nil
        parseIssueLine = nil
        statusMessage = text == snapshot?.text ? nil : message
    }

    /// Saves the current draft as the state Undo returns to. Call before changing it.
    private func recordStep(undoSelection: Set<String>? = nil) {
        endRawSession()
        pushUndo(draftText, selection: undoSelection.map { EntrySelection(section: section, names: $0) })
        redoStack.removeAll()
    }

    private func pushUndo(_ text: String, selection: EntrySelection? = nil) {
        undoStack.append(DraftStep(text: text, selection: selection))
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
        redoStack.append(DraftStep(text: draftText, selection: previous.selection))
        restore(following(previous), selection: previous.selection)
    }

    func redo() {
        if showRaw, let rawEditor, rawCanRedo {
            rawEditor.undoManager?.redo()
            return
        }
        // An unfinished form edit is a new change, so committing it empties the redo stack.
        guard (try? flushEditor()) != nil, let next = redoStack.popLast() else { return }
        endRawSession()
        pushUndo(draftText, selection: next.selection)
        restore(following(next))
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

    private func restore(_ text: String, selection: EntrySelection? = nil) {
        let previous = document
        draftText = text
        parseDraft()
        statusMessage = nil
        clearEditor()
        if let selection {
            section = selection.section
            search = ""
            applyEntrySelection(selection.names.intersection(visibleEntries.map(\.name)))
            return
        }
        guard !showRaw else { return }
        let changed = section.kind.flatMap { kind -> String? in
            let old = previous?.entriesByName(kind) ?? [:]
            return document?.entries(kind).filter { old[$0.name] != $0 }.map(\.name)
                .min { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        reselect(changed)
    }

    /// Selects `preferred`, or else keeps the current entry if it still exists.
    private func reselect(_ preferred: String? = nil) {
        if preferred == nil, hasMultipleSelection {
            let remaining = selectedEntryNames.intersection(visibleEntries.map(\.name))
            if !remaining.isEmpty { selectEntries(remaining); return }
        }
        if let target = preferred ?? sectionEntry(named: selectedName)?.name { reveal(target) } else { selectFirstEntry() }
    }

    /// Selects an entry, clearing a search that would hide it from the list.
    private func reveal(_ name: String) {
        clearSearchIfHiding(name)
        selectEntry(name)
    }

    private func clearSearchIfHiding(_ name: String) {
        if !visibleEntries.contains(where: { $0.name == name }) { search = "" }
    }

    private func changedFields(_ editor: EntryEditor) -> [String: String] {
        editor.fields.filter { key, value in loadedEditor?.fields[key] != value }
    }

    /// Commits the form when a field is finished. A bad name stays in the form with its error beside it.
    func commitForm() {
        guard formIsDirty, nameError == nil else { return }
        reportingErrors { try flushEditor() }
    }

    @discardableResult
    func flushEditor() throws -> Bool {
        guard let editor, editor != loadedEditor else { return false }
        guard var next = document else { throw ConfigError.invalid("Repair the configuration in YAML before editing entries.") }
        try next.update(editor.kind, originalName: editor.originalName, name: editor.name, fields: changedFields(editor))
        try stage(next)
        let name = editor.name.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedName = name
        selectedEntryNames = [name]
        showEditor(for: next.entry(editor.kind, named: name))
        clearSearchIfHiding(name)
        return true
    }

    func selectSection(_ next: AppSection) {
        reportingErrors {
            try flushEditor()
            endRawSession()
            selectedEntryNames = []
            section = next; search = ""; showRaw = false
            clearEditor(); selectedName = nil
            if next == .backups { refreshBackups() } else { selectFirstEntry() }
        }
    }

    func selectEntry(_ name: String?) {
        reportingErrors {
            try flushEditor()
            selectedName = name
            entrySelectionGeneration &+= 1
            selectedEntryNames = name.map { [$0] } ?? []
            showEditor(for: sectionEntry(named: name))
        }
    }

    func selectFirstEntry() { selectEntry(visibleEntries.first?.name) }

    /// AppKit can report selection during a SwiftUI update. Keep only the latest still-current request.
    func queueEntrySelection(_ names: Set<String>) {
        entrySelectionGeneration &+= 1
        let generation = entrySelectionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.entrySelectionGeneration,
                  self.section.kind != nil, !self.showRaw, !self.sheetIsOpen else { return }
            self.selectEntries(names)
        }
    }

    func selectEntries(_ names: Set<String>) {
        guard section.kind != nil, names != selectedEntryNames else { return }
        reportingErrors {
            let originalName = editor?.originalName
            try flushEditor()
            var names = names
            // A focus change can commit a rename while the list is still sending its old selection.
            if let originalName, let renamed = editor?.originalName, originalName != renamed,
               names.remove(originalName) != nil { names.insert(renamed) }
            applyEntrySelection(names.intersection(visibleEntries.map(\.name)))
        }
    }

    private func applyEntrySelection(_ names: Set<String>) {
        entrySelectionGeneration &+= 1
        selectedEntryNames = names
        selectedName = names.count == 1 ? names.first : nil
        showEditor(for: showRaw ? nil : sectionEntry(named: selectedName))
    }

    func createConfiguration() {
        reportingErrors { try stage(.empty); selectFirstEntry() }
    }

    func addEntry() {
        guard let kind = section.kind else { return }
        reportingErrors {
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
        }
    }

    /// Flushes the form and returns the entry's current name, since the flush may have renamed it.
    private func flushed(_ name: String?) throws -> String? {
        let isEditing = name == editor?.originalName
        try flushEditor()
        return isEditing ? selectedName : name
    }

    func makeActive(_ name: String? = nil) {
        guard !hasMultipleSelection else { return }
        reportingErrors {
            guard let name = try flushed(name ?? selectedName) else { return }
            try switchContext(to: name, stagedMessage: "Context switch staged")
        }
    }

    func clearActive() {
        guard !hasMultipleSelection else { return }
        reportingErrors {
            try flushEditor()
            try switchContext(to: "", stagedMessage: "Active context cleared")
        }
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
        undoStack = undoStack.map { var step = $0; step.context = name; return step }
        redoStack = redoStack.map { var step = $0; step.context = name; return step }
        document = next
        draftText = draft(text, following: name)
        statusMessage = nil
    }

    private func following(_ step: DraftStep) -> String {
        step.context.map { draft(step.text, following: $0) } ?? step.text
    }

    /// Keeps the file's own text when nothing differs, as `stage` does, so a matching draft leaves nothing to apply.
    private func draft(_ text: String, following name: String) -> String {
        let patched = KubeDocument.settingCurrentContext(name, in: text) ?? text
        guard let parsed = try? KubeDocument(yaml: patched), diskDocument?.isEquivalent(to: parsed) == true else { return patched }
        return snapshot?.text ?? patched
    }

    func deleteEntry(_ requested: String? = nil) {
        guard !hasMultipleSelection else { return }
        reportingErrors {
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
        }
    }

    func requestSelectionDeletion() {
        guard canRequestSelectionDeletion else { return }
        reportingErrors {
            try flushEditor()
            guard let kind = section.kind, let original = document else { return }
            let names = selectedEntryNames.intersection(visibleEntries.map(\.name))
            guard names.count > 1 else { return }
            let originalSection = section
            let url = snapshot?.url
            entrySelectionGeneration &+= 1
            confirmingDeletion = true
            defer {
                confirmingDeletion = false
                entrySelectionGeneration &+= 1
            }
            var next = original
            do { try next.delete(kind, names: names) } catch {
                _ = ask("Cannot delete selected items", error.localizedDescription, ["OK"])
                return
            }
            let choice = ask("Delete \(names.count) \(kind.title.lowercased())?",
                             "Changes take effect after Apply. You can undo this deletion.", ["Delete", "Cancel"])
            guard choice == 0, section == originalSection, document == original, snapshot?.url == url else { return }
            try stage(next, undoSelection: names)
            applyEntrySelection([])
            selectFirstEntry()
        }
    }

    func openK9s(_ requested: String? = nil) {
        guard let name = requested ?? selectedName, k9sBlockReason(name) == nil else { return }
        if selectedName != name || selectedEntryNames != [name] { selectEntry(name) }
        guard selectedName == name, let snapshot else { return }
        if let session = k9sSessions[name] {
            let view = session.terminal.view
            if let window = view.window { window.makeFirstResponder(view) } else { k9sFocusRequests.insert(session.id) }
        } else {
            startK9s(context: name, snapshot: snapshot)
        }
    }

    func restartK9s() {
        guard let session = k9sSession, k9sRestartBlockReason == nil, let snapshot else { return }
        if session.phase == .missing { k9sLoginPath = nil }
        endK9s(context: session.contextName)
        startK9s(context: session.contextName, snapshot: snapshot, isExpanded: session.isExpanded)
    }

    func closeK9s() {
        guard let name = k9sSession?.contextName else { return }
        endK9s(context: name)
    }

    func closeAllK9s() {
        for name in Array(k9sSessions.keys) { endK9s(context: name) }
    }

    private func endK9s(context name: String) {
        k9sLaunchTasks.removeValue(forKey: name)?.cancel()
        // Remove ownership first, so a late callback cannot change a replacement session.
        if let session = k9sSessions.removeValue(forKey: name) {
            k9sFocusRequests.remove(session.id)
            session.terminal.onExit = nil
            session.terminal.stop()
        }
    }

    /// Selection moves on from contexts that are gone, leaving no way to close their sessions.
    /// A file that needs repair says nothing about the contexts, unlike one that's missing or blank.
    private func closeK9sForRemovedContexts() {
        guard parseIssue == nil else { return }
        for name in Array(k9sSessions.keys) where document?.entry(.contexts, named: name) == nil {
            endK9s(context: name)
        }
    }

    /// Only an explicit Open request takes focus, and only in the pane for that session.
    func takeK9sFocusRequest(for id: UUID? = nil) -> Bool {
        guard k9sIsVisible, let session = k9sSession, id == nil || session.id == id else { return false }
        return k9sFocusRequests.remove(session.id) != nil
    }

    private func startK9s(context name: String, snapshot: FileSnapshot, isExpanded: Bool = false) {
        let terminal = makeK9sTerminal()
        let baseline = latestDisk(changed: fileHasChanged).document
        let kubeconfig = snapshot.url
        let cluster = baseline?.entry(.contexts, named: name)?.value("cluster") ?? ""
        let appearance = k9sAppearance()
        let session = K9sSession(contextName: name, resolvedFileURL: snapshot.resolvedURL, terminal: terminal,
                                 baseline: baseline, appearance: appearance, isExpanded: isExpanded)
        let id = session.id
        k9sSessions[name] = session
        k9sFocusRequests.insert(id)
        terminal.onExit = { [weak self] code in self?.k9sExited(context: name, id: id, code: code) }
        k9sLaunchTasks[name] = Task { [weak self, findLoginPath, isK9sExecutable, k9sEnvironment, k9sLoginPath] in
            let loginPath: String?
            if let k9sLoginPath { loginPath = k9sLoginPath } else { loginPath = await findLoginPath() }
            guard let self, !Task.isCancelled, self.k9sSessions[name]?.id == id else { return }
            self.k9sLoginPath = loginPath
            if let launch = K9sLaunch(kubeconfig: kubeconfig, context: name, cluster: cluster, appearance: appearance,
                                      loginPath: loginPath, inherited: k9sEnvironment, isExecutable: isK9sExecutable) {
                terminal.start(launch)
            } else {
                self.k9sSessions[name]?.phase = .missing
            }
        }
    }

    private func k9sExited(context name: String, id: UUID, code: Int32?) {
        guard k9sSessions[name]?.id == id else { return }
        if code == 0 { endK9s(context: name) } else { k9sSessions[name]?.phase = .exited(code) }
    }

    private var fileHasChanged: Bool { snapshot.map { (try? store.hasChanged($0)) ?? true } ?? false }

    /// The file as it is now, which can be newer than the loaded snapshot. The document is nil if the file is gone or unreadable.
    private func latestDisk(changed: Bool) -> (document: KubeDocument?, isGone: Bool) {
        guard changed, let snapshot else { return (diskDocument, false) }
        guard let loaded = try? store.load(snapshot.url) else { return (nil, false) }
        return (loaded.exists ? try? KubeDocument(yaml: loaded.text) : nil, !loaded.exists)
    }

    /// A file that can't be read says nothing about the context, so that only counts as a change.
    private func refreshK9sFreshness(disk: KubeDocument?, fileIsGone: Bool) {
        var updated = k9sSessions
        var didChange = false
        for (name, session) in k9sSessions {
            let freshness: ContextConnectionChange = disk != nil || fileIsGone
                ? KubeDocument.connectionChange(ofContext: name, from: session.baseline, to: disk)
                : .changed
            if freshness != session.freshness {
                updated[name]?.freshness = freshness
                didChange = true
            }
        }
        if didChange { k9sSessions = updated }
    }

    /// Shows an alert and returns the index of the chosen button.
    var ask: (_ message: String, _ detail: String, _ buttons: [String]) -> Int = { message, detail, buttons in
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    /// Asks which file to open.
    var chooseFile: (_ title: String) -> URL? = { title in
        let panel = NSOpenPanel()
        panel.title = title; panel.showsHiddenFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Asks where to save an export.
    var chooseExportURL: (_ title: String, _ name: String) -> URL? = { title, name in
        let panel = NSSavePanel()
        panel.title = title; panel.nameFieldStringValue = name
        return panel.runModal() == .OK ? panel.url : nil
    }

    func duplicateEntry(_ requested: String) {
        guard !hasMultipleSelection else { return }
        reportingErrors {
            guard let kind = section.kind, let name = try flushed(requested), var next = document else { return }
            let copy = try next.duplicate(kind, name: name)
            try stage(next)
            reveal(copy)
        }
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
            closeK9sForRemovedContexts()
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
            if let url = self?.chooseFile("Open Configuration") { self?.load(url) }
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
        guard snapshot != nil else { return }
        let changed = fileHasChanged
        fileChangedOnDisk = changed
        if !k9sSessions.isEmpty {
            let disk = latestDisk(changed: changed)
            refreshK9sFreshness(disk: disk.document, fileIsGone: disk.isGone)
        }
    }

    func toggleRawEditor() {
        reportingErrors {
            try flushEditor()
            if showRaw { endRawSession(); showRaw = false; reselect(); return }
            clearEditor(); showRaw = true
        }
    }

    /// Find for the whole app: the YAML editor's find bar, or else the list's search.
    func find() {
        if showRaw { performFind(.showFindInterface); return }
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
        guard let url = chooseFile("Import Kubeconfig") else { return }
        try prepareImport(file: url)
    }

    func prepareImport(file url: URL) throws {
        // Bounded, because a dropped file can be anything, including a pipe that would never finish reading.
        guard let data = try? LocalFileAccess().read(url, maximumByteCount: KubeDocument.maximumByteCount),
              let yaml = String(data: data, encoding: .utf8) else {
            throw ConfigError.invalid("Choose a UTF-8 kubeconfig file of at most 16 MB.")
        }
        try prepareImport(yaml: yaml, directory: url.deletingLastPathComponent())
    }

    @discardableResult
    func importDroppedFiles(_ urls: [URL]) -> Bool {
        guard !sheetIsOpen, errorMessage == nil, window?.attachedSheet == nil else { return false }
        guard urls.count == 1, let url = urls.first, url.isFileURL else {
            errorMessage = "Drop one kubeconfig file at a time."
            return false
        }
        do {
            try prepareImport(file: url)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
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
        reportingErrors {
            // Read first, since applying pending changes can prune this very backup.
            let record = try store.backups.record(backup, for: snapshot.resolvedURL)
            let restored = try store.backups.rollbackText(record, for: snapshot.resolvedURL)
            resolvePendingChanges { [weak self] in
                guard let self else { return }
                // Do not modify snapshot: it still represents the live file against which Apply must compare.
                if restored != self.draftText { self.recordStep() }
                self.draftText = restored
                self.parseDraft()
                self.statusMessage = self.hasPendingChanges ? "Rollback staged" : nil
                self.selectSection(.contexts)
            }
        }
    }

    func exportDraft() {
        reportingErrors {
            try flushEditor()
            try export(Data(draftText.utf8), title: "Export Draft", name: "kubeconfig-draft.yaml")
        }
    }

    func requestContextExport() {
        guard canExportContexts else { return }
        reportingErrors {
            try flushEditor()
            guard let document, let snapshot else { return }
            let names = selectedEntryNames.intersection(visibleEntries.map(\.name))
            contextExportPlan = try ContextExportPlan(document: document, contextNames: names,
                                                     sourceDirectory: snapshot.url.deletingLastPathComponent())
        }
    }

    func closeContextExport() { contextExportPlan = nil }

    /// Saves exactly the reviewed snapshot, even if an external credential file has changed since preview.
    func saveContextExport() throws {
        guard let plan = contextExportPlan else { return }
        if try export(Data(plan.yaml.utf8), title: "Export Selected Contexts", name: "kubeconfig-export.yaml",
                      protecting: Array(plan.sourceFiles)) {
            closeContextExport()
        }
    }

    func exportRecovery() {
        guard let recoveryContents else { return }
        reportingErrors {
            if try export(recoveryContents, title: "Save Previous Configuration", name: "kubeconfig-previous.yaml") {
                self.recoveryContents = nil; backupWarning = nil
            }
        }
    }

    @discardableResult
    private func export(_ data: Data, title: String, name: String, protecting sources: [URL] = []) throws -> Bool {
        guard let url = chooseExportURL(title, name) else { return false }
        let destination = url.standardizedFileURL
        let resolved = destination.resolvingSymlinksInPath()
        let openFiles = [snapshot?.url, snapshot?.resolvedURL].compactMap { $0?.standardizedFileURL }
        if openFiles.contains(where: { $0 == destination || $0.resolvingSymlinksInPath() == resolved }) {
            throw ConfigError.invalid("Export to a different file. Use Apply to update the open configuration.")
        }
        if sources.contains(where: { $0.standardizedFileURL == destination || $0.resolvingSymlinksInPath() == resolved }) {
            throw ConfigError.invalid("Export to a different file. A referenced credential file cannot be replaced by the export.")
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
