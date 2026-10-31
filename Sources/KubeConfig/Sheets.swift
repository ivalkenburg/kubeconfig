import AppKit
import KubeConfigCore
import SwiftUI

struct ReviewSheet: View {
    @ObservedObject var model: AppModel
    @State private var diff: [DiffLine] = []
    @State private var coloredLines: [AttributedString] = []
    @State private var changes: [Range<Int>] = []
    @State private var current = 0
    @State private var issue: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Review changes").font(.title2).fontWeight(.semibold)
                Text(model.snapshot?.url.path ?? "").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Text("\(backupNote) Comments and formatting may change.")
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            Divider()
            if let issue { ContentUnavailableView("Unable to show changes", systemImage: "exclamationmark.triangle", description: Text(issue)) }
            else {
                ScrollViewReader { proxy in
                    ScrollView([.horizontal, .vertical]) {
                        // Wrapped lines vary in height, and a lazy stack's estimates would jump while scrolling.
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(diff) { line in
                                HStack(alignment: .top, spacing: 10) {
                                    Text(prefix(line.change)).foregroundStyle(color(line.change)).frame(width: 12)
                                    Text(coloredLines[line.id]).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .font(.system(.callout, design: .monospaced))
                                .padding(.horizontal, 16).padding(.vertical, 2)
                                .background(color(line.change).opacity(tint(line)))
                                .id(line.id)
                            }
                        }.padding(.vertical, 12).frame(minWidth: 700, alignment: .leading)
                    }
                    .defaultScrollAnchor(.topLeading)
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: current) { withAnimation { reveal(with: proxy) } }
                    .onChange(of: changes) {
                        // Waits for the sheet's first layout, then jumps there without animating.
                        DispatchQueue.main.async { reveal(with: proxy) }
                    }
                }
            }
            Divider()
            HStack(spacing: 10) {
                GlassIconGroup {
                    GlassIconButton(title: "Previous Change", symbol: "chevron.up") { current -= 1 }
                        .keyboardShortcut(.upArrow, modifiers: [])
                        .disabled(current <= 0)
                    GlassIconButton(title: "Next Change", symbol: "chevron.down") { current += 1 }
                        .keyboardShortcut(.downArrow, modifiers: [])
                        .disabled(current >= changes.count - 1)
                }
                Text(changes.isEmpty ? "No line changes" : "Change \(current + 1) of \(changes.count)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("Cancel", action: model.cancelReview).keyboardShortcut(.cancelAction)
                Button("Apply Changes", action: model.commit)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(issue != nil)
            }.padding(20)
        }
        .frame(width: 780, height: 620)
        .onAppear(perform: refresh)
        .interactiveDismissDisabled()
    }

    private var backupNote: String {
        if model.retention == 0 { return "Backups are disabled." }
        return model.snapshot?.exists == true ? "The current file will be saved as a backup." : "This creates the file."
    }

    private func refresh() {
        do {
            guard let document = model.document else { return }
            let lines = try ConfigurationDiff.lines(before: model.snapshot?.text ?? "", after: document)
            coloredLines = lines.map { YAMLStyle.attributed($0.text.isEmpty ? " " : $0.text) }
            diff = lines
            changes = ConfigurationDiff.changes(in: diff)
            current = 0
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    private func reveal(with proxy: ScrollViewProxy) {
        guard changes.indices.contains(current) else { return }
        proxy.scrollTo(diff[changes[current].lowerBound].id, anchor: UnitPoint(x: 0, y: 0.3))
    }

    private func tint(_ line: DiffLine) -> Double {
        guard line.change != .unchanged else { return 0 }
        return changes.indices.contains(current) && changes[current].contains(line.id) ? 0.2 : 0.08
    }

    private func prefix(_ change: DiffLine.Change) -> String { change == .added ? "+" : change == .removed ? "−" : " " }
    private func color(_ change: DiffLine.Change) -> Color { change == .added ? .green : change == .removed ? .red : .secondary }
}

struct ImportSourceSheet: View {
    @ObservedObject var model: AppModel
    @State private var yaml = ""
    @State private var directory: URL?
    @State private var issue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Import kubeconfig").font(.title2).fontWeight(.semibold)
                    Text("Choose a file or paste YAML. You’ll review entries and naming conflicts before merging.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose File…") {
                    do { try model.chooseImportFile() } catch { issue = error.localizedDescription }
                }
            }
            TextEditor(text: $yaml)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator, lineWidth: 1))
                .accessibilityLabel("YAML to import")
                .onChange(of: yaml) { issue = nil }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Source folder").fontWeight(.medium)
                    Text(directory?.path ?? "Required only when pasted YAML contains relative file paths.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Choose…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.showsHiddenFiles = true
                    if panel.runModal() == .OK { directory = panel.url }
                }
            }
            if let issue { Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { model.showImportSource = false }.keyboardShortcut(.cancelAction)
                Button("Preview Import") {
                    do { try model.prepareImport(yaml: yaml, directory: directory) }
                    catch { issue = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 680, height: 600)
    }
}

