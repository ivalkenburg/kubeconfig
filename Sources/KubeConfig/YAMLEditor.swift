import AppKit
import KubeConfigCore
import SwiftUI

enum YAMLStyle {
    /// Above this, recoloring on every keystroke costs more than the color is worth.
    static let highlightLimit = 2 * 1024 * 1024

    static func color(_ kind: YAMLHighlighter.Kind) -> NSColor {
        switch kind {
        case .key: return .systemBlue
        case .punctuation: return .tertiaryLabelColor
        case .string: return .systemGreen
        case .number: return .systemOrange
        case .keyword: return .systemPurple
        case .comment: return .secondaryLabelColor
        }
    }

    /// Read-only YAML for previews and diffs.
    static func attributed(_ text: String) -> AttributedString {
        guard text.utf8.count <= highlightLimit else { return AttributedString(text) }
        let units = Array(text.utf16)
        var result = AttributedString()
        var offset = 0
        func append(_ range: Range<Int>, _ kind: YAMLHighlighter.Kind?) {
            var piece = AttributedString(String(decoding: units[range], as: UTF16.self))
            if let kind { piece.foregroundColor = Color(nsColor: color(kind)) }
            result.append(piece)
        }
        for token in YAMLHighlighter.tokens(in: text) {
            append(offset..<token.range.lowerBound, nil)
            append(token.range, token.kind)
            offset = token.range.upperBound
        }
        append(offset..<units.count, nil)
        return result
    }
}

/// The full-file editor: NSTextView for attribute-level coloring, a line-number gutter, and its own undo.
struct YAMLEditor: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.font = Coordinator.font
        textView.textColor = .labelColor
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 6, height: 10)
        textView.setAccessibilityLabel("Kubeconfig YAML")
        textView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let ruler = LineNumberRuler(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        context.coordinator.attach(textView, scrollView: scrollView, ruler: ruler)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.sync(text: model.draftText, errorLine: model.parseIssueLine)
        context.coordinator.setWrapping(model.wrapsYAML)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        static let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        private let model: AppModel
        private let undo = UndoManager()
        private weak var textView: NSTextView?
        private weak var scrollView: NSScrollView?
        private weak var ruler: LineNumberRuler?
        private var wraps = false

        init(model: AppModel) {
            self.model = model
            super.init()
            for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange, .NSUndoManagerDidCloseUndoGroup] {
                NotificationCenter.default.addObserver(self, selector: #selector(undoStateChanged), name: name, object: undo)
            }
        }

        func attach(_ textView: NSTextView, scrollView: NSScrollView, ruler: LineNumberRuler) {
            self.textView = textView
            self.scrollView = scrollView
            self.ruler = ruler
            DispatchQueue.main.async { [weak self] in
                self?.model.rawEditor = textView
                self?.textView?.window?.makeFirstResponder(textView)
            }
        }

        func detach() {
            model.rawEditor = nil
            if model.rawCanUndo { model.rawCanUndo = false }
            if model.rawCanRedo { model.rawCanRedo = false }
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        /// Applies text from the model. Anything but the editor's own typing starts its undo over.
        func sync(text: String, errorLine: Int?) {
            guard let textView, let ruler else { return }
            if textView.string != text {
                textView.string = text
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                undo.removeAllActions()
                highlight()
                DispatchQueue.main.async { [weak self] in
                    self?.publishUndoState()
                    self?.showLineStarts()
                }
            }
            if ruler.errorLine != errorLine { ruler.errorLine = errorLine }
        }

        func setWrapping(_ wrap: Bool) {
            guard wrap != wraps, let textView, let scrollView, let container = textView.textContainer else { return }
            wraps = wrap
            let unlimited = CGFloat.greatestFiniteMagnitude
            let clip = scrollView.contentView
            let width = clip.bounds.width - clip.contentInsets.left
            scrollView.hasHorizontalScroller = !wrap
            textView.isHorizontallyResizable = !wrap
            container.widthTracksTextView = wrap
            container.containerSize = NSSize(width: wrap ? max(0, width - textView.textContainerInset.width * 2) : unlimited, height: unlimited)
            if wrap {
                textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
                showLineStarts()
            }
            ruler?.needsDisplay = true
        }

        /// The gutter sits in the clip view's inset, so that's where the text's left edge starts.
        /// A text view wider than the clip view otherwise opens scrolled to zero, with line starts behind the gutter.
        private func showLineStarts() {
            guard let scrollView else { return }
            let clip = scrollView.contentView
            clip.scroll(to: NSPoint(x: -clip.contentInsets.left, y: clip.bounds.minY))
            scrollView.reflectScrolledClipView(clip)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            highlight()
            model.editRaw(textView.string)
            publishUndoState()
        }

        @objc private func undoStateChanged() { publishUndoState() }

        private func publishUndoState() {
            if model.rawCanUndo != undo.canUndo { model.rawCanUndo = undo.canUndo }
            if model.rawCanRedo != undo.canRedo { model.rawCanRedo = undo.canRedo }
        }

        private func highlight() {
            guard let textView, let storage = textView.textStorage else { return }
            let text = storage.string
            let whole = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttributes([.font: Self.font, .foregroundColor: NSColor.labelColor], range: whole)
            if text.utf8.count <= YAMLStyle.highlightLimit {
                for token in YAMLHighlighter.tokens(in: text) {
                    storage.addAttribute(.foregroundColor, value: YAMLStyle.color(token.kind), range: NSRange(token.range))
                }
            }
            storage.endEditing()
            textView.typingAttributes = [.font: Self.font, .foregroundColor: NSColor.labelColor]
            ruler?.textDidChange()
        }
    }
}

