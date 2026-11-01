import AppKit
import Combine
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
            DraftCommands(model: model)
        }
        Settings { PreferencesView() }
    }
}

// Menu items only follow the model from inside a type that observes it. SwiftUI leaves them enabled behind a sheet.
private struct DraftCommands: Commands {
    @ObservedObject var model: AppModel
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Group {
                Button("Open Configuration…", action: model.openConfiguration).keyboardShortcut("o")
                Menu("Open Recent") {
                    ForEach(model.recentFiles, id: \.self) { url in
                        Button(model.displayPath(url)) { model.openRecent(url) }
                    }
                    Divider()
                    Button("Clear Menu", action: model.clearRecentFiles)
                }.disabled(model.recentFiles.isEmpty)
                Button("Reload Configuration", action: model.reload).keyboardShortcut("r")
                Divider()
                Button("Import…") { model.showImportSource = true }.keyboardShortcut("i").disabled(!model.canImport)
                Button("Export Selected Contexts…", action: model.requestContextExport).disabled(!model.canExportContexts)
                Button("Export Draft…", action: model.exportDraft).keyboardShortcut("e", modifiers: [.command, .shift]).disabled(model.hasNoConfiguration)
            }.disabled(model.sheetIsOpen)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Review & Apply…") { model.requestReview() }.keyboardShortcut("s").disabled(!model.canApply || model.sheetIsOpen)
            Button("Discard Changes", action: model.discardDraft).disabled(!model.hasPendingChanges || model.sheetIsOpen)
        }
        CommandGroup(after: .toolbar) {
            Toggle("Wrap Lines", isOn: $model.wrapsYAML).disabled(!model.showRaw && model.section != .backups)
            Divider()
            Button("Open in k9s") { model.openK9s() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(model.k9sBlockReason(model.selectedName) != nil)
            // SidebarCommands stays disabled until something in the split view has focus.
            Button(model.sidebarIsCollapsed ? "Show Sidebar" : "Hide Sidebar", action: model.toggleSidebar)
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(model.k9sFillsWindow)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo", action: model.undoCommand).keyboardShortcut("z").disabled(!model.canUndo && !model.sheetIsOpen)
            Button("Redo", action: model.redoCommand).keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canRedoCommand && !model.sheetIsOpen)
        }
        CommandGroup(after: .textEditing) {
            Button("Find…", action: model.find).keyboardShortcut("f").disabled(model.sheetIsOpen || model.k9sIsVisible)
            Group {
                Button("Find Next") { model.performFind(.nextMatch) }.keyboardShortcut("g")
                Button("Find Previous") { model.performFind(.previousMatch) }.keyboardShortcut("g", modifiers: [.command, .shift])
            }.disabled(!model.showRaw || model.sheetIsOpen)
        }
        // The app has no help book, so the default item only reports that help isn't available.
        CommandGroup(replacing: .help) {}
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
    func applicationWillTerminate(_ notification: Notification) { model?.closeK9s() }
}

private struct WindowBridge: NSViewRepresentable {
    let model: AppModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.delegate = context.coordinator
            model.window = view.window
            // Leave focus off the search field, so the first keystroke isn't typed into it.
            view.window?.makeFirstResponder(nil)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        let model: AppModel
        private var menuSync: AnyCancellable?
        init(model: AppModel) {
            self.model = model
            super.init()
            // SwiftUI refreshes menu items when a menu opens, so shortcuts would otherwise act on stale enabled states.
            menuSync = model.objectWillChange.debounce(for: .milliseconds(30), scheduler: RunLoop.main).sink { _ in
                for title in ["File", "Edit", "View"] {
                    if let menu = NSApp.mainMenu?.item(withTitle: title)?.submenu { menu.delegate?.menuNeedsUpdate?(menu) }
                }
            }
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard model.needsAttentionBeforeLeaving else { return true }
            model.resolvePendingChanges { DispatchQueue.main.async { sender.performClose(nil) } }
            return false
        }
    }
}