struct ImportSheet: View {
    @ObservedObject var model: AppModel
    @State private var plan: ImportPlan
    @State private var issue: String?
    /// Fixed for the sheet's lifetime, so typing a destination name doesn't color it all over again.
    private let importedYAML: AttributedString

    init(model: AppModel, initialPlan: ImportPlan) {
        self.model = model
        _plan = State(initialValue: initialPlan)
        importedYAML = YAMLStyle.attributed((try? initialPlan.incoming.serialized()) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Review import").font(.title2).fontWeight(.semibold)
                Text("Existing entries stay intact unless you choose Replace.")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(EntryKind.importOrder) { kind in
                        let indices = plan.items.indices.filter { plan.items[$0].kind == kind }
                        if !indices.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(kind.title, systemImage: kind.symbol).font(.headline)
                                ForEach(indices, id: \.self) { index in
                                    importRow(index)
                                    if index != indices.last { Divider() }
                                }
                            }
                        }
                    }
                    if plan.items.isEmpty { Text("This import contains only configuration metadata.").foregroundStyle(.secondary) }
                    if !plan.resolvedPaths.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Resolved file paths", systemImage: "folder").font(.headline)
                            ForEach(plan.resolvedPaths, id: \.self) { path in
                                Text(path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                    }
                    DisclosureGroup("Imported configuration") {
                        Text(importedYAML)
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(24)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if !plan.incoming.currentContext.isEmpty {
                    Toggle("Make imported ‘\(plan.incoming.currentContext)’ active after Apply", isOn: $plan.activateImportedContext)
                        .toggleStyle(.checkbox)
                }
                if let issue { Label(issue, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange) }
                HStack {
                    Spacer()
                    Button("Cancel", action: model.closeImport).keyboardShortcut(.cancelAction)
                    Button("Merge into Draft") {
                        do {
                            try model.acceptImport(plan)
                        } catch { issue = error.localizedDescription }
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }.padding(20)
        }.frame(width: 800, height: 680)
    }

    private func importRow(_ index: Int) -> some View {
        let item = plan.items[index]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.originalName).fontWeight(.medium).lineLimit(2)
                    Text(item.identical ? "Identical entry exists" : item.conflicts ? "Name already exists" : "New entry")
                        .font(.caption).foregroundStyle(item.conflicts && !item.identical ? Color.orange : .secondary)
                }
                Spacer()
                Picker("Action", selection: $plan.items[index].action) {
                    Text(item.conflicts ? "Rename imported" : "Add").tag(ImportAction.rename)
                    if item.conflicts { Text("Replace existing").tag(ImportAction.replace) }
                    Text("Skip").tag(ImportAction.skip)
                    if item.identical { Text("Reuse existing").tag(ImportAction.reuse) }
                }.labelsHidden().frame(width: 165).accessibilityLabel("Import action for \(item.originalName)")
            }
            if item.action == .rename {
                HStack {
                    Text("Import as").font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                    TextField("Destination name", text: $plan.items[index].destinationName).textFieldStyle(.roundedBorder)
                }
            }
            if item.action == .replace {
                Label("Existing contexts using this name will use the imported settings.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }.padding(.vertical, 5)
    }
}

struct PreferencesView: View {
    @AppStorage(BackupRetention.key) private var retention = BackupRetention.defaultCount
    @AppStorage(ContextSwitching.immediateKey) private var switchesImmediately = ContextSwitching.immediateByDefault
    var body: some View {
        Form {
            Section {
                Toggle("Switch contexts immediately", isOn: $switchesImmediately)
            } header: { Text("Contexts") } footer: {
                Text(switchesImmediately
                     ? "Make Active and double-click write the active context to the file right away, with no backup. Other pending changes stay in the draft."
                     : "Make Active and double-click stage the switch for Apply.")
            }
            Section {
                Stepper(value: Binding(get: { BackupRetention.clamped(retention) }, set: { retention = $0 }), in: BackupRetention.range) {
                    HStack {
                        Text("Backups per configuration")
                        Spacer()
                        TextField("Count", value: $retention, format: .number)
                            .multilineTextAlignment(.trailing).frame(width: 60)
                            .onChange(of: retention) { _, value in retention = BackupRetention.clamped(value) }
                    }
                }
                if retention == 0 {
                    Label("Backups disabled", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            } header: { Text("Rolling backups") } footer: {
                Text("Keeps the newest \(retention) per file. Set zero to disable backups and remove existing history on the next Apply.")
            }
            Section {
                LabeledContent("Default configuration", value: "~/.kube/config")
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")
            }
        }.formStyle(.grouped).padding(10).frame(width: 480, height: 430)
    }
}
