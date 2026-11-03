import AppKit
import KubeConfigCore
import SwiftTerm
import SwiftUI

extension K9sAppearance {
    var nativeAppearance: NSAppearance { NSAppearance(named: self == .light ? .aqua : .darkAqua)! }

    /// Resolve semantic colors once so running sessions keep their launch appearance.
    var backgroundColor: NSColor { resolved(.textBackgroundColor) }
    var foregroundColor: NSColor { resolved(.textColor) }

    private func resolved(_ color: NSColor) -> NSColor {
        var result = color
        nativeAppearance.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.deviceRGB) ?? color
        }
        return result
    }
}

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
    private let backgroundUpdates = DispatchSource.makeUserDataAddSource(queue: .main)
    var onExit: ((Int32?) -> Void)?
    var view: NSView { terminal }

    init() {
        terminal.processDelegate = self
        terminal.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        backgroundUpdates.setEventHandler { [weak self] in self?.matchScreenBackground() }
        backgroundUpdates.resume()
        let updates = backgroundUpdates
        terminal.setProcessOutputHandler { updates.add(data: 1) }
    }

    deinit { backgroundUpdates.cancel() }

    func start(_ launch: K9sLaunch) {
        terminal.appearance = launch.appearance.nativeAppearance
        terminal.nativeBackgroundColor = launch.appearance.backgroundColor
        terminal.nativeForegroundColor = launch.appearance.foregroundColor
        terminal.startProcess(executable: launch.executable, args: launch.arguments, environment: launch.environment,
                              currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    func stop() { terminal.terminate() }

    /// k9s paints true-color cells with SGR instead of setting the default background with OSC 11.
    /// Match a full-screen fill so the inset and partial final row/column share the skin's color.
    private func matchScreenBackground() {
        guard let snapshot = terminal.terminalContentSnapshot(region: .viewport) else { return }
        var backgrounds: [Attribute.Color: Int] = [:]
        var count = 0
        for row in snapshot.rows {
            for cell in row.cells {
                let attribute = cell.attribute
                let background = attribute.style.contains(.inverse) ? attribute.fg : attribute.bg
                backgrounds[background, default: 0] += 1
                count += 1
            }
        }
        // A selection, border or status bar must not replace the skin's background.
        guard let dominant = backgrounds.max(by: { $0.value < $1.value }), dominant.value > count / 2,
              case let .trueColor(red, green, blue) = dominant.key else { return }
        let color = NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        guard let current = terminal.nativeBackgroundColor.usingColorSpace(.sRGB),
              abs(current.redComponent - color.redComponent) > 0.0001 ||
                abs(current.greenComponent - color.greenComponent) > 0.0001 ||
                abs(current.blueComponent - color.blueComponent) > 0.0001 else { return }
        terminal.nativeBackgroundColor = color
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { onExit?(exitCode) }
    func processFailedToStart(source: TerminalView, error: LocalProcessError) { onExit?(nil) }
}

/// Shows the model's terminal, adopting it from whichever pane last held it.
struct K9sTerminalHost: NSViewRepresentable {
    let terminal: NSView
    let appearance: K9sAppearance
    let takeFocusRequest: () -> Bool

    func makeNSView(context: Context) -> Container { Container() }

    func updateNSView(_ container: Container, context: Context) {
        container.takeFocusRequest = takeFocusRequest
        container.appearance = appearance.nativeAppearance
        container.wantsLayer = true
        guard terminal.superview !== container else { return }
        terminal.removeFromSuperview()
        terminal.appearance = appearance.nativeAppearance
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            terminal.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])
        container.followBackground(of: terminal, fallback: appearance.backgroundColor)
        container.focusIfRequested()
    }

    final class Container: NSView {
        var takeFocusRequest: (() -> Bool)?
        private var backgroundObservation: NSKeyValueObservation?

        /// SwiftTerm updates its backing layer for native colors, OSC changes and reverse video.
        /// Follow that color so the inset stays continuous with the terminal without polling.
        func followBackground(of terminal: NSView, fallback: NSColor) {
            backgroundObservation = nil
            layer?.backgroundColor = fallback.cgColor
            backgroundObservation = terminal.layer?.observe(\.backgroundColor, options: [.initial, .new]) { [weak self] layer, _ in
                self?.layer?.backgroundColor = layer.backgroundColor ?? fallback.cgColor
            }
        }

        override func willRemoveSubview(_ subview: NSView) {
            backgroundObservation = nil
            super.willRemoveSubview(subview)
        }

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
                    restartButton("Restart")
                    Button("Back", action: model.closeK9s)
                }
            }
            switch session.freshness {
            case .changed:
                NoticeBar(text: "This context changed on disk, so k9s may be out of date.") {
                    restartButton("Restart")
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
                    restartButton("Try Again").buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                K9sTerminalHost(terminal: session.terminal.view, appearance: session.appearance,
                                takeFocusRequest: { model.takeK9sFocusRequest(for: session.id) })
                    .id(session.id)
                    .accessibilityLabel("k9s terminal for \(session.contextName)")
            }
        }
    }

    private func restartButton(_ title: String) -> some View {
        let blockReason = model.k9sRestartBlockReason
        return Button(title, action: model.restartK9s).disabled(blockReason != nil).help(blockReason ?? "")
    }

    private static let installCommand = "brew install k9s"
}
