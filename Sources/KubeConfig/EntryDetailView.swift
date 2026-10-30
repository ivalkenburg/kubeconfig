import AppKit
import KubeConfigCore
import SwiftUI

struct EntryDetailView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 25, weight: .regular)).foregroundStyle(Color.accentColor)
                    .frame(width: 42, height: 42).background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.editor?.originalName ?? "New \(kind.singular)")
                        .font(.title2).fontWeight(.semibold).lineLimit(2).textSelection(.enabled)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if kind == .contexts {
                    Button(action: model.makeActive) {
                        Label(isActive ? "Active in Draft" : "Make Active", systemImage: "checkmark.circle")
                    }.disabled(isActive)
                }
            }.padding(24)
            Divider()
            Form {
                Section {
                    TextField("Name", text: nameBinding)
                        .accessibilityIdentifier("entryName")
                } header: { Text("\(kind.singular.capitalized) details") }

                if kind == .contexts {
                    Section {
                        referencePicker("Cluster", key: "cluster", kind: .clusters, optional: false)
                        referencePicker("User", key: "user", kind: .users, optional: true)
                        TextField("Namespace", text: field("namespace"), prompt: Text("default"))
                    } header: { Text("References") } footer: {
                        Text("The namespace becomes this context’s CLI default after Apply. An empty namespace uses default.")
                    }
                    if isActive {
                        Section {
                            Button("Clear Active Context", action: model.clearActive)
                        } footer: { Text("Clearing is staged until Apply.") }
                    }
                } else if kind == .clusters {
                    Section("Connection") {
                        TextField("Server", text: field("server"), prompt: Text("https://cluster.example.com:6443"))
                        TextField("TLS server name", text: field("tls-server-name"), prompt: Text("Optional"))
                        TextField("Proxy URL", text: field("proxy-url"), prompt: Text("Optional"))
                    }
                    Section {
                        pathField("Certificate authority", key: "certificate-authority")
                        if entry?.fields["certificate-authority-data"] != nil {
                            Label("An embedded CA certificate takes precedence over the file path.", systemImage: "doc.badge.lock")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if entry?.fields["insecure-skip-tls-verify"]?.bool == true {
                            Label("TLS verification is disabled in this configuration.", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    } header: { Text("TLS") } footer: { Text("Additional TLS settings are preserved. Use YAML to edit embedded certificates or verification settings.") }
                } else {
                    Section {
                        LabeledContent("Authentication", value: entry?.authenticationSummary ?? "No credentials")
                        TextField("Username", text: field("username"))
                        secretField("Password", key: "password")
                        secretField("Token", key: "token")
                        Toggle("Reveal credentials", isOn: $model.revealedSecrets)
                            .toggleStyle(.switch).controlSize(.small)
                    } header: { Text("Credentials") } footer: {
                        Text("Credential plugins, provider settings, and embedded keys are preserved. This app does not run authentication commands.")
                    }
                    Section("Certificate files") {
                        pathField("Client certificate", key: "client-certificate")
                        secretField("Private key path", key: "client-key")
                        if entry?.fields["client-key-data"] != nil {
                            Label("Embedded private key retained. Edit it in YAML.", systemImage: "lock.doc")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !model.validationIssues.isEmpty {
                    Section("Configuration issues") {
                        ForEach(model.validationIssues, id: \.self) { issue in
                            Label(issue, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                        }
                    }
                }
                Section {
                    HStack {
                        Button("Delete \(kind.singular.capitalized)…", role: .destructive, action: model.deleteSelected)
                        Spacer()
                        if model.formIsDirty {
                            Button("Stage Edits") {
                                do { try model.flushEditor() } catch { model.errorMessage = error.localizedDescription }
                            }
                        }
                    }
                } footer: {
                    Text("Edits remain pending until you review and Apply. Unrecognized configuration fields are retained.")
                }
            }
            .formStyle(.grouped)
        }
    }

    private var kind: EntryKind { model.editor?.kind ?? .contexts }
    private var entry: ConfigEntry? { model.document?.entry(kind, named: model.editor?.originalName ?? "") }
    private var isActive: Bool { model.document?.currentContext == model.editor?.originalName }
    private var subtitle: String {
        switch kind {
        case .contexts: return "Choose a cluster, credentials, and namespace."
        case .clusters: return "Configure the API server and TLS connection."
        case .users: return "Manage credentials referenced by your contexts."
        }
    }
    private var nameBinding: Binding<String> {
        Binding(get: { model.editor?.name ?? "" }, set: { model.editor?.name = $0 })
    }
    private func field(_ key: String) -> Binding<String> {
        Binding(get: { model.editor?.fields[key] ?? "" }, set: { model.editor?.fields[key] = $0 })
    }
    private func referencePicker(_ title: String, key: String, kind: EntryKind, optional: Bool) -> some View {
        Picker(title, selection: field(key)) {
            Text(optional ? "None (anonymous)" : "Choose a cluster").tag("")
            let current = model.editor?.fields[key] ?? ""
            if !current.isEmpty, model.document?.entry(kind, named: current) == nil { Text("\(current) (missing)").tag(current) }
            ForEach(model.document?.entries(kind) ?? []) { entry in Text(entry.name).tag(entry.name) }
        }
    }
    @ViewBuilder private func secretField(_ title: String, key: String) -> some View {
        if model.revealedSecrets { TextField(title, text: field(key)) }
        else { SecureField(title, text: field(key)) }
    }
    private func pathField(_ title: String, key: String) -> some View {
        HStack {
            TextField(title, text: field(key), prompt: Text("Optional file path"))
            Button {
                let panel = NSOpenPanel(); panel.title = "Choose \(title.lowercased())"; panel.showsHiddenFiles = true
                if panel.runModal() == .OK, let url = panel.url { model.editor?.fields[key] = url.path }
            } label: { Image(systemName: "folder") }
            .buttonStyle(.borderless).help("Choose \(title.lowercased()) file")
            .accessibilityLabel("Choose \(title.lowercased()) file")
        }
    }
}

struct RawEditorView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            NoticeBar(symbol: "eye", text: "Raw YAML displays credentials. Changes are saved only after Apply.") { EmptyView() }
            if !model.validationIssues.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(model.validationIssues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.circle").font(.callout)
                    }
                }.foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(14)
                Divider()
            }
            TextEditor(text: Binding(get: { model.draftText }, set: model.editRaw))
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(Color(nsColor: .textBackgroundColor))
                .accessibilityLabel("Kubeconfig YAML")
        }
    }
}

