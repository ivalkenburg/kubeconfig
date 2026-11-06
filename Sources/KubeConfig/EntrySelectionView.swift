import KubeConfigCore
import SwiftUI

struct EntrySelectionSummary: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Text("\(model.selectedEntryNames.count) \(model.section.title.lowercased()) selected")
                .font(.title2).fontWeight(.semibold)
            Text(model.section == .contexts
                 ? "Export these contexts and their clusters and users, or delete the selected contexts."
                 : "Delete the selected \(model.section.title.lowercased()). Changes take effect after Apply.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            HStack(spacing: 12) {
                if model.section == .contexts {
                    Button("Preview Export…", action: model.requestContextExport)
                        .buttonStyle(.borderedProminent).disabled(!model.canExportContexts)
                }
                Button("\(model.selectionDeleteTitle)…", role: .destructive, action: model.requestSelectionDeletion)
                    .buttonStyle(.bordered).disabled(!model.canRequestSelectionDeletion)
            }
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
