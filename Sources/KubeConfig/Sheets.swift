import AppKit
import KubeConfigCore
import SwiftUI

struct ReviewSheet: View {
    @ObservedObject var model: AppModel
    @State private var reveal = false
    @State private var diff: [DiffLine] = []
    @State private var issue: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Review changes").font(.title2).fontWeight(.semibold)
                Text(model.snapshot?.url.path ?? "").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Apply replaces this file. \(model.retention == 0 ? "Backups are disabled." : "Its previous contents will be saved as a backup after Apply.")")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Reveal credentials and original formatting", isOn: $reveal).toggleStyle(.checkbox)
                    .onChange(of: reveal) { _, _ in refresh() }
                if !reveal {
                    Text("Credentials are masked. Formatting and comments may change; reveal the original to inspect those changes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            Divider()
            if let issue { ContentUnavailableView("Unable to show changes", systemImage: "exclamationmark.triangle", description: Text(issue)) }
            else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(diff) { line in
                            HStack(alignment: .top, spacing: 10) {
                                Text(prefix(line.change)).foregroundStyle(color(line.change)).frame(width: 12)
                                Text(line.text.isEmpty ? " " : line.text).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.system(.callout, design: .monospaced))
                            .padding(.horizontal, 16).padding(.vertical, 2)
                            .background(color(line.change).opacity(line.change == .unchanged ? 0 : 0.08))
                        }
                    }.padding(.vertical, 12).frame(minWidth: 700, alignment: .leading)
                }.background(Color(nsColor: .textBackgroundColor))
            }
            Divider()
            HStack {
                Label("\(diff.filter { $0.change == .added }.count) added · \(diff.filter { $0.change == .removed }.count) removed", systemImage: "arrow.left.arrow.right")
                    .font(.caption).foregroundStyle(.secondary)
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

    private func refresh() {
        do {
            guard let document = model.document else { return }
            diff = try ConfigurationDiff.lines(before: model.snapshot?.text ?? "", after: document, reveal: reveal)
            issue = nil
        } catch { issue = error.localizedDescription }
    }
    private func prefix(_ change: DiffLine.Change) -> String { change == .added ? "+" : change == .removed ? "−" : " " }
    private func color(_ change: DiffLine.Change) -> Color { change == .added ? .green : change == .removed ? .red : .secondary }
}

struct PasteSheet: View {
    @ObservedObject var model: AppModel
    @State private var yaml = ""
    @State private var directory: URL?
    @State private var issue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Paste kubeconfig YAML").font(.title2).fontWeight(.semibold)
            Text("Paste the configuration from your provider. You’ll review entries and naming conflicts before merging.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $yaml)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator, lineWidth: 1))
                .accessibilityLabel("YAML to import")
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Source folder").fontWeight(.medium)
                    Text(directory?.path ?? "Required only when this YAML contains relative file paths.")
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
                Button("Cancel") { model.showPaste = false }.keyboardShortcut(.cancelAction)
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
    @State private var reveal = false

    init(model: AppModel, initialPlan: ImportPlan) {
        self.model = model
        _plan = State(initialValue: initialPlan)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Review import").font(.title2).fontWeight(.semibold)
                Text("Resolve names before merging into your draft. Existing entries stay intact unless you choose Replace.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Skip retains an existing entry of the same name when imported contexts refer to it. Missing references must be resolved before merging.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach([EntryKind.clusters, .users, .contexts]) { kind in
                        if plan.items.contains(where: { $0.kind == kind }) {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(kind.title, systemImage: kind.symbol).font(.headline)
                                ForEach(plan.items.indices.filter { plan.items[$0].kind == kind }, id: \.self) { index in
                                    importRow(index)
                                    if index != plan.items.indices.last { Divider() }
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
                        Toggle("Reveal credentials", isOn: $reveal).toggleStyle(.checkbox).padding(.vertical, 8)
                        Text((try? plan.incoming.serialized(revealingSecrets: reveal)) ?? "")
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
                    Text("The file changes only after Apply.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { model.showImport = false; model.importPlan = nil }.keyboardShortcut(.cancelAction)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.items[index].originalName).fontWeight(.medium).lineLimit(2)
                    Text(plan.items[index].identical ? "Identical entry exists" : plan.items[index].conflicts ? "Name already exists" : "New entry")
                        .font(.caption).foregroundStyle(plan.items[index].conflicts && !plan.items[index].identical ? Color.orange : .secondary)
                }
                Spacer()
                Picker("Action", selection: $plan.items[index].action) {
                    Text(plan.items[index].conflicts ? "Rename imported" : "Add").tag(ImportAction.rename)
                    if plan.items[index].conflicts { Text("Replace existing").tag(ImportAction.replace) }
                    Text("Skip").tag(ImportAction.skip)
                    if plan.items[index].identical { Text("Reuse existing").tag(ImportAction.reuse) }
                }.labelsHidden().frame(width: 165).accessibilityLabel("Import action for \(plan.items[index].originalName)")
            }
            if plan.items[index].action == .rename {
                HStack {
                    Text("Import as").font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                    TextField("Destination name", text: $plan.items[index].destinationName).textFieldStyle(.roundedBorder)
                }
            }
            if plan.items[index].action == .replace {
                Label("Existing contexts using this name will use the imported settings.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }.padding(.vertical, 5)
    }
}

struct PreferencesView: View {
    @AppStorage("backupRetention") private var retention = 10
    var body: some View {
        Form {
            Section {
                Stepper(value: Binding(get: { min(1000, max(0, retention)) }, set: { retention = $0 }), in: 0...1000) {
                    HStack {
                        Text("Backups per configuration")
                        Spacer()
                        TextField("Count", value: $retention, format: .number)
                            .multilineTextAlignment(.trailing).frame(width: 60)
                            .onChange(of: retention) { _, value in retention = min(1000, max(0, value)) }
                    }
                }
                if retention == 0 {
                    Label("Backups disabled", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            } header: { Text("Rolling backups") } footer: {
                Text("After each successful Apply, save the previous contents. Keep the newest \(retention) per file. Older backups are removed after the next successful Apply. Set zero to disable backups and remove existing history on the next Apply.")
            }
            Section {
                LabeledContent("Default configuration", value: "~/.kube/config")
                LabeledContent("Version", value: "1.0")
            }
        }.formStyle(.grouped).padding(10).frame(width: 480, height: 320)
    }
}
