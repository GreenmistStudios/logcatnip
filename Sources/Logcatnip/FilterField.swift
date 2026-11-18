import AppKit
import LogcatKit
import SwiftUI

/// The filter field. SwiftUI's `TextField` cannot color its text, underline part of it or report the caret, so
/// this wraps a single-line `NSTextView` and shows suggestions in a child panel.
struct FilterField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    /// Take focus when this changes (⌘F).
    let focusRequest: Int
    let suggestions: @MainActor (_ query: String, _ cursor: Int) -> [FilterSuggestion]
    let onSubmit: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        // Built from the parts so it uses TextKit 1, whose temporary attributes the highlighting relies on.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let textView = FilterTextView(frame: .zero, textContainer: container)
        textView.coordinator = coordinator
        textView.placeholder = placeholder
        textView.delegate = coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isFieldEditor = false
        // Smart quotes and dashes would rewrite the `"` and `-` the filter language depends on.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.font = FilterTextView.fieldFont
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Filter")

        let scrollView = FilterScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none

        coordinator.textView = textView
        coordinator.lastFocusRequest = focusRequest
        textView.string = text
        coordinator.applyHighlighting()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        textView.placeholder = placeholder
        if textView.string != text {
            // Changed from outside the field: the context menu, the level picker, the clear button, a saved filter.
            textView.string = text
            textView.undoManager?.removeAllActions(withTarget: textView)
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            coordinator.hidePanel()
            coordinator.applyHighlighting()
            textView.needsDisplay = true
        }
        if focusRequest != coordinator.lastFocusRequest {
            coordinator.lastFocusRequest = focusRequest
            textView.window?.makeFirstResponder(textView)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let height = ceil(NSLayoutManager().defaultLineHeight(for: FilterTextView.fieldFont))
        return CGSize(width: proposal.width ?? 200, height: height)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSViewToolTipOwner {
        var parent: FilterField
        weak var textView: FilterTextView?
        var lastFocusRequest = 0
        private var panel: CompletionPanel?
        private var isApplying = false
        private var errorMessage: String?
        private weak var observedWindow: NSWindow?

        init(_ parent: FilterField) {
            self.parent = parent
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if parent.text != textView.string { parent.text = textView.string }
            applyHighlighting()
            if panel?.isShown == true { refreshPanel() }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if panel?.isShown == true, !isApplying { refreshPanel() }
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            // A filter is one line: pasted line breaks become spaces.
            guard let string = replacementString, string.contains(where: \.isNewline) else { return true }
            textView.insertText(String(string.map { $0.isNewline ? " " : $0 }), replacementRange: range)
            return false
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let visible = panel?.isShown == true
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                guard visible else { return false }
                panel?.moveSelection(by: -1)
            case #selector(NSResponder.moveDown(_:)):
                guard visible else { return false }
                panel?.moveSelection(by: 1)
            case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)):
                guard visible else { return false }
                panel?.moveSelection(by: -10)
            case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)):
                guard visible else { return false }
                panel?.moveSelection(by: 10)
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                if let suggestion = visible ? panel?.selected : nil {
                    accept(suggestion)
                } else {
                    hidePanel()
                    parent.onSubmit()
                }
            case #selector(NSResponder.insertTab(_:)):
                if let suggestion = visible ? panel?.selected : nil {
                    accept(suggestion)
                } else {
                    hidePanel()
                    textView.window?.selectNextKeyView(nil)
                }
            case #selector(NSResponder.insertBacktab(_:)):
                hidePanel()
                textView.window?.selectPreviousKeyView(nil)
            case #selector(NSResponder.cancelOperation(_:)):
                // NSTextView would turn Esc into `complete:`. Esc closes the list; ⌥Esc opens it.
                hidePanel()
            case #selector(NSResponder.complete(_:)), #selector(NSResponder.setMark(_:)):
                showCompletions(forced: true)
            default:
                return false
            }
            return true
        }

        // MARK: Completion

        /// Called after the user typed a character: open the list when the caret is in a value or a key that has
        /// something typed, and close it otherwise. It never opens by itself in an empty field or after a space.
        func didType() {
            guard !isApplying, let textView, !textView.hasMarkedText() else { return }
            showCompletions(forced: false)
        }

        /// Computes suggestions at the caret and shows them under the text they would replace. A key position with
        /// nothing typed only opens when asked for (`forced`): it would otherwise pop up after every space.
        func showCompletions(forced: Bool) {
            guard let textView, !textView.hasMarkedText(), textView.window != nil else { return }
            let query = textView.string
            let offsets = FilterTextOffsets(query)
            let cursor = offsets.character(forUTF16: textView.selectedRange().location)
            if !forced {
                let context = FilterCompletion.completionContext(query: query, cursor: cursor)
                switch context.kind {
                case .none: hidePanel(); return
                case .key: if context.prefix.isEmpty { hidePanel(); return }
                case .value: break
                }
            }
            let list = parent.suggestions(query, cursor)
            guard let first = list.first, let window = textView.window else {
                hidePanel()
                return
            }
            // Under the start of the text being replaced; a whole-field history replacement starts at the caret.
            let anchorOffset = first.kind == .history ? cursor : first.replacement.lowerBound
            let anchor = textView.screenRect(ofUTF16Offset: offsets.utf16(anchorOffset))
            let panel = ensurePanel()
            observe(window)
            panel.show(list, below: anchor, in: window)
        }

        private func refreshPanel() {
            guard !isApplying, let textView, !textView.hasMarkedText() else { return }
            showCompletions(forced: false)
        }

        private func ensurePanel() -> CompletionPanel {
            if let panel { return panel }
            let panel = CompletionPanel()
            panel.onAccept = { [weak self] suggestion in self?.accept(suggestion) }
            self.panel = panel
            return panel
        }

        func hidePanel() {
            panel?.hide()
        }

        func accept(_ suggestion: FilterSuggestion) {
            guard let textView else { return }
            let offsets = FilterTextOffsets(textView.string)
            isApplying = true
            // Through the text view, so the edit is undoable and the delegate hears about it.
            textView.insertText(suggestion.insertion, replacementRange: offsets.nsRange(suggestion.replacement))
            isApplying = false
            hidePanel()
            // A key leaves the caret where its value goes, so offer the values straight away.
            if suggestion.kind == .key { showCompletions(forced: false) }
        }

        // MARK: Window

        private func observe(_ window: NSWindow) {
            guard observedWindow !== window else { return }
            if let observedWindow {
                NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: observedWindow)
            }
            observedWindow = window
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidResignKey(_:)), name: NSWindow.didResignKeyNotification, object: window
            )
        }

        @objc private func windowDidResignKey(_ notification: Notification) {
            hidePanel()
        }

        func tearDown() {
            NotificationCenter.default.removeObserver(self)
            observedWindow = nil
            panel?.hide()
            panel?.close()
            panel = nil
        }

        // MARK: Highlighting

        /// Colors the field from the lexer, which keeps going past errors, and underlines what the parser rejects.
        /// It parses the field's own text so the underline always matches what is shown; the border and the status
        /// bar keep using the session's debounced filter error.
        func applyHighlighting() {
            guard let textView, let layoutManager = textView.layoutManager else { return }
            let string = textView.string
            let offsets = FilterTextOffsets(string)
            let full = NSRange(location: 0, length: (string as NSString).length)
            for key in [NSAttributedString.Key.foregroundColor, .underlineStyle, .underlineColor] {
                layoutManager.removeTemporaryAttribute(key, forCharacterRange: full)
            }
            let highlighting = FilterSyntax.highlighting(for: string)
            for span in highlighting.spans {
                guard let color = Self.color(for: span.kind) else { continue }
                layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: offsets.nsRange(span.range))
            }

            textView.removeAllToolTips()
            errorMessage = highlighting.error?.message
            guard let error = highlighting.error, let range = error.range else { return }
            let nsRange = offsets.nsRange(range)
            layoutManager.addTemporaryAttributes([
                .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                .underlineColor: NSColor.systemRed,
            ], forCharacterRange: nsRange)
            if let container = textView.textContainer {
                let glyphs = layoutManager.glyphRange(forCharacterRange: nsRange, actualCharacterRange: nil)
                var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
                rect.origin.x += textView.textContainerOrigin.x
                rect.origin.y += textView.textContainerOrigin.y
                rect.size.width = max(rect.width, 6)
                textView.addToolTip(rect, owner: self, userData: nil)
            }
        }

        private static func color(for kind: FilterSyntaxSpan.Kind) -> NSColor? {
            switch kind {
            case .key: .systemPurple
            case .logicalOperator, .parenthesis: .systemOrange
            case .quotedValue, .quotedText: .systemRed
            case .regexValue: .systemTeal
            case .value, .text: nil
            }
        }

        nonisolated func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
            MainActor.assumeIsolated { errorMessage ?? "" }
        }
    }
}