final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private var lineStarts = [0]
    var errorLine: Int? { didSet { needsDisplay = true } }

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.frameDidChangeNotification, object: textView)
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func redraw() { needsDisplay = true }

    func textDidChange() {
        var starts = [0]
        for (index, unit) in (textView?.string ?? "").utf16.enumerated() where unit == 10 { starts.append(index + 1) }
        lineStarts = starts
        needsDisplay = true
    }

    /// One-based line containing a UTF-16 offset.
    private func line(at location: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= location { low = middle } else { high = middle - 1 }
        }
        return low + 1
    }

    // Replaces the default drawing, whose divider would run up under the toolbar.
    override func draw(_ dirtyRect: NSRect) { drawHashMarksAndLabels(in: dirtyRect) }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let origin = textView.textContainerOrigin
        let glyphs = layout.glyphRange(forBoundingRect: textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        layout.enumerateLineFragments(forGlyphRange: glyphs) { [self] fragment, _, _, range, _ in
            let location = layout.characterIndexForGlyph(at: range.location)
            let number = line(at: location)
            // A wrapped line is numbered once, on its first row.
            if lineStarts[number - 1] == location { draw(number: number, fragment: fragment, textView: textView) }
        }
        // The empty line after a trailing newline has no glyphs of its own.
        let extra = layout.extraLineFragmentRect
        if !extra.isEmpty { draw(number: lineStarts.count, fragment: extra, textView: textView) }
    }

    private func draw(number: Int, fragment: NSRect, textView: NSTextView) {
        let isError = number == errorLine
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: isError ? .bold : .regular),
            .foregroundColor: isError ? NSColor.systemRed : NSColor.tertiaryLabelColor,
        ]
        let label = "\(number)" as NSString
        let size = label.size(withAttributes: attributes)
        let top = convert(NSPoint(x: 0, y: fragment.minY + textView.textContainerOrigin.y), from: textView).y
        let y = top + (fragment.height - size.height) / 2
        label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y), withAttributes: attributes)
        if isError {
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: 5, y: top + (fragment.height - 6) / 2, width: 6, height: 6)).fill()
        }
    }
}
