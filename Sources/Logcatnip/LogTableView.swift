import AppKit
import LogcatKit
import os
import SwiftUI

/// The log table. AppKit's NSTableView keeps scrolling smooth with hundreds of thousands of rows, which
/// SwiftUI's Table does not.
struct LogTableView: NSViewRepresentable {
    let session: LogSession
    var fontSize: Double
    var showDate: Bool
    var wrapLines: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(session: session, fontSize: fontSize, showDate: showDate, wrapLines: wrapLines)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.unbind()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        enum Column: String, CaseIterable {
            case time, pid, tag, package, level, message

            var title: String {
                switch self {
                case .time: "Time"
                case .pid: "PID-TID"
                case .tag: "Tag"
                case .package: "Package"
                case .level: ""
                case .message: "Message"
                }
            }

            var menuTitle: String { self == .level ? "Level" : title }
            var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }
        }

        private var session: LogSession?
        private let tableView = LogNSTableView()
        private let scrollView = LogScrollView()
        private var font: NSFont?
        private var italicFont: NSFont?
        /// Advance of one character in the monospaced font, used to work out wrapped row heights without
        /// laying out text.
        private var charWidth: CGFloat = 7
        /// Height of one line of text in the font.
        private var textLineHeight: CGFloat = 15
        private var wrapLines = false
        /// Characters that fit on one wrapped line of the Message column; heights are recomputed when it changes.
        private var wrapColumns = 0
        private var heightUpdatePending = false
        private var showDate = false
        private var isProgrammaticScroll = false
        /// Lines longer than this many cells are cut off with an ellipsis when not wrapping, so one huge line
        /// cannot make the column (and the view behind it) enormous. The tooltip still has the whole line.
        static let maxMessageCells = 10_000
        /// Width, measured from the rendered text, of the widest message line whose width the monospaced
        /// arithmetic cannot know (tabs, wide characters, markers). The Message column is at least this wide.
        private var widestMessage: CGFloat = 0
        /// `session.widestLineCells` as of the last column sizing, so appends only resize when it grew.
        private var appliedWidestCells = 0
        private var messageWidthUpdatePending = false
        /// Whether the delegate answers `tableView(_:heightOfRow:)`. A table that has it may ask for the
        /// height of many rows when it reloads, which is wasted work for 500,000 equal rows, so it is hidden
        /// unless lines wrap. Lock-guarded because `responds(to:)` is nonisolated.
        private let heightOfRowEnabled = OSAllocatedUnfairLock(initialState: false)
        private var fullHeightPass: Task<Void, Never>?
        /// The wrap width every row's height was last computed for. Differs from `wrapColumns` while a resize
        /// is still being applied.
        private var heightsColumns = 0
        /// Paragraph styles for highlighted (attributed) cells, matching the line breaking of plain cells.
        private let truncatingStyle: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            return style
        }()
        private let wrappingStyle: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byCharWrapping
            return style
        }()

        func makeScrollView() -> NSScrollView {
            for column in Column.allCases {
                let tableColumn = NSTableColumn(identifier: column.identifier)
                tableColumn.title = column.title
                tableColumn.headerToolTip = column.menuTitle
                switch column {
                case .time: tableColumn.width = 96
                case .pid: tableColumn.width = 90
                case .tag: tableColumn.width = 150
                case .package: tableColumn.width = 190
                case .level:
                    tableColumn.width = 20
                    tableColumn.minWidth = 20
                    tableColumn.maxWidth = 20
                case .message:
                    tableColumn.width = 800
                    // Sized to its content (see updateMessageColumnWidth), so dragging it would be undone.
                    tableColumn.resizingMask = []
                    // The default cap would stop a 10,000-cell line at large font sizes.
                    tableColumn.maxWidth = 1_000_000
                }
                tableColumn.minWidth = min(tableColumn.minWidth, 20)
                tableView.addTableColumn(tableColumn)
            }
            tableView.style = .plain
            tableView.usesAutomaticRowHeights = false
            tableView.allowsMultipleSelection = true
            tableView.allowsColumnReordering = true
            tableView.allowsColumnResizing = true
            tableView.columnAutoresizingStyle = .noColumnAutoresizing
            tableView.intercellSpacing = NSSize(width: 6, height: 0)
            tableView.gridStyleMask = []
            tableView.dataSource = self
            tableView.delegate = self
            tableView.autosaveName = "LogTable"
            tableView.autosaveTableColumns = true
            tableView.copyHandler = { [weak self] in self?.copySelection() }
            tableView.cancelHandler = { [weak self] in
                guard let find = self?.session?.find, find.isVisible else { return false }
                find.hide()
                return true
            }

            let menu = NSMenu()
            menu.delegate = self
            tableView.menu = menu

            let headerMenu = NSMenu()
            headerMenu.delegate = self
            tableView.headerView?.menu = headerMenu

            scrollView.documentView = tableView
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            scrollView.contentView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(viewportDidResize(_:)),
                name: NSView.frameDidChangeNotification,
                object: scrollView.contentView
            )
            return scrollView
        }

        func update(session: LogSession, fontSize: Double, showDate: Bool, wrapLines: Bool) {
            var needsReload = false
            if self.session !== session {
                unbindSession()
                self.session = session
                session.onRowsChanged = { [weak self] change in self?.apply(change) }
                session.find.table = self
                session.find.onChange = { [weak self] change in self?.applyFind(change) }
                needsReload = true
            }
            if font.map({ Double($0.pointSize) }) != fontSize {
                let regular = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
                font = regular
                italicFont = NSFontManager.shared.convert(regular, toHaveTrait: .italicFontMask)
                tableView.rowHeight = ceil(fontSize * 1.5)
                charWidth = ("M" as NSString).size(withAttributes: [.font: regular]).width
                textLineHeight = Self.wrappedLineHeight(regular)
                needsReload = true
            }
            if self.wrapLines != wrapLines {
                self.wrapLines = wrapLines
                scrollView.hasHorizontalScroller = !wrapLines
                setHeightOfRowEnabled(wrapLines)
                if wrapLines {
                    let clipView = scrollView.contentView
                    clipView.scroll(to: NSPoint(x: 0, y: clipView.bounds.origin.y))
                    scrollView.reflectScrolledClipView(clipView)
                }
                needsReload = true
            }
            if self.showDate != showDate {
                self.showDate = showDate
                tableView.tableColumn(withIdentifier: Column.time.identifier)?.width = showDate ? 175 : 96
                updateMessageColumnWidth()
                needsReload = true
            }
            if needsReload {
                resetMessageWidth()
                wrapColumns = currentWrapColumns()
                reloadAll()
                updateFindMarkers()
                if session.autoScroll { scrollToEnd() }
            }
        }

        func unbind() {
            unbindSession()
            NotificationCenter.default.removeObserver(self)
        }

        private func unbindSession() {
            session?.onRowsChanged = nil
            session?.find.onChange = nil
            session?.find.table = nil
            fullHeightPass?.cancel()
        }

        // MARK: Updates

        private func apply(_ change: LogSession.RowsChange) {
            guard let session else { return }
            switch change {
            case .appended:
                tableView.noteNumberOfRowsChanged()
                // A long line may have arrived; the column is sized from the session's widest line, not from
                // the cells that happen to be on screen.
                if session.widestLineCells != appliedWidestCells { updateMessageColumnWidth() }
                updateFindMarkers()
                if session.autoScroll { scrollToEnd() }
            case let .reloaded(removedFront):
                let selectedIDs = selectedEntryIDs()
                let firstVisible = tableView.rows(in: tableView.visibleRect).location
                // Trimming the front of the buffer keeps the width so the view doesn't jump; a new filter
                // or a clear measures again.
                if removedFront == 0 { resetMessageWidth() }
                reloadAll()
                restoreSelection(selectedIDs)
                updateFindMarkers()
                if session.autoScroll {
                    scrollToEnd()
                } else if removedFront > 0 {
                    scroll(toRow: max(0, firstVisible - removedFront))
                } else if let firstSelected = tableView.selectedRowIndexes.first {
                    scroll(toRow: firstSelected)
                }
            case .refreshVisible:
                let visible = tableView.rows(in: tableView.visibleRect)
                guard visible.length > 0 else { return }
                tableView.reloadData(
                    forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                    columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
                )
            }
        }

        private func selectedEntryIDs() -> Set<Int> {
            guard let session else { return [] }
            var ids = Set<Int>()
            for index in tableView.selectedRowIndexes.prefix(5000) where index < session.rows.count {
                ids.insert(session.rows[index].entryID)
            }
            return ids
        }

        private func restoreSelection(_ ids: Set<Int>) {
            guard let session, !ids.isEmpty else { return }
            var indexes = IndexSet()
            for (index, row) in session.rows.enumerated() where ids.contains(row.entryID) {
                indexes.insert(index)
            }
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        }

        func scrollToEnd() {
            let count = tableView.numberOfRows
            guard count > 0 else { return }
            scroll(toRow: count - 1)
        }

        /// Scrolls vertically only, keeping the horizontal offset the user chose.
        private func scroll(toRow row: Int) {
            isProgrammaticScroll = true
            let clipView = scrollView.contentView
            let x = clipView.bounds.origin.x
            tableView.scrollRowToVisible(row)
            if clipView.bounds.origin.x != x {
                clipView.scroll(to: NSPoint(x: x, y: clipView.bounds.origin.y))
                scrollView.reflectScrolledClipView(clipView)
            }
            isProgrammaticScroll = false
        }

        /// Reloads every row. A reload makes any pending height pass redundant.
        private func reloadAll() {
            fullHeightPass?.cancel()
            heightsColumns = wrapColumns
            tableView.reloadData()
        }

        // MARK: Keeping the viewport

        private var viewportTop: CGFloat {
            let clip = scrollView.contentView
            return clip.bounds.minY + clip.contentInsets.top
        }

        /// Whether the end of the log is on screen: the test that decides whether to follow new logs.
        private var isScrolledToBottom: Bool {
            guard let document = scrollView.documentView else { return true }
            return scrollView.contentView.bounds.maxY >= document.frame.height - tableView.rowHeight * 1.5
        }

        /// The row to hold still across a change of row heights, and where it sits in the viewport.
        private func captureAnchor() -> ViewportAnchor? {
            guard let session else { return nil }
            let visible = tableView.rows(in: tableView.visibleRect)
            let anchor = ViewportAnchor.choose(
                selectedRows: tableView.selectedRowIndexes,
                visibleRows: visible.location..<(visible.location + visible.length),
                isFollowing: session.autoScroll
            )
            guard case let .row(row, _, _) = anchor else { return anchor }
            return anchor?.withOffset(Double(tableView.rect(ofRow: row).minY - viewportTop))
        }

        /// Scrolls so the anchored row is where it was (or, for a selected row, still on screen), after the
        /// heights above it changed. `settleFollow` also updates follow mode, which is state SwiftUI observes
        /// and so must not change while SwiftUI is updating the view.
        private func restore(_ anchor: ViewportAnchor, settleFollow: Bool) {
            guard let session else { return }
            switch anchor {
            case .end:
                scrollToEnd()
            case let .row(row, offset, keepInView):
                guard row < tableView.numberOfRows else { return }
                scrollView.tile()
                tableView.tile()
                let clip = scrollView.contentView
                let insets = clip.contentInsets
                let rect = tableView.rect(ofRow: row)
                let top = ViewportAnchor.restoredTop(
                    rowMinY: Double(rect.minY), rowHeight: Double(rect.height), offset: offset, keepInView: keepInView,
                    viewportHeight: Double(clip.bounds.height - insets.top - insets.bottom),
                    documentHeight: Double(tableView.frame.height)
                )
                isProgrammaticScroll = true
                let target = NSRect(x: clip.bounds.origin.x, y: CGFloat(top) - insets.top, width: clip.bounds.width, height: clip.bounds.height)
                clip.scroll(to: clip.constrainBoundsRect(target).origin)
                scrollView.reflectScrolledClipView(clip)
                isProgrammaticScroll = false
                // A selected row that was followed to the bottom may now be somewhere else.
                if settleFollow, keepInView, session.autoScroll != isScrolledToBottom {
                    session.autoScroll = isScrolledToBottom
                }
            }
        }

        // MARK: Message column width

        private func resetMessageWidth() {
            widestMessage = 0
            updateMessageColumnWidth()
        }

        /// Measures a rendered label. Only lines whose width the monospaced arithmetic cannot know need this
        /// (anything but printable ASCII), so the common line costs nothing here.
        private func noteMessageWidth(of label: NSTextField) {
            guard !wrapLines else { return }
            let width = min(ceil(label.attributedStringValue.size().width), CGFloat(Self.maxMessageCells) * charWidth)
            guard width > widestMessage else { return }
            widestMessage = width
            // Resizing a column while the table is asking for cell views would re-enter layout.
            guard !messageWidthUpdatePending else { return }
            messageWidthUpdatePending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                messageWidthUpdatePending = false
                updateMessageColumnWidth()
            }
        }

        /// Widens the Message column for a line that has not been rendered yet. Printable ASCII lines are
        /// already covered by the session's widest line.
        private func noteMessageWidth(ofRow row: LogSession.Row) {
            guard !row.span.isASCII else { return }
            let width = min(ceil(charWidth * CGFloat(row.span.cells)), CGFloat(Self.maxMessageCells) * charWidth)
            guard width > widestMessage else { return }
            widestMessage = width
            updateMessageColumnWidth()
        }

        /// Makes the Message column as wide as its widest line, and at least wide enough to fill the view.
        /// The width comes from the session's line widths, so a line is readable in full by scrolling before
        /// it has ever been drawn; lines whose width is only an estimate can widen it further once drawn.
        private func updateMessageColumnWidth() {
            guard let message = tableView.tableColumn(withIdentifier: Column.message.identifier) else { return }
            appliedWidestCells = session?.widestLineCells ?? 0
            let spacing = tableView.intercellSpacing.width
            let others = tableView.tableColumns.reduce(CGFloat(0)) { sum, column in
                column === message || column.isHidden ? sum : sum + column.width + spacing
            }
            let fill = scrollView.contentView.bounds.width - others - spacing
            let cap = CGFloat(Self.maxMessageCells) * charWidth
            let content = max(CGFloat(min(appliedWidestCells, Self.maxMessageCells)) * charWidth, min(widestMessage, cap))
            // Text fields inset their text by a few points on each side.
            let width = wrapLines ? max(fill, 100) : max(content + 8, fill, 100)
            if abs(message.width - width) >= 0.5 {
                message.width = width
            }
            if wrapLines { wrapWidthDidChange() }
        }

        // MARK: Wrapping

        /// Characters per wrapped line. Rounds down and leaves room for the text field's insets, so a
        /// row may get a little spare space but its text is never clipped.
        private func currentWrapColumns() -> Int {
            guard let message = tableView.tableColumn(withIdentifier: Column.message.identifier) else { return 1 }
            return max(1, Int((message.width - 8) / charWidth))
        }

        /// Measures what one more line adds to a wrapping label, which can differ from the font's line height
        /// by a point after rounding.
        private static func wrappedLineHeight(_ font: NSFont) -> CGFloat {
            let label = NSTextField(wrappingLabelWithString: "")
            label.font = font
            let bounds = NSRect(x: 0, y: 0, width: 1000, height: 100_000)
            label.stringValue = "a"
            let one = label.cell?.cellSize(forBounds: bounds).height ?? 0
            label.stringValue = Array(repeating: "a", count: 11).joined(separator: "\n")
            let eleven = label.cell?.cellSize(forBounds: bounds).height ?? 0
            return max(1, ceil((eleven - one) / 10))
        }

        /// The width the text wraps at changed. The rows on screen get their new heights on the next turn
        /// of the run loop, so a live resize re-wraps what is visible at once; every other row follows once
        /// the resizing settles, because heights for 500,000 rows are too much work for every frame.
        private func wrapWidthDidChange() {
            let columns = currentWrapColumns()
            guard columns != wrapColumns else { return }
            wrapColumns = columns
            // Coalesce: a live window resize changes the width many times per frame.
            guard !heightUpdatePending else { return }
            heightUpdatePending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                heightUpdatePending = false
                guard wrapLines, heightsColumns != wrapColumns else { return }
                let visible = tableView.rows(in: tableView.visibleRect)
                if visible.length > 0 {
                    noteHeightsChanged(IndexSet(integersIn: visible.location..<(visible.location + visible.length)))
                }
                scheduleFullHeightPass()
            }
        }

        private func noteHeightsChanged(_ rows: IndexSet) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                tableView.noteHeightOfRows(withIndexesChanged: rows)
            }
        }

        private func scheduleFullHeightPass() {
            fullHeightPass?.cancel()
            fullHeightPass = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.updateAllHeights()
            }
        }

        /// Recomputes every row's height, keeping the reading position or the selected row where it was.
        private func updateAllHeights() {
            let count = tableView.numberOfRows
            guard wrapLines, count > 0, let session else { return }
            let anchor = captureAnchor()
            heightsColumns = wrapColumns
            noteHeightsChanged(IndexSet(integersIn: 0..<count))
            if let anchor {
                restore(anchor, settleFollow: true)
            } else if session.autoScroll {
                scrollToEnd()
            }
        }

        /// A wrapped row is as tall as its lines need. Spans were measured when the rows were built, so this
        /// is an array read and some arithmetic: AppKit may call it for every row of a 500,000-row table.
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard wrapLines, let session, row < session.rows.count else { return tableView.rowHeight }
            let logRow = session.rows[row]
            // Markers are drawn with eight characters of dashes and spaces around the message.
            let lines = logRow.span.wrappedLineCount(columns: wrapColumns, extraCells: logRow.isMarker ? 8 : 0)
            guard lines > 1 else { return tableView.rowHeight }
            return tableView.rowHeight + CGFloat(lines - 1) * textLineHeight
        }

        /// Hides `tableView(_:heightOfRow:)` from AppKit while lines do not wrap: a table that is told there
        /// are no per-row heights never asks for them and keeps every row at `rowHeight`.
        nonisolated override func responds(to aSelector: Selector!) -> Bool {
            if aSelector == NSSelectorFromString("tableView:heightOfRow:") {
                return heightOfRowEnabled.withLock { $0 }
            }
            return super.responds(to: aSelector)
        }

        /// NSTableView looks at what its delegate responds to when the delegate is set, so the delegate is set
        /// again for the change to take effect. Callers reload right after.
        private func setHeightOfRowEnabled(_ enabled: Bool) {
            heightOfRowEnabled.withLock { $0 = enabled }
            tableView.delegate = nil
            tableView.delegate = self
        }

        @objc private func viewportDidResize(_ notification: Notification) {
            updateMessageColumnWidth()
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
                  column.identifier != Column.message.identifier
            else { return }
            updateMessageColumnWidth()
        }

        /// Scrolling away from the bottom stops following new logs; scrolling back to it resumes.
        @objc private func boundsDidChange(_ notification: Notification) {
            guard !isProgrammaticScroll, let session else { return }
            let atBottom = isScrolledToBottom
            if session.autoScroll != atBottom {
                session.autoScroll = atBottom
            }
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int {
            session?.rows.count ?? 0
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let session, let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue),
                  row < session.rows.count
            else { return nil }
            let logRow = session.rows[row]
            guard let entry = session.entry(for: logRow) else { return nil }

            if entry.kind == .marker {
                let label = makeLabel(column.identifier)
                if column == .message {
                    setWrapping(label)
                    label.stringValue = "——— \(entry.message) ———"
                    label.font = italicFont ?? label.font
                    label.textColor = .secondaryLabelColor
                    // The decoration around a marker's text is not in its span.
                    noteMessageWidth(of: label)
                } else {
                    label.stringValue = column == .time ? LogcatTime.format(entry.timestamp, includeDate: showDate) : ""
                    label.textColor = .tertiaryLabelColor
                }
                return label
            }

            let isFirstLine = logRow.line == 0
            if column == .level {
                let cell = makeBadge()
                let badge = cell.badge
                if isFirstLine {
                    badge.isHidden = false
                    badge.stringValue = entry.level.letter
                    badge.backgroundColor = LogColors.badgeBackground(for: entry.level)
                    badge.textColor = LogColors.badgeText(for: entry.level)
                } else {
                    badge.isHidden = true
                }
                return cell
            }

            let label = makeLabel(column.identifier)
            label.toolTip = nil
            switch column {
            case .time:
                label.stringValue = isFirstLine ? LogcatTime.format(entry.timestamp, includeDate: showDate) : ""
                label.textColor = .secondaryLabelColor
            case .pid:
                label.stringValue = isFirstLine ? "\(entry.pid)-\(entry.tid)" : ""
                label.textColor = .secondaryLabelColor
            case .tag:
                label.stringValue = isFirstLine ? entry.tag : ""
                label.textColor = LogColors.tag(entry.tag)
                label.toolTip = isFirstLine ? entry.tag : nil
                if isFirstLine { highlightMatches(in: label, text: entry.tag, row: row, wrapped: false) }
            case .package:
                let process = session.processName(for: entry)
                label.stringValue = isFirstLine ? (process ?? (entry.pid > 0 ? "pid-\(entry.pid)" : "")) : ""
                label.textColor = process == nil ? .tertiaryLabelColor : .secondaryLabelColor
                label.toolTip = isFirstLine ? process : nil
            case .message:
                setWrapping(label)
                let text = logRow.text(in: entry.message)
                label.stringValue = text
                label.textColor = LogColors.text(for: entry.level)
                if !wrapLines, logRow.span.cells > 120 { label.toolTip = text }
                highlightMatches(in: label, text: text, row: row, wrapped: wrapLines)
                if !logRow.span.isASCII { noteMessageWidth(of: label) }
            case .level:
                break
            }
            return label
        }

        private func makeLabel(_ identifier: NSUserInterfaceItemIdentifier) -> NSTextField {
            let label: NSTextField
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField {
                label = reused
            } else {
                label = NSTextField(labelWithString: "")
                label.identifier = identifier
                label.lineBreakMode = .byTruncatingTail
                label.maximumNumberOfLines = 1
                label.cell?.truncatesLastVisibleLine = true
                label.isSelectable = false
            }
            if let font { label.font = font }
            return label
        }

        /// Message labels wrap by character in wrap mode, matching the heights from heightOfRow.
        private func setWrapping(_ label: NSTextField) {
            label.maximumNumberOfLines = wrapLines ? 0 : 1
            label.cell?.wraps = wrapLines
            label.lineBreakMode = wrapLines ? .byCharWrapping : .byTruncatingTail
        }

        private func makeBadge() -> BadgeCellView {
            let cell: BadgeCellView
            if let reused = tableView.makeView(withIdentifier: Column.level.identifier, owner: nil) as? BadgeCellView {
                cell = reused
            } else {
                cell = BadgeCellView()
                cell.identifier = Column.level.identifier
            }
            cell.badgeHeight = tableView.rowHeight
            cell.badge.font = NSFont.monospacedSystemFont(ofSize: (font?.pointSize ?? 12) - 1, weight: .bold)
            return cell
        }

        // MARK: Find

        /// Gives the label an attributed string with every match highlighted. Rows that do not match keep
        /// the plain string, so scrolling past them costs one binary search.
        private func highlightMatches(in label: NSTextField, text: String, row: Int, wrapped: Bool) {
            guard let isCurrent = session?.find.highlight(forRow: row),
                  let ranges = session?.find.ranges(in: text), !ranges.isEmpty
            else { return }
            let attributed = NSMutableAttributedString(string: text, attributes: [
                .font: label.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: label.textColor ?? NSColor.labelColor,
                .paragraphStyle: wrapped ? wrappingStyle : truncatingStyle,
            ])
            let background = isCurrent ? LogColors.currentFindMatch : LogColors.findMatch
            for range in ranges {
                attributed.addAttributes([.backgroundColor: background, .foregroundColor: LogColors.findMatchText], range: range)
            }
            label.attributedStringValue = attributed
        }

        /// Redraws the visible cells after the matches changed.
        private func applyFind(_ change: FindChange) {
            let visible = tableView.rows(in: tableView.visibleRect)
            if visible.length > 0 {
                var rows = visible.location..<(visible.location + visible.length)
                if case let .rows(changed) = change { rows = rows.clamped(to: changed) }
                let columns = IndexSet([Column.tag, Column.message].map { tableView.column(withIdentifier: $0.identifier) }.filter { $0 >= 0 })
                if !rows.isEmpty, !columns.isEmpty {
                    tableView.reloadData(forRowIndexes: IndexSet(integersIn: rows), columnIndexes: columns)
                }
            }
            updateFindMarkers()
        }

        private func updateFindMarkers() {
            guard let session else { return }
            let find = session.find
            let markers = scrollView.markers
            markers.rowCount = session.rows.count
            markers.setRows(find.isActive ? find.results.rows : [], for: .findMatches, style: LogColors.findMarker)
            let current = find.currentRow.flatMap { find.isActive && find.results.contains($0) ? [$0] : nil } ?? []
            markers.setRows(current, for: .currentFindMatch, style: LogColors.currentFindMarker)
        }

        // MARK: Copy and menus

        func copySelection() {
            guard let session else { return }
            let indexes = tableView.selectedRowIndexes
            guard !indexes.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.text(forRows: indexes), forType: .string)
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            if menu === tableView.headerView?.menu {
                buildHeaderMenu(menu)
            } else {
                buildRowMenu(menu)
            }
        }

        private func buildHeaderMenu(_ menu: NSMenu) {
            for column in Column.allCases where column != .message {
                guard let tableColumn = tableView.tableColumn(withIdentifier: column.identifier) else { continue }
                let item = NSMenuItem(title: column.menuTitle, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = column.rawValue
                item.state = tableColumn.isHidden ? .off : .on
                menu.addItem(item)
            }
        }

        @objc private func toggleColumn(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String,
                  let column = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(raw))
            else { return }
            column.isHidden.toggle()
            updateMessageColumnWidth()
        }

        private func buildRowMenu(_ menu: NSMenu) {
            guard let session else { return }
            let clicked = tableView.clickedRow
            guard clicked >= 0, clicked < session.rows.count,
                  let entry = session.entry(for: session.rows[clicked])
            else { return }
            if !tableView.selectedRowIndexes.contains(clicked) {
                tableView.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
            }

            menu.addItem(item("Copy", #selector(copyRows)))
            menu.addItem(item("Copy Message", #selector(copyMessage), entry.message))
            guard entry.kind == .log else { return }

            menu.addItem(.separator())
            let tag = LogSession.quoted(entry.tag)
            menu.addItem(item("Show Only Tag “\(entry.tag)”", #selector(addTerm), "tag=:\(tag)"))
            menu.addItem(item("Hide Tag “\(entry.tag)”", #selector(addTerm), "-tag=:\(tag)"))
            if let process = session.processName(for: entry) {
                let package = LogEntry.packageName(forProcess: process)
                menu.addItem(item("Show Only Package “\(package)”", #selector(addTerm), "package=:\(LogSession.quoted(package))"))
                menu.addItem(item("Hide Package “\(package)”", #selector(addTerm), "-package=:\(LogSession.quoted(package))"))
            }
            menu.addItem(item("Show Only PID \(entry.pid)", #selector(addTerm), "pid:\(entry.pid)"))
            menu.addItem(item("Show Only TID \(entry.tid)", #selector(addTerm), "tid:\(entry.tid)"))
            menu.addItem(item("Show \(entry.level.name) and Above", #selector(setLevel), entry.level.rawValue))
        }

        private func item(_ title: String, _ action: Selector, _ value: Any? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = value
            return item
        }

        @objc private func copyRows() {
            copySelection()
        }

        @objc private func copyMessage(_ sender: NSMenuItem) {
            guard let message = sender.representedObject as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message, forType: .string)
        }

        @objc private func addTerm(_ sender: NSMenuItem) {
            guard let term = sender.representedObject as? String else { return }
            session?.addTerm(term)
        }

        @objc private func setLevel(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? Int, let level = LogLevel(rawValue: raw) else { return }
            session?.setMinimumLevel(level)
        }
    }
}

/// Holds the level badge at the top of its row, one line tall, so wrapped rows don't stretch it.
final class BadgeCellView: NSView {
    let badge: NSTextField = {
        let badge = NSTextField(labelWithString: "")
        badge.alignment = .center
        badge.drawsBackground = true
        badge.isBezeled = false
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 3
        return badge
    }()

    var badgeHeight: CGFloat = 18 {
        didSet { if badgeHeight != oldValue { needsLayout = true } }
    }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        addSubview(badge)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        badge.frame = NSRect(x: 0, y: 0, width: bounds.width, height: min(badgeHeight, bounds.height))
    }
}

/// Routes Edit > Copy (⌘C) and Esc to the coordinator.
final class LogNSTableView: NSTableView {
    var copyHandler: (() -> Void)?
    /// Called on Esc; returns whether it handled the key (it closes the find bar).
    var cancelHandler: (() -> Bool)?

    override func cancelOperation(_ sender: Any?) {
        if cancelHandler?() == true { return }
        super.cancelOperation(sender)
    }

    @objc func copy(_ sender: Any?) {
        copyHandler?()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return selectedRow >= 0
        }
        return super.validateUserInterfaceItem(item)
    }
}

extension LogTableView.Coordinator: FindTableNavigating {
    var findAnchor: FindAnchor {
        let selected = tableView.selectedRowIndexes
        if let first = selected.first, let last = selected.last { return .selection(first...last) }
        let visible = tableView.rows(in: tableView.visibleRect)
        if visible.length > 0 { return .viewport(visible.location...(visible.location + visible.length - 1)) }
        return .none
    }

    var selectedRowIndexes: IndexSet { tableView.selectedRowIndexes }

    /// Selects the row alone, stops following new logs, and scrolls it to the vertical centre unless it is
    /// fully visible already. Without wrapping, also scrolls sideways when the first highlight is out of
    /// sight.
    func revealFindMatch(row: Int, highlight: NSRange?) {
        guard let session, row >= 0, row < tableView.numberOfRows else { return }
        session.autoScroll = false
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

        let clip = scrollView.contentView
        let bounds = clip.bounds
        let insets = clip.contentInsets
        let viewportTop = bounds.minY + insets.top
        let viewportBottom = bounds.maxY - insets.bottom
        let rowRect = tableView.rect(ofRow: row)
        var origin = bounds.origin
        if rowRect.minY < viewportTop || rowRect.maxY > viewportBottom {
            origin.y = rowRect.midY - (viewportBottom - viewportTop) / 2 - insets.top
        }
        if !wrapLines, let highlight, row < session.rows.count, let line = currentMessageLine(row: row) {
            // A line whose width is only an estimate may not have been drawn yet, so widen the column
            // first or the scroll would stop at the old edge.
            noteMessageWidth(ofRow: session.rows[row])
            let column = tableView.column(withIdentifier: Column.message.identifier)
            if column >= 0 {
                let prefix = (line as NSString).substring(to: highlight.location)
                let matched = (line as NSString).substring(with: highlight)
                // The text starts a few points inside its cell.
                let x = tableView.rect(ofColumn: column).minX + 4 + charWidth * CGFloat(MessageLines.cells(prefix))
                let width = charWidth * CGFloat(MessageLines.cells(matched))
                if x < bounds.minX || x + width > bounds.maxX {
                    origin.x = max(0, x - 40)
                }
            }
        }
        guard origin != bounds.origin else { return }
        isProgrammaticScroll = true
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
        isProgrammaticScroll = false
    }

    private func currentMessageLine(row: Int) -> String? {
        guard let session, row < session.rows.count, let entry = session.entry(for: session.rows[row]) else { return nil }
        return session.rows[row].text(in: entry.message)
    }

    func focusTable() {
        tableView.window?.makeFirstResponder(tableView)
    }
}