/// Keeps the text view as tall as the line and at least as wide as the field, so clicking anywhere in the field
/// puts the caret in it.
private final class FilterScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let textView = documentView as? NSTextView else { return }
        let size = contentSize
        textView.minSize = NSSize(width: size.width, height: size.height)
        if textView.frame.height != size.height || textView.frame.width < size.width {
            textView.setFrameSize(NSSize(width: max(textView.frame.width, size.width), height: size.height))
        }
    }
}

/// A single-line text view: no wrapping, no scrolling past the line, and a placeholder.
final class FilterTextView: NSTextView {
    static let fieldFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    weak var coordinator: FilterField.Coordinator?
    var placeholder = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, !hasMarkedText() else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.fieldFont, .foregroundColor: NSColor.placeholderTextColor]
        let origin = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y)
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }

    /// ⌃Space, which Android Studio uses. macOS may reserve it for switching input sources; ⌥Esc always works.
    override func keyDown(with event: NSEvent) {
        let controlOnly = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control
        if event.keyCode == 49, controlOnly {
            coordinator?.showCompletions(forced: true)
            return
        }
        super.keyDown(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        coordinator?.didType()
    }

    override func resignFirstResponder() -> Bool {
        coordinator?.hidePanel()
        return super.resignFirstResponder()
    }

    /// The screen rectangle of the character at a UTF-16 offset, or of the insertion point at the end.
    func screenRect(ofUTF16Offset offset: Int) -> NSRect {
        let range = NSRange(location: min(offset, (string as NSString).length), length: 0)
        var rect = firstRect(forCharacterRange: range, actualRange: nil)
        // The start of the replaced text may be scrolled out of the field; keep the list over the field.
        if let window, let clip = enclosingScrollView?.contentView {
            let field = window.convertToScreen(clip.convert(clip.bounds, to: nil))
            rect.origin.x = min(max(rect.origin.x, field.minX), field.maxX)
            rect.origin.y = field.minY
            rect.size.height = field.height
        }
        return rect
    }
}
