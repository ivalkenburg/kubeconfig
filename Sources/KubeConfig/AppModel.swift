import AppKit
import Combine
import KubeConfigCore
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case contexts, clusters, users, backups
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var kind: EntryKind? { EntryKind(rawValue: rawValue) }
    var symbol: String { kind?.symbol ?? "clock.arrow.circlepath" }
}

struct EntryEditor: Equatable {
    var kind: EntryKind
    var originalName: String?
    var name: String
    var fields: [String: String]

    static func keys(_ kind: EntryKind) -> [String] {
        switch kind {
        case .contexts: return ["cluster", "user", "namespace"]
        case .clusters: return ["server", "certificate-authority", "tls-server-name", "proxy-url"]
        case .users: return ["username", "password", "token", "client-certificate", "client-key"]
        }
    }

    init(kind: EntryKind, entry: ConfigEntry?) {
        self.kind = kind
        originalName = entry?.name
        name = entry?.name ?? ""
        fields = Dictionary(uniqueKeysWithValues: Self.keys(kind).map { ($0, entry?.value($0) ?? "") })
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var section: AppSection = .contexts
    @Published var selectedName: String?
    @Published var search = ""
    @Published var editor: EntryEditor?
    @Published var document: KubeDocument?
    @Published var draftText = ""
    @Published var snapshot: FileSnapshot?
    @Published private(set) var appliedContext = ""
    @Published var parseIssue: String?
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var backupWarning: String?
    @Published var recoveryContents: Data?
    @Published var records: [BackupRecord] = []
    @Published var selectedBackupID: String?
    @Published var showRaw = false
    @Published var showReview = false
    @Published var showImport = false
    @Published var importPlan: ImportPlan?
    @Published var showPaste = false
    @Published var revealedSecrets = false
    private var loadedEditor: EntryEditor?
    private var afterApply: (() -> Void)?
    let store: ConfigurationStore
    let defaults: UserDefaults
    private(set) var launchOptions: LaunchOptions?

    init(store: ConfigurationStore = ConfigurationStore(), defaults: UserDefaults = .standard, initialURL: URL? = nil,
         arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.store = store
        self.defaults = defaults
        defaults.register(defaults: ["backupRetention": 10])
        do {
            let options = try LaunchOptions(arguments: arguments)
            launchOptions = options
            load(initialURL ?? options.configurationURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kube/config"))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var retention: Int { min(1000, max(0, defaults.integer(forKey: "backupRetention"))) }
    var hasPendingChanges: Bool { draftText != (snapshot?.text ?? "") || editor != loadedEditor }
    var needsAttentionBeforeLeaving: Bool { hasPendingChanges || recoveryContents != nil }
    var formIsDirty: Bool { editor != loadedEditor }
    var missingFile: Bool { snapshot?.exists == false && draftText.isEmpty }
    var validationIssues: [String] { parseIssue.map { [$0] } ?? document?.validationIssues ?? [] }
    var selectedBackup: BackupRecord? { visibleBackups.first { $0.id == selectedBackupID } }
    var visibleBackups: [BackupRecord] {
        guard !search.isEmpty else { return records }
        return records.filter { record in
            [record.createdAt.formatted(.dateTime.year().month(.wide).day().hour().minute().second()),
             record.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute().second()),
             record.createdAt.ISO8601Format()].contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }
    var visibleEntries: [ConfigEntry] {
        guard let kind = section.kind else { return [] }
        return (document?.entries(kind) ?? []).filter { entry in
            search.isEmpty || [entry.name, entry.value("cluster"), entry.value("namespace"), entry.value("server")].contains { $0.localizedCaseInsensitiveContains(search) }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func load(_ url: URL) {
        do {
            let loaded = try store.load(url)
            snapshot = loaded
            draftText = loaded.text
            parseDraft()
            appliedContext = document?.currentContext ?? ""
            editor = nil; loadedEditor = nil; selectedName = nil
            showRaw = false; revealedSecrets = false; statusMessage = nil; backupWarning = nil
            selectFirstEntry()
            refreshBackups()
        } catch { errorMessage = error.localizedDescription }
    }

    func parseDraft() {
        if draftText.isEmpty && snapshot?.exists == false { document = nil; parseIssue = nil; return }
        do { document = try KubeDocument(yaml: draftText); parseIssue = nil }
        catch { document = nil; parseIssue = error.localizedDescription }
    }

    func editRaw(_ text: String) {
        draftText = text
        editor = nil; loadedEditor = nil
        statusMessage = nil
        parseDraft()
    }

    func stage(_ next: KubeDocument, message: String? = nil) throws {
        let text = try next.serialized()
        document = next
        draftText = text
        parseIssue = nil
        statusMessage = message
    }

    @discardableResult
    func flushEditor() throws -> Bool {
        guard let editor, editor != loadedEditor else { return false }
        guard var next = document else { throw ConfigError.invalid("Repair the configuration in YAML before editing entries.") }
        let changedFields = editor.fields.filter { key, value in loadedEditor?.fields[key] != value }
        try next.update(editor.kind, originalName: editor.originalName, name: editor.name, fields: changedFields)
        try stage(next)
        let name = editor.name.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedName = name
        self.editor = EntryEditor(kind: editor.kind, entry: next.entry(editor.kind, named: name))
        loadedEditor = self.editor
        return true
    }

    func selectSection(_ next: AppSection) {
        do {
            try flushEditor()
            section = next; search = ""; showRaw = false; revealedSecrets = false
            editor = nil; loadedEditor = nil; selectedName = nil
            if next == .backups { refreshBackups() } else { selectFirstEntry() }
        } catch { errorMessage = error.localizedDescription }
    }

    func selectEntry(_ name: String?) {
        do {
            try flushEditor()
            selectedName = name
            revealedSecrets = false
            if let kind = section.kind, let name, let entry = document?.entry(kind, named: name) {
                editor = EntryEditor(kind: kind, entry: entry)
                loadedEditor = editor
            } else { editor = nil; loadedEditor = nil }
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
            var next = document ?? .empty
            var name = "new-\(kind.singular)", suffix = 2
            while next.entry(kind, named: name) != nil { name = "new-\(kind.singular)-\(suffix)"; suffix += 1 }
            var fields: [String: String] = [:]
            if kind == .contexts {
                fields["cluster"] = next.entries(.clusters).first?.name ?? ""
                fields["user"] = next.entries(.users).first?.name ?? ""
            }
            try next.update(kind, originalName: nil, name: name, fields: fields)
            try stage(next)
            selectEntry(name)
        } catch { errorMessage = error.localizedDescription }
    }

    func makeActive() {
        do {
            try flushEditor()
            guard let selectedName, var next = document else { return }
            try next.setCurrentContext(selectedName)
            try stage(next, message: "Context switch staged. Apply to update your CLI defaults.")
        } catch { errorMessage = error.localizedDescription }
    }

    func clearActive() {
        do {
            try flushEditor()
            guard var next = document else { return }
            try next.setCurrentContext("")
            try stage(next, message: "Clearing the active context is staged.")
        } catch { errorMessage = error.localizedDescription }
    }

    func deleteSelected() {
        do {
            try flushEditor()
            guard let kind = section.kind, let selectedName, var next = document else { return }
            let references = next.referencingContexts(kind, name: selectedName)
            guard references.isEmpty else { throw ConfigError.referenced(selectedName, references) }
            let alert = NSAlert()
            alert.messageText = "Delete ‘\(selectedName)’?"
            alert.informativeText = kind == .contexts && next.currentContext == selectedName
                ? "This is the active context. Deleting it will explicitly clear the active context. The change takes effect after Apply."
                : "The deletion is staged until you Apply."
            alert.addButton(withTitle: kind == .contexts && next.currentContext == selectedName ? "Delete & Clear Active" : "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if kind == .contexts && next.currentContext == selectedName { try next.setCurrentContext("") }
            try next.delete(kind, name: selectedName)
            editor = nil; loadedEditor = nil; self.selectedName = nil
            try stage(next)
            selectFirstEntry()
        } catch { errorMessage = error.localizedDescription }
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
        } catch { errorMessage = error.localizedDescription }
    }

    func cancelReview() { showReview = false; afterApply = nil }

    func commit() {
        do {
            try requireRecoveryResolved()
            guard let document, let snapshot else { return }
            let result = try store.apply(document, over: snapshot, retention: retention)
            self.snapshot = result.snapshot
            draftText = result.snapshot.text
            appliedContext = document.currentContext
            backupWarning = result.warning
            recoveryContents = result.recoveryContents
            statusMessage = result.warning == nil ? "Applied. Your configuration is up to date." : nil
            showReview = false
            refreshBackups()
            let action = afterApply; afterApply = nil
            // Keep the recovery export available if writing the backup failed.
            if result.warning == nil { action?() }
        } catch { errorMessage = error.localizedDescription }
    }

    private func requireRecoveryResolved() throws {
        guard recoveryContents == nil else {
            throw ConfigError.backupFailure("Export the previous configuration using Export Previous… before applying more changes. To discard it explicitly, close or reopen the configuration and choose Discard Previous Contents.")
        }
    }

    func resolvePendingChanges(then action: @escaping () -> Void) {
        if recoveryContents != nil {
            let alert = NSAlert()
            alert.messageText = "Save the previous configuration before leaving?"
            alert.informativeText = "The file was applied, but saving its backup failed. Export the previous contents to retain an undo point."
            alert.addButton(withTitle: "Export Previous…")
            alert.addButton(withTitle: "Discard Previous Contents")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                exportRecovery()
                if recoveryContents == nil { resolvePendingChanges(then: action) }
            case .alertSecondButtonReturn:
                recoveryContents = nil; backupWarning = nil
                resolvePendingChanges(then: action)
            default: break
            }
            return
        }
        guard hasPendingChanges else { action(); return }
        let alert = NSAlert()
        alert.messageText = "Apply your pending changes?"
        alert.informativeText = "Review and apply them, discard them, or keep editing."
        alert.addButton(withTitle: "Review & Apply")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: requestReview(afterApplying: action)
        case .alertSecondButtonReturn: discardDraft(); action()
        default: break
        }
    }

    func discardDraft() {
        draftText = snapshot?.text ?? ""
        parseDraft()
        editor = nil; loadedEditor = nil; selectedName = nil
        statusMessage = nil
        selectFirstEntry()
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

    func revealRawEditor() {
        do {
            try flushEditor()
            if showRaw { showRaw = false; selectFirstEntry(); return }
            let alert = NSAlert()
            alert.messageText = "Open the YAML editor?"
            alert.informativeText = "Raw YAML displays the actual configuration, including tokens, passwords, and private keys. Changes remain pending until Apply."
            alert.addButton(withTitle: "Open YAML")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            editor = nil; loadedEditor = nil; showRaw = true
        } catch { errorMessage = error.localizedDescription }
    }

    func importFile() {
        do {
            try flushEditor()
            guard document != nil || missingFile else { throw ConfigError.invalid("Repair this configuration before merging an import.") }
            let panel = NSOpenPanel()
            panel.title = "Import Kubeconfig"
            panel.showsHiddenFiles = true
            if panel.runModal() == .OK, let url = panel.url {
                guard let data = try LocalFileAccess().read(url), let yaml = String(data: data, encoding: .utf8) else { throw ConfigError.invalid("Choose a UTF-8 kubeconfig file.") }
                try prepareImport(yaml: yaml, directory: url.deletingLastPathComponent())
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func prepareImport(yaml: String, directory: URL?) throws {
        try flushEditor()
        guard document != nil || missingFile else { throw ConfigError.invalid("Repair this configuration before merging an import.") }
        importPlan = try ImportPlan(target: document ?? .empty, incoming: KubeDocument(yaml: yaml), sourceDirectory: directory)
        showPaste = false
        showImport = true
    }

    func acceptImport(_ plan: ImportPlan) throws {
        let merged = try plan.merged(into: document ?? .empty)
        try stage(merged, message: "Import staged. Review and Apply to save it.")
        editor = nil; loadedEditor = nil; selectedName = nil
        showImport = false; importPlan = nil; section = .contexts; showRaw = false
        selectFirstEntry()
    }

    func refreshBackups() {
        guard let snapshot else { return }
        do {
            records = try store.backups.records(for: snapshot.resolvedURL)
            if !records.contains(where: { $0.id == selectedBackupID }) { selectedBackupID = records.first?.id }
        } catch {
            records = []; selectedBackupID = nil
            errorMessage = error.localizedDescription
        }
    }

    func rollbackSelected() {
        guard let backup = selectedBackup, let snapshot else { return }
        resolvePendingChanges { [weak self] in
            guard let self else { return }
            do {
                let restored = try self.store.backups.rollbackText(backup, for: snapshot.resolvedURL)
                // Do not modify snapshot: it still represents the live file against which Apply must compare.
                self.editor = nil; self.loadedEditor = nil; self.selectedName = nil
                self.draftText = restored
                self.parseDraft()
                self.statusMessage = "Rollback staged. Review and Apply to restore this version."
                self.section = .contexts; self.showRaw = false; self.selectFirstEntry()
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
        let panel = NSSavePanel()
        panel.title = title; panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return false }
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
        else { statusMessage = "No backups have been saved for this configuration yet." }
    }
}
