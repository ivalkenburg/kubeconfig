import AppKit
import KubeConfigCore
import SwiftTerm
import SwiftUI

/// A terminal running k9s. The model owns it, so it outlives the pane that shows it.
@MainActor protocol K9sTerminal: AnyObject {
    var view: NSView { get }
    /// Called with the exit status, or nil if a signal ended it or it couldn't start.
    var onExit: ((Int32?) -> Void)? { get set }
    func start(_ launch: K9sLaunch)
    func stop()
}

@MainActor final class K9sTerminalProcess: K9sTerminal, LocalProcessTerminalViewDelegate {
    private let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    var onExit: ((Int32?) -> Void)?
    var view: NSView { terminal }

    init() {
        terminal.processDelegate = self
        terminal.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        // k9s draws for a dark terminal, so this stays dark in Light Mode. DESIGN.md records the exception.
        terminal.nativeBackgroundColor = NSColor(srgbRed: 0.08, green: 0.09, blue: 0.10, alpha: 1)
        terminal.nativeForegroundColor = NSColor(srgbRed: 0.88, green: 0.89, blue: 0.90, alpha: 1)
    }

    func start(_ launch: K9sLaunch) {
        terminal.startProcess(executable: launch.executable, args: launch.arguments, environment: launch.environment,
                              currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    func stop() { terminal.terminate() }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { onExit?(exitCode) }
    func processFailedToStart(source: TerminalView, error: LocalProcessError) { onExit?(nil) }
}

/// Shows the model's terminal, adopting it from whichever pane last held it.
struct K9sTerminalHost: NSViewRepresentable {
    let terminal: NSView
    let takeFocusRequest: () -> Bool

    func makeNSView(context: Context) -> Container { Container() }

    func updateNSView(_ container: Container, context: Context) {
        container.takeFocusRequest = takeFocusRequest
        guard terminal.superview !== container else { return }
        terminal.removeFromSuperview()
        terminal.frame = container.bounds
        terminal.autoresizingMask = [.width, .height]
        container.addSubview(terminal)
        container.focusIfRequested()
    }

    final class Container: NSView {
        var takeFocusRequest: (() -> Bool)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            focusIfRequested()
        }

        /// Selecting the context in the list only shows k9s, so the arrow keys stay with the list.
        func focusIfRequested() {
            guard window != nil, !subviews.isEmpty, takeFocusRequest?() == true else { return }
            // Waits a turn, because the window has to hold the whole view tree before focus can land in it.
            DispatchQueue.main.async { [weak self] in
                guard let self, let terminal = self.subviews.first else { return }
                self.window?.makeFirstResponder(terminal)
            }
        }
    }
}

struct K9sDetailView: View {
    @ObservedObject var model: AppModel
    let session: K9sSession

    var body: some View {
        VStack(spacing: 0) {
            if case let .exited(code) = session.phase {
                NoticeBar(text: code.map { "k9s exited with status \($0)." } ?? "k9s stopped unexpectedly.") {
                    Button("Restart", action: model.restartK9s)
                        .disabled(restartBlockReason != nil).help(restartBlockReason ?? "")
                    Button("Back", action: model.closeK9s)
                }
            }
            switch session.freshness {
            case .changed:
                NoticeBar(text: "This context changed on disk, so k9s may be out of date.") {
                    Button("Restart", action: model.restartK9s)
                        .disabled(restartBlockReason != nil).help(restartBlockReason ?? "")
                }
            case .removed:
                NoticeBar(text: "This context is no longer in the file.") {
                    Button("Close", action: model.closeK9s)
                }
            case .unchanged: EmptyView()
            }
            if session.phase == .missing {
                ContentUnavailableView {
                    Label("k9s isn’t installed", systemImage: "terminal")
                } description: {
                    Text("Install it with Homebrew, then try again.")
                } actions: {
                    Text(Self.installCommand).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Button("Copy Command") { model.copyToPasteboard(Self.installCommand) }
                    Button("Try Again", action: model.restartK9s).buttonStyle(.borderedProminent)
                        .disabled(restartBlockReason != nil).help(restartBlockReason ?? "")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                K9sTerminalHost(terminal: session.terminal.view, takeFocusRequest: model.takeK9sFocusRequest)
                    .id(session.id)
                    .accessibilityLabel("k9s terminal for \(session.contextName)")
            }
        }
    }

    private var restartBlockReason: String? { model.k9sRestartBlockReason }
    private static let installCommand = "brew install k9s"
}
