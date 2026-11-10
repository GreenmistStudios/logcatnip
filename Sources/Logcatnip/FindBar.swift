import AppKit
import SwiftUI

/// The find bar under the filter bar. Searches the rows the table shows.
struct FindBar: View {
    @Bindable var find: FindController

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            FindField(find: find, query: find.query, focusRequest: find.focusRequest)
                .frame(minWidth: 120)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(find.error == nil ? Color(nsColor: .separatorColor) : .red, lineWidth: 1)
                )

            Text(counterText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(find.error == nil ? Color.secondary : Color.red)
                .lineLimit(1)
                .frame(minWidth: 90, alignment: .trailing)
                .help(find.error?.message ?? "")

            Button {
                find.navigate(.previous)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(find.matchCount == 0)
            .help("Previous match (⇧⌘G)")

            Button {
                find.navigate(.next)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(find.matchCount == 0)
            .help("Next match (⌘G)")

            Toggle(isOn: $find.matchCase) {
                Text("Aa").font(.system(.body, design: .monospaced))
            }
            .toggleStyle(.button)
            .help("Match case")

            Toggle(isOn: $find.regex) {
                Text(".*").font(.system(.body, design: .monospaced))
            }
            .toggleStyle(.button)
            .help("Regular expression")

            Toggle(isOn: $find.wholeWord) {
                Text("ab").underline().font(.system(.body, design: .monospaced))
            }
            .toggleStyle(.button)
            .help("Whole word")

            Button("Done") { find.hide() }
                .help("Close (Esc)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var counterText: String {
        if let error = find.error { return error.message }
        if find.query.isEmpty { return "" }
        if find.matchCount == 0 { return find.isSearching ? "Searching…" : "No matches" }
        if let index = find.currentIndex { return "\((index + 1).formatted()) of \(find.matchCount.formatted())" }
        return find.matchCount == 1 ? "1 match" : "\(find.matchCount.formatted()) matches"
    }
}

/// An AppKit text field, because SwiftUI's `onSubmit` cannot tell Return from ⇧Return, and Esc has to close
/// the bar instead of reaching the window.
struct FindField: NSViewRepresentable {
    let find: FindController
    /// Read by the bar so a change re-runs `updateNSView`.
    let query: String
    let focusRequest: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(find: find)
    }

    func makeNSView(context: Context) -> FindNSTextField {
        let field = FindNSTextField()
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.placeholderString = "Find in results"
        field.stringValue = query
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: FindNSTextField, context: Context) {
        // The query changes from outside when ⌘E fills it in.
        if let editor = field.currentEditor() as? NSTextView {
            if editor.string != query { editor.string = query }
        } else if field.stringValue != query {
            field.stringValue = query
        }
        if find.handledFocusRequest != focusRequest {
            find.handledFocusRequest = focusRequest
            field.focus()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let find: FindController

        init(find: FindController) {
            self.find = find
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            find.query = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertLineBreak(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
                find.navigate(shift ? .previous : .next)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                find.hide()
                return true
            default:
                return false
            }
        }
    }
}

final class FindNSTextField: NSTextField {
    private var pendingFocus = false

    /// Takes focus and selects the text. When the field is not in a window yet, waits until it is.
    func focus() {
        guard window != nil else {
            pendingFocus = true
            return
        }
        window?.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard pendingFocus, window != nil else { return }
        pendingFocus = false
        // The window may still be assembling its responder chain.
        DispatchQueue.main.async { [weak self] in self?.focus() }
    }
}
