import AppKit
import LogcatKit

/// The suggestion list under the filter field: a borderless child panel that never takes key status, so the
/// field keeps the keyboard while the list is open.
@MainActor
final class CompletionPanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate {
    static let rowHeight: CGFloat = 20
    private static let maxVisibleRows = 12
    private static let widthRange: ClosedRange<CGFloat> = 220...560

    var onAccept: ((FilterSuggestion) -> Void)?
    private(set) var suggestions: [FilterSuggestion] = []

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let labelFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    private let detailFont = NSFont.systemFont(ofSize: 11)

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        let background = NSVisualEffectView()
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true
        contentView = background

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("suggestion"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = .zero
        tableView.refusesFirstResponder = true
        tableView.allowsEmptySelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.frame = background.bounds
        scrollView.autoresizingMask = [.width, .height]
        background.addSubview(scrollView)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var isShown: Bool { isVisible }

    var selected: FilterSuggestion? {
        let row = tableView.selectedRow
        return suggestions.indices.contains(row) ? suggestions[row] : nil
    }

    /// Shows the list under `anchor`, a screen rectangle around the text being completed, or above it when the
    /// screen has no room below. The first row is selected on every update, as in a menu.
    func show(_ suggestions: [FilterSuggestion], below anchor: NSRect, in parent: NSWindow) {
        self.suggestions = suggestions
        tableView.reloadData()
        tableView.selectRowIndexes([0], byExtendingSelection: false)
        tableView.scrollRowToVisible(0)

        let size = NSSize(
            width: width(for: suggestions),
            height: CGFloat(min(suggestions.count, Self.maxVisibleRows)) * Self.rowHeight
        )
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - size.height - 2)
        if let visible = (parent.screen ?? NSScreen.main)?.visibleFrame {
            if origin.y < visible.minY { origin.y = anchor.maxY + 2 }
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        }
        setFrame(NSRect(origin: origin, size: size), display: true)
        if !isVisible {
            parent.addChildWindow(self, ordered: .above)
        }
    }

    func hide() {
        guard isVisible else { return }
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    func moveSelection(by delta: Int) {
        guard !suggestions.isEmpty else { return }
        let row = min(max(tableView.selectedRow + delta, 0), suggestions.count - 1)
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    /// Wide enough for the longest label and detail, within a range that keeps the list readable.
    private func width(for suggestions: [FilterSuggestion]) -> CGFloat {
        var widest: CGFloat = 0
        for suggestion in suggestions {
            let label = (suggestion.label as NSString).size(withAttributes: [.font: labelFont]).width
            let detail = suggestion.detail.map { ($0 as NSString).size(withAttributes: [.font: detailFont]).width } ?? 0
            widest = max(widest, label + detail + 40)
        }
        return min(max(widest.rounded(.up), Self.widthRange.lowerBound), Self.widthRange.upperBound)
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard suggestions.indices.contains(row) else { return }
        onAccept?(suggestions[row])
    }

    // MARK: NSTableViewDataSource, NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { suggestions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("suggestionCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? SuggestionCell)
            ?? SuggestionCell(identifier: identifier, labelFont: labelFont, detailFont: detailFont)
        let suggestion = suggestions[row]
        cell.label.stringValue = suggestion.label
        cell.detail.stringValue = suggestion.detail ?? ""
        return cell
    }
}

/// One row: the label in the field's font, the detail dimmed and right-aligned.
private final class SuggestionCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier, labelFont: NSFont, detailFont: NSFont) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.font = labelFont
        label.lineBreakMode = .byTruncatingTail
        detail.font = detailFont
        detail.textColor = .secondaryLabelColor
        detail.alignment = .right
        detail.lineBreakMode = .byTruncatingTail
        for field in [label, detail] {
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
            field.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
