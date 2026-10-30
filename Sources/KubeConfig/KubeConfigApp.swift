import AppKit
import SwiftUI

@main
struct KubeConfigApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("KubeConfig", id: "main") {
            MainView(model: model)
                .background(WindowBridge(model: model))
                .onAppear {
                    delegate.model = model
                    #if DEBUG
                    ScreenshotCapture.startIfRequested(model: model)
                    #endif
                }
                .frame(minWidth: 920, minHeight: 600)
        }
        .defaultSize(width: 1120, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Configuration…", action: model.openConfiguration).keyboardShortcut("o")
                Button("Reload Configuration", action: model.reload).keyboardShortcut("r")
                Divider()
                Button("Import File…", action: model.importFile).keyboardShortcut("i")
                Button("Paste YAML…") { model.showPaste = true }.keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Export Draft…", action: model.exportDraft).keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Review & Apply…") { model.requestReview() }.keyboardShortcut("s").disabled(!model.hasPendingChanges)
            }
        }
        Settings { PreferencesView() }
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.needsAttentionBeforeLeaving else { return .terminateNow }
        model.resolvePendingChanges { DispatchQueue.main.async { sender.terminate(nil) } }
        return .terminateCancel
    }
}

private struct WindowBridge: NSViewRepresentable {
    let model: AppModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.delegate = context.coordinator }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        let model: AppModel
        init(model: AppModel) { self.model = model }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard model.needsAttentionBeforeLeaving else { return true }
            model.resolvePendingChanges { DispatchQueue.main.async { sender.performClose(nil) } }
            return false
        }
    }
}
