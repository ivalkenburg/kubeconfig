import KubeConfigCore
import SwiftUI

struct ContextExportSheet: View {
    @ObservedObject var model: AppModel
    @State private var issue: String?
    @State private var copyFeedbackID: UUID?
    private let yaml: String
    @State private var coloredYAML: AttributedString?

    init(model: AppModel, plan: ContextExportPlan) {
        self.model = model
        yaml = plan.yaml
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Preview export").font(.title2).fontWeight(.semibold)
                Text("Review the kubeconfig to copy or save.")
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                if let coloredYAML {
                    Text(coloredYAML).font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(20)
                }
            }
            .defaultScrollAnchor(.topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let issue { Label(issue, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange) }
                HStack {
                    Button(copyFeedbackID == nil ? "Copy" : "Copied") {
                        model.copyToPasteboard(yaml)
                        copyFeedbackID = UUID()
                    }
                    .help("Copy the complete kubeconfig to the clipboard")
                    .task(id: copyFeedbackID) {
                        guard copyFeedbackID != nil else { return }
                        do { try await Task.sleep(for: .seconds(2)) }
                        catch { return }
                        copyFeedbackID = nil
                    }
                    Spacer()
                    Button("Cancel", action: model.closeContextExport).keyboardShortcut(.cancelAction)
                    Button("Export…") {
                        do { try model.saveContextExport() }
                        catch { issue = error.localizedDescription }
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }.padding(20)
        }.frame(width: 720, height: 640)
        .onAppear { if coloredYAML == nil { coloredYAML = YAMLStyle.attributed(yaml) } }
    }
}
