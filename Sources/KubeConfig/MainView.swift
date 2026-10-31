import AppKit
import KubeConfigCore
import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel
    @FocusState private var searchIsFocused: Bool

    var body: some View {
        Group {
            if model.showRaw {
                // The whole file is on screen, so the entry list has nothing to add.
                NavigationSplitView(columnVisibility: $model.columnVisibility) {
                    sidebar
                } detail: {
                    detail.toolbar { toolbarContent }
                }
            } else {
                NavigationSplitView(columnVisibility: $model.columnVisibility) {
                    sidebar
                } content: {
                    contentList
                        .navigationSplitViewColumnWidth(min: 235, ideal: 275, max: 370)
                } detail: {
                    detail.toolbar { toolbarContent }
                }
            }
        }
        .toolbar(removing: .title)
        .onChange(of: model.searchFocusRequest) { searchIsFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.checkForExternalChange()
        }
        .sheet(isPresented: $model.showReview) { ReviewSheet(model: model) }
        .sheet(isPresented: $model.showImportSource) { ImportSourceSheet(model: model) }
        .sheet(isPresented: $model.showImport) {
            if let plan = model.importPlan { ImportSheet(model: model, initialPlan: plan) }
        }
        .alert("Couldn’t complete the action", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") {}
        } message: { Text(model.errorMessage ?? "") }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) { FileTitle(model: model) }
            .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible, placement: .navigation)
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: model.openConfiguration) { Label("Open", systemImage: "folder") }
                .help("Open a different kubeconfig (⌘O)")
            Button { model.showImportSource = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
                .help("Merge another kubeconfig into this draft (⌘I)")
                .disabled(!model.canImport)
            Button(action: model.toggleRawEditor) {
                Label(model.showRaw ? "Forms" : "YAML", systemImage: model.showRaw ? "list.bullet.rectangle" : "chevron.left.forwardslash.chevron.right")
            }
            .help(model.showRaw ? "Return to the forms" : "Edit the complete configuration as YAML")
            .disabled(model.hasNoConfiguration && !model.showRaw)
            if model.showRaw {
                Toggle(isOn: $model.wrapsYAML) { Label("Wrap Lines", systemImage: "arrow.turn.down.left") }
                    .help("Wrap long lines")
            }
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: model.undoCommand) { Label("Undo", systemImage: "arrow.uturn.backward") }
                .help("Undo (⌘Z)")
                .disabled(!model.canUndo)
            Button(action: model.redoCommand) { Label("Redo", systemImage: "arrow.uturn.forward") }
                .help("Redo (⇧⌘Z)")
                .disabled(!model.canRedoCommand)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button(action: model.discardDraft) { Text("Discard").padding(.horizontal, 6) }
                .help("Discard all pending changes. Undo brings them back.")
                .disabled(!model.hasPendingChanges)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.requestReview() } label: {
                Label(applyTitle, systemImage: "checkmark").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.glassProminent)
            .disabled(!model.canApply)
            .help(model.validationIssues.isEmpty ? "Review changes and apply them to disk (⌘S)" : "Fix the configuration issues before applying")
        }
    }

    private var applyTitle: String {
        model.reviewCount > 0 ? "Apply \(model.reviewCount)" : "Apply"
    }

    private var sidebar: some View {
        let changes = model.pendingChanges
        return List(selection: Binding<AppSection?>(get: { model.section }, set: { if let next = $0, next != model.section { model.selectSection(next) } })) {
            Section("Configuration") {
                ForEach(AppSection.configuration) { section in
                    Label(section.title, systemImage: section.symbol)
                        .badge(section.kind.flatMap { changes?.count($0) } ?? 0)
                        .tag(section)
                }
            }
            Section("History") {
                Label("Backups", systemImage: AppSection.backups.symbol).tag(AppSection.backups)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("KubeConfig")
        .navigationSplitViewColumnWidth(min: 155, ideal: 180, max: 220)
    }

    private var contentList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                searchField
                if let kind = model.section.kind {
                    Button(action: model.addEntry) { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("Add \(kind.singular)")
                        .accessibilityLabel("Add \(kind.singular)")
                        .disabled(model.document == nil)
                } else {
                    Button(action: model.refreshBackups) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Refresh backups").accessibilityLabel("Refresh backups")
                }
            }.padding(10)
            if let kind = model.section.kind {
                entryList(kind)
            } else {
                backupList
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder private func entryList(_ kind: EntryKind) -> some View {
        let changes = model.pendingChanges
        let entries = model.visibleEntries
        if entries.isEmpty {
            ListMessage(symbol: model.search.isEmpty ? kind.symbol : "magnifyingglass",
                        title: model.search.isEmpty ? "No \(kind.title.lowercased()) yet" : "No matches") {
                if model.search.isEmpty, model.document != nil {
                    Button("Add \(kind.singular)", action: model.addEntry)
                }
            }
        } else {
            List(selection: Binding<String?>(get: { model.selectedName }, set: { if $0 != model.selectedName { model.selectEntry($0) } })) {
                ForEach(entries) { entry in
                    EntryRow(entry: entry, active: isActive(entry), changed: isChanged(entry, in: changes))
                        .tag(entry.name)
                        .padding(.vertical, 5)
                }
            }
            .contextMenu(forSelectionType: String.self) { names in
                if let entry = entries.first(where: { names.contains($0.name) }) { entryMenu(entry) }
            } primaryAction: { names in
                if let entry = entries.first(where: { names.contains($0.name) }), entry.kind == .contexts, !isActive(entry) {
                    model.makeActive(entry.name)
                }
            }
            .listStyle(.inset)
            .onDeleteCommand {
                if let name = model.selectedName, model.deleteBlockReason(name) == nil { model.deleteEntry(name) } else { NSSound.beep() }
            }
        }
    }

    private func isActive(_ entry: ConfigEntry) -> Bool {
        entry.kind == .contexts && model.document?.currentContext == entry.name
    }

    private func isChanged(_ entry: ConfigEntry, in changes: DraftChanges?) -> Bool {
        changes?.contains(entry.kind, name: entry.name) == true || (isActive(entry) && changes?.activeContextChanged == true)
    }

    @ViewBuilder private func entryMenu(_ entry: ConfigEntry) -> some View {
        if entry.kind == .contexts {
            if isActive(entry) {
                Button("Clear Active Context", action: model.clearActive)
            } else {
                Button("Make Active") { model.makeActive(entry.name) }
            }
            Divider()
        }
        Button("Duplicate") { model.duplicateEntry(entry.name) }
        Button("Copy Name") { model.copyToPasteboard(entry.name) }
        if entry.kind == .clusters {
            Button("Copy Server URL") { model.copyToPasteboard(entry.value("server")) }
                .disabled(entry.value("server").isEmpty)
        }
        Divider()
        let blocked = model.deleteBlockReason(entry.name)
        Button(blocked.map { "Delete (\($0.lowercased()))" } ?? (isActive(entry) ? "Delete…" : "Delete"), role: .destructive) {
            model.deleteEntry(entry.name)
        }
        .disabled(blocked != nil)
    }

    @ViewBuilder private var backupList: some View {
        let backups = model.visibleBackups
        if model.records.isEmpty {
            ListMessage(symbol: AppSection.backups.symbol, title: "No backups yet", detail: "After Apply, the previous version appears here.")
        } else if backups.isEmpty {
            ListMessage(symbol: "magnifyingglass", title: "No matching backups", detail: "Try another date or clear your search.") {
                Button("Clear Search") { model.search = "" }
            }
        } else {
            List(backups, selection: $model.selectedBackupID) { record in
                VStack(alignment: .leading, spacing: 5) {
                    Text(record.createdAt, format: .backupDate)
                        .font(.system(.body, weight: .medium))
                    Text(ByteCountFormatter.string(fromByteCount: Int64(record.byteCount), countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6).tag(record.id)
                .contextMenu {
                    Button("Rollback…") { model.selectedBackupID = record.id; model.rollbackSelected() }
                    Button("Reveal in Finder", action: model.revealBackups)
                }
            }.listStyle(.inset)
        }
    }

    private var searchField: some View {
        let label = "Search \(model.section.title.lowercased())"
        return HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(model.section == .backups ? "Search by date" : label, text: $model.search)
                .textFieldStyle(.plain)
                .focused($searchIsFocused)
                .accessibilityLabel(label)
            if !model.search.isEmpty {
                Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
            }
        }.padding(.horizontal, 10).padding(.vertical, 6).background(.quaternary.opacity(0.5), in: Capsule())
    }

    private var emptyStateProblem: String {
        let path = model.snapshot?.url.path ?? "the selected path"
        return model.snapshot?.exists == true ? "\(path) is empty." : "There’s no file at \(path)."
    }

    @ViewBuilder private var detail: some View {
        VStack(spacing: 0) {
            if let warning = model.backupWarning {
                NoticeBar(text: warning) {
                    if model.recoveryContents != nil { Button("Export Previous…", action: model.exportRecovery) }
                }
            }
            if model.fileChangedOnDisk {
                NoticeBar(text: "This file changed outside KubeConfig. Reload to see the new version.") {
                    if model.hasPendingChanges { Button("Export Draft…", action: model.exportDraft) }
                    Button("Reload", action: model.reload)
                }
            }
            if model.section == .backups, model.damagedBackupCount > 0 {
                let count = model.damagedBackupCount
                NoticeBar(text: "\(count) damaged backup\(count == 1 ? " isn’t" : "s aren’t") listed.") {
                    Button("Reveal Folder", action: model.revealBackups)
                }
            }
            // Fills the rest, so that an unavailable view can't let the stack above it drift to the middle.
            Group {
                if model.showRaw {
                    YAMLEditor(model: model)
                } else if model.section == .backups {
                    BackupDetailView(model: model)
                } else if model.hasNoConfiguration {
                    ContentUnavailableView {
                        Label("Create your configuration", systemImage: "doc.badge.plus")
                    } description: {
                        Text("\(emptyStateProblem) Create a configuration or import a kubeconfig to get started.")
                    } actions: {
                        Button("Create Configuration", action: model.createConfiguration).buttonStyle(.borderedProminent)
                        Button("Import…") { model.showImportSource = true }
                    }
                } else if model.parseIssue != nil {
                    ContentUnavailableView {
                        Label("This file needs repair", systemImage: "exclamationmark.triangle")
                    } description: { Text(model.parseIssue ?? "") } actions: {
                        Button("Open YAML Editor", action: model.toggleRawEditor).buttonStyle(.borderedProminent)
                        Button("Open Another File…", action: model.openConfiguration)
                    }
                } else if model.editor != nil {
                    EntryDetailView(model: model)
                } else {
                    ContentUnavailableView {
                        Label("Select a \(model.section.kind?.singular ?? "configuration")", systemImage: model.section.symbol)
                    } description: {
                        Text("Choose an entry to edit, add one, or import a kubeconfig.")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct FileTitle: View {
    @ObservedObject var model: AppModel
    @State private var showIssues = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle
            HStack(spacing: 4) {
                Text(model.filePath).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let status = model.draftStatus { Text("· \(status)").foregroundStyle(.secondary).fixedSize() }
                if !model.validationIssues.isEmpty { issuesButton.fixedSize() }
            }.font(.caption)
        }
        // Stays over the list column, which is 235 to 370 wide.
        .frame(maxWidth: 260, alignment: .leading)
        .padding(.leading, 6)
        .help(model.snapshot?.url.path ?? "")
        .contextMenu {
            if let path = model.snapshot?.url.path { Button("Copy Path") { model.copyToPasteboard(path) } }
        }
    }

    @ViewBuilder private var sectionTitle: some View {
        if model.sidebarIsCollapsed {
            Menu {
                ForEach(AppSection.configuration) { sectionToggle($0) }
                Divider()
                sectionToggle(.backups)
            } label: {
                Text(model.section.title).font(.headline)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } else {
            Text(model.section.title).font(.headline).lineLimit(1)
        }
    }

    private func sectionToggle(_ section: AppSection) -> some View {
        Toggle(section.title, isOn: Binding(get: { model.section == section }, set: { _ in
            if section != model.section { model.selectSection(section) }
        }))
    }

    private var issuesButton: some View {
        let count = model.validationIssues.count
        return Button { showIssues.toggle() } label: {
            Text("· \(count) issue\(count == 1 ? "" : "s")")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.orange)
        .help("Show configuration issues")
        .popover(isPresented: $showIssues, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.validationIssues, id: \.self) { issue in
                    Label(issue, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14).frame(width: 320, alignment: .leading)
        }
    }
}

private struct EntryRow: View {
    let entry: ConfigEntry
    let active: Bool
    let changed: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.kind.symbol).foregroundStyle(active ? Color.accentColor : .secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(entry.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if changed { ChangeDot() }
                    if active { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).help("Active in Draft").accessibilityLabel("Active in Draft") }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }
    private var subtitle: String {
        switch entry.kind {
        case .contexts:
            let cluster = entry.value("cluster"), namespace = entry.value("namespace")
            return (cluster.isEmpty ? "No cluster" : cluster) + " · " + (namespace.isEmpty ? "default" : namespace)
        case .clusters: return entry.value("server").isEmpty ? "Server address required" : entry.value("server")
        case .users: return entry.authenticationSummary
        }
    }
}

/// Stands in for a list with nothing to show.
private struct ListMessage<Actions: View>: View {
    let symbol: String
    let title: String
    var detail: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
            Text(title).font(.subheadline).foregroundStyle(detail == nil ? .secondary : .primary)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            actions
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension ListMessage where Actions == EmptyView {
    init(symbol: String, title: String, detail: String? = nil) {
        self.init(symbol: symbol, title: title, detail: detail) { EmptyView() }
    }
}

struct ChangeDot: View {
    var body: some View {
        Circle().fill(.orange).frame(width: 6, height: 6)
            .help("Changed since the file on disk")
            .accessibilityLabel("Changed")
    }
}

struct GlassIconButton: View {
    let title: String
    let symbol: String
    var isOn = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.foreground))
        }
        .buttonStyle(.glass).buttonBorderShape(.circle)
        .help(title).accessibilityLabel(title)
    }
}

struct GlassIconGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) { content }
        }
    }
}

struct NoticeBar<Actions: View>: View {
    let text: String
    @ViewBuilder var actions: Actions
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            // A fixed height here would have the window measure this wrapped at its narrowest, and overflow.
            Text(text).font(.callout)
            Spacer(minLength: 4)
            actions
        }
        .padding(14)
        .background(.orange.opacity(0.07))
        Divider()
    }
}
