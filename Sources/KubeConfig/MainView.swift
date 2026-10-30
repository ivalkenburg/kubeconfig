import AppKit
import KubeConfigCore
import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 155, ideal: 180, max: 220)
            } content: {
                contentList
                    .navigationSplitViewColumnWidth(min: 235, ideal: 275, max: 370)
            } detail: {
                detail
            }
            Divider()
            footer
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: model.openConfiguration) { Label("Open", systemImage: "folder") }
                    .help("Open a different kubeconfig (⌘O)")
                Menu {
                    Button("Import File…", action: model.importFile)
                    Button("Paste YAML…") { model.showPaste = true }
                } label: { Label("Import", systemImage: "square.and.arrow.down") }
                .disabled(model.document == nil && !model.missingFile)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: model.revealRawEditor) {
                    Label(model.showRaw ? "Forms" : "YAML", systemImage: model.showRaw ? "list.bullet.rectangle" : "chevron.left.forwardslash.chevron.right")
                }
                .help("Edit the complete configuration as YAML")
                .disabled(model.missingFile)
                Button { model.requestReview() } label: { Label("Apply…", systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent)
                    .labelStyle(.titleAndIcon)
                    .disabled(!model.hasPendingChanges)
                    .help("Review changes and apply them to disk (⌘S)")
            }
        }
        .sheet(isPresented: $model.showReview) { ReviewSheet(model: model) }
        .sheet(isPresented: $model.showPaste) { PasteSheet(model: model) }
        .sheet(isPresented: $model.showImport) {
            if let plan = model.importPlan { ImportSheet(model: model, initialPlan: plan) }
        }
        .alert("Couldn’t complete the action", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding<AppSection?>(get: { model.section }, set: { if let next = $0, next != model.section { model.selectSection(next) } })) {
                Section("Configuration") {
                    ForEach([AppSection.contexts, .clusters, .users]) { section in
                        Label {
                            Text(section.title)
                        } icon: {
                            Image(systemName: section.symbol)
                                .foregroundStyle(model.section == section ? Color.white : Color.primary)
                        }.tag(section)
                    }
                }
                Section("History") {
                    Label {
                        Text("Backups")
                    } icon: {
                        Image(systemName: AppSection.backups.symbol)
                            .foregroundStyle(model.section == .backups ? Color.white : Color.primary)
                    }.tag(AppSection.backups)
                }
            }
            .listStyle(.sidebar)
            VStack(alignment: .leading, spacing: 9) {
                Label("Active context", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.appliedContext.isEmpty ? "None selected" : model.appliedContext)
                    .font(.system(.subheadline, weight: .medium))
                    .lineLimit(2).textSelection(.enabled)
                if model.document?.currentContext != model.appliedContext, model.document != nil {
                    Text("Switch pending Apply").font(.caption).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            Divider()
            HStack {
                SettingsLink { Label("Preferences", systemImage: "gearshape") }
                    .buttonStyle(.plain).font(.caption)
                Spacer()
            }.padding(16)
        }
        .navigationTitle("KubeConfig")
    }

    private var contentList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.section.title).font(.headline)
                Spacer()
                if let kind = model.section.kind {
                    Text("\(model.document?.entries(kind).count ?? 0)").font(.caption).foregroundStyle(.secondary)
                    Button(action: model.addEntry) { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("Add \(kind.singular)")
                        .accessibilityLabel("Add \(kind.singular)")
                        .disabled(model.document == nil)
                } else {
                    Button(action: model.refreshBackups) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Refresh backups").accessibilityLabel("Refresh backups")
                }
            }.padding(.horizontal, 16).padding(.vertical, 13)
            Divider()
            if model.section == .backups {
                backupList
            } else {
                entryList
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var entryList: some View {
        VStack(spacing: 0) {
            searchField
            if model.visibleEntries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: model.search.isEmpty ? model.section.symbol : "magnifyingglass")
                        .font(.title2).foregroundStyle(.secondary)
                    Text(model.search.isEmpty ? "No \(model.section.title.lowercased()) yet" : "No matches")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if model.search.isEmpty, model.document != nil {
                        Button("Add \(model.section.kind!.singular)", action: model.addEntry)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding<String?>(get: { model.selectedName }, set: { if $0 != model.selectedName { model.selectEntry($0) } })) {
                    ForEach(model.visibleEntries) { entry in
                        EntryRow(entry: entry, active: model.document?.currentContext == entry.name && entry.kind == .contexts)
                            .tag(entry.name)
                            .padding(.vertical, 5)
                    }
                }.listStyle(.inset)
            }
        }
    }

    private var backupList: some View {
        VStack(spacing: 0) {
            searchField
            if model.records.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath").font(.title2).foregroundStyle(.secondary)
                    Text("No backups yet").font(.subheadline)
                    Text("After Apply, the previous version appears here.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.visibleBackups.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                    Text("No matching backups").font(.subheadline)
                    Text("Try another date or clear your search.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Clear Search") { model.search = "" }
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.visibleBackups, selection: $model.selectedBackupID) { record in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(record.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                            .font(.system(.body, weight: .medium))
                        Text(ByteCountFormatter.string(fromByteCount: Int64(record.byteCount), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 6).tag(record.id)
                }.listStyle(.inset)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(model.section == .backups ? "Search backups by date" : "Search \(model.section.title.lowercased())", text: $model.search)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search \(model.section.title.lowercased())")
            if !model.search.isEmpty {
                Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
            }
        }.padding(9).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7)).padding(10)
    }

    @ViewBuilder private var detail: some View {
        VStack(spacing: 0) {
            if let warning = model.backupWarning {
                NoticeBar(symbol: "exclamationmark.triangle", text: warning, tint: .orange) {
                    if model.recoveryContents != nil { Button("Export Previous…", action: model.exportRecovery) }
                }
            }
            if model.showRaw {
                RawEditorView(model: model)
            } else if model.section == .backups {
                BackupDetailView(model: model)
            } else if model.missingFile {
                ContentUnavailableView {
                    Label("Create your configuration", systemImage: "doc.badge.plus")
                } description: {
                    Text("There’s no file at \(model.snapshot?.url.path ?? "the selected path"). Create one or import a kubeconfig to get started.")
                } actions: {
                    Button("Create Configuration", action: model.createConfiguration).buttonStyle(.borderedProminent)
                    Button("Import File…", action: model.importFile)
                }
            } else if model.parseIssue != nil {
                ContentUnavailableView {
                    Label("This file needs repair", systemImage: "doc.badge.exclamationmark")
                } description: { Text(model.parseIssue ?? "") } actions: {
                    Button("Open YAML Editor", action: model.revealRawEditor).buttonStyle(.borderedProminent)
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
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            Text(model.snapshot?.url.path ?? "No configuration open")
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                .help(model.snapshot?.url.path ?? "")
            Spacer(minLength: 10)
            if !model.validationIssues.isEmpty {
                Label("\(model.validationIssues.count) issue\(model.validationIssues.count == 1 ? "" : "s")", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange).help(model.validationIssues.joined(separator: "\n"))
            }
            if model.hasPendingChanges {
                Label("Pending changes", systemImage: "circle.fill").foregroundStyle(.orange)
                Menu {
                    Button("Export Draft…", action: model.exportDraft)
                    Button("Reload from Disk…", action: model.reload)
                    Button("Discard Changes…") { model.resolvePendingChanges {} }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Draft actions")
            } else {
                Label(model.statusMessage ?? "Up to date", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .font(.caption)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }
}

private struct EntryRow: View {
    let entry: ConfigEntry
    let active: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.kind.symbol).foregroundStyle(active ? Color.accentColor : .secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(entry.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if active { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).help("Active in draft").accessibilityLabel("Active in draft") }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }
    private var subtitle: String {
        switch entry.kind {
        case .contexts: return entry.value("cluster") + " · " + (entry.value("namespace").isEmpty ? "default" : entry.value("namespace"))
        case .clusters: return entry.value("server").isEmpty ? "Server address required" : entry.value("server")
        case .users: return entry.authenticationSummary
        }
    }
}

struct NoticeBar<Actions: View>: View {
    let symbol: String
    let text: String
    var tint: Color = .accentColor
    @ViewBuilder var actions: Actions
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            actions
        }
        .padding(14)
        .background(tint.opacity(0.07))
        Divider()
    }
}