struct BackupDetailView: View {
    @ObservedObject var model: AppModel
    @State private var reveal = false

    var body: some View {
        if let record = model.selectedBackup {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Previous configuration").font(.title2).fontWeight(.semibold)
                            Text(record.createdAt, format: .dateTime.year().month(.wide).day().hour().minute().second())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Rollback to This Version…", action: model.rollbackSelected).buttonStyle(.borderedProminent)
                    }
                    Text("Rollback loads this version as a draft. Review and Apply to restore it; the replaced configuration becomes a new backup.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Toggle("Reveal credentials", isOn: $reveal).toggleStyle(.checkbox)
                        Spacer()
                        Button("Reveal Backup Folder", action: model.revealBackups)
                    }
                }.padding(24)
                Divider()
                ScrollView([.horizontal, .vertical]) {
                    Text(preview(record))
                        .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(20)
                }.background(Color(nsColor: .textBackgroundColor))
            }.onChange(of: model.selectedBackupID) { _, _ in reveal = false }
        } else {
            ContentUnavailableView {
                Label("Your undo history", systemImage: "clock.arrow.circlepath")
            } description: {
                Text("Previous configurations are saved after each successful Apply. Choose a backup to inspect or roll back.")
            } actions: {
                SettingsLink { Text("Backup Preferences…") }
            }
        }
    }

    private func preview(_ record: BackupRecord) -> String {
        let text = String(data: record.contents, encoding: .utf8) ?? ""
        if reveal { return text }
        return (try? KubeDocument(yaml: text).serialized(revealingSecrets: false)) ?? "This backup contains invalid YAML. Reveal its contents to inspect it."
    }
}
