import AppKit
import KubeConfigCore
import SwiftUI

struct EntryDetailView: View {
    @ObservedObject var model: AppModel
    @FocusState private var focus: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(model.editor?.originalName ?? "")
                    .font(.title2).fontWeight(.semibold).lineLimit(2).textSelection(.enabled)
                Spacer()
                GlassIconGroup {
                    if kind == .contexts {
                        GlassIconButton(title: isActive ? "Clear Active Context" : "Make Active", symbol: isActive ? "checkmark.circle.fill" : "checkmark.circle", isOn: isActive) {
                            if isActive { model.clearActive() } else { model.makeActive() }
                        }
                        GlassIconButton(title: k9sBlockReason ?? "Open in k9s (⇧⌘K)", symbol: "terminal") { model.openK9s() }
                            .disabled(k9sBlockReason != nil)
                        GlassIconButton(title: model.contextExportTitle, symbol: "square.and.arrow.up", action: model.requestContextExport)
                            .disabled(!model.canExportContexts)
                    }
                    GlassIconButton(title: blockedReason ?? "Delete \(kind.singular.capitalized)", symbol: "trash") { model.deleteEntry() }
                        .disabled(blockedReason != nil)
                }
            }.padding(.horizontal, 24).padding(.top, 14)
            Form {
                if kind == .contexts {
                    Section {
                        nameField
                        referencePicker(.clusters, none: "Choose a cluster")
                        referencePicker(.users, none: "None (anonymous)")
                        textField("Namespace", key: "namespace", prompt: "default")
                    } footer: {
                        Text("An empty namespace uses default.")
                    }
                } else if kind == .clusters {
                    Section {
                        nameField
                        textField("Server", key: "server", prompt: "https://cluster.example.com:6443")
                        textField("TLS server name", key: "tls-server-name", prompt: "Optional")
                        textField("Proxy URL", key: "proxy-url", prompt: "Optional")
                    }
                    Section {
                        pathField("Certificate authority", key: "certificate-authority")
                        if entry?.has("certificate-authority-data") == true {
                            Label("An embedded CA certificate takes precedence over the file path.", systemImage: "lock.doc")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if entry?.booleanValue("insecure-skip-tls-verify") == true {
                            Label("TLS verification is disabled in this configuration.", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    } header: { Text("TLS") } footer: { Text("Use YAML to edit embedded certificates or verification settings.") }
                } else {
                    Section {
                        nameField
                        LabeledContent("Authentication", value: entry?.authenticationSummary ?? "No credentials")
                        textField("Username", key: "username")
                        textField("Password", key: "password")
                        textField("Token", key: "token")
                    } footer: {
                        Text("KubeConfig keeps credential plugins but never runs them. k9s runs them to connect.")
                    }
                    Section("Certificate files") {
                        pathField("Client certificate", key: "client-certificate")
                        pathField("Private key", key: "client-key")
                        if entry?.has("client-key-data") == true {
                            Label("Embedded private key retained. Edit it in YAML.", systemImage: "lock.doc")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onChange(of: focus) { old, _ in if old != nil { model.commitForm() } }
    }

    private func rowLabel(_ title: String, changed: Bool) -> some View {
        HStack(spacing: 6) {
            if changed { ChangeDot() }
            Text(title)
        }
    }

    @ViewBuilder private var nameField: some View {
        TextField(text: nameBinding) { rowLabel("Name", changed: model.isNameChanged) }
            .accessibilityIdentifier("entryName")
            .focused($focus, equals: "name")
            .onSubmit(model.commitForm)
        if let error = model.nameError {
            Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
        }
    }

    private func textField(_ title: String, key: String, prompt: String? = nil) -> some View {
        TextField(text: field(key), prompt: prompt.map { Text($0) }) { rowLabel(title, changed: model.isFieldChanged(key)) }
            .focused($focus, equals: key)
            .onSubmit(model.commitForm)
    }

    private var kind: EntryKind { model.editor?.kind ?? .contexts }
    private var entry: ConfigEntry? { model.document?.entry(kind, named: model.editor?.originalName ?? "") }
    private var isActive: Bool { kind == .contexts && model.document?.currentContext == model.editor?.originalName }
    private var k9sBlockReason: String? { model.k9sBlockReason(model.editor?.originalName) }
    private var blockedReason: String? { model.editor.flatMap { model.deleteBlockReason($0.originalName) } }
    private var nameBinding: Binding<String> {
        Binding(get: { model.editor?.name ?? "" }, set: { model.editor?.name = $0 })
    }
    private func field(_ key: String) -> Binding<String> {
        Binding(get: { model.editor?.fields[key] ?? "" }, set: { model.editor?.fields[key] = $0 })
    }
    private func referencePicker(_ kind: EntryKind, none: String) -> some View {
        let key = kind.singular
        return Picker(selection: Binding(get: { model.editor?.fields[key] ?? "" }, set: { model.editor?.fields[key] = $0; model.commitForm() })) {
            Text(none).tag("")
            let current = model.editor?.fields[key] ?? ""
            if !current.isEmpty, model.document?.entry(kind, named: current) == nil { Text("\(current) (missing)").tag(current) }
            ForEach(model.document?.entries(kind) ?? []) { entry in Text(entry.name).tag(entry.name) }
        } label: { rowLabel(key.capitalized, changed: model.isFieldChanged(key)) }
    }
    private func pathField(_ title: String, key: String) -> some View {
        HStack {
            textField(title, key: key, prompt: "Optional file path")
            Button {
                if let url = model.chooseFile("Choose \(title.lowercased())") { model.editor?.fields[key] = url.path; model.commitForm() }
            } label: { Image(systemName: "folder") }
            .buttonStyle(.borderless).help("Choose \(title.lowercased()) file")
            .accessibilityLabel("Choose \(title.lowercased()) file")
        }
    }
}

struct BackupDetailView: View {
    @ObservedObject var model: AppModel
    /// Kept between updates, so that only a new selection reads its file again.
    @State private var contents = ""
    @State private var issue: String?

    var body: some View {
        if let record = model.selectedBackup {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text(record.createdAt, format: .backupFullDate)
                        .font(.title2).fontWeight(.semibold).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer()
                    GlassIconGroup {
                        GlassIconButton(title: model.wrapsYAML ? "Stop Wrapping Lines" : "Wrap Lines", symbol: "arrow.turn.down.left", isOn: model.wrapsYAML) { model.wrapsYAML.toggle() }
                        GlassIconButton(title: "Reveal Backup Folder", symbol: "folder", action: model.revealBackups)
                        GlassIconButton(title: "Rollback to This Version…", symbol: "arrow.uturn.backward.circle", action: model.rollbackSelected)
                            .disabled(issue != nil)
                    }
                }.padding(.horizontal, 24).padding(.vertical, 14)
                Divider()
                if let issue {
                    ContentUnavailableView("Unable to show this backup", systemImage: "exclamationmark.triangle", description: Text(issue))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    YAMLPreview(text: contents, wraps: model.wrapsYAML)
                }
            }
            .onChange(of: record.id, initial: true) {
                do {
                    contents = try model.backupPreview(record)
                    issue = nil
                } catch { issue = error.localizedDescription }
            }
        } else {
            ContentUnavailableView {
                Label("Your undo history", systemImage: AppSection.backups.symbol)
            } description: {
                Text("Previous configurations are saved after each successful Apply. Choose a backup to inspect or roll back.")
            } actions: {
                SettingsLink { Text("Backup Settings…") }
                Button("Reveal Backup Folder", action: model.revealBackups)
            }
        }
    }
}
