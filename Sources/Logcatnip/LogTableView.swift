import AppKit
import LogcatKit
import os
import SwiftUI

/// The log table. AppKit's NSTableView keeps scrolling smooth with hundreds of thousands of rows, which
/// SwiftUI's Table does not.
struct LogTableView: NSViewRepresentable {
    let session: LogSession
    var fontSize: Double
    var viewOptions: LogViewOptions
    var wrapLines: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(session: session, fontSize: fontSize, viewOptions: viewOptions, wrapLines: wrapLines)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.unbind()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        typealias Column = LogColumn

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
        /// The options the columns were last set up for; nil until the first update.
        private var viewOptions: LogViewOptions?
        /// Produces every cell's text, rebuilt whenever the options change.
        private var formatter = LogLineFormatter(options: .standard)
        /// True while the options are being applied to the columns, so the resizes that causes are not taken
        /// for the user dragging a column edge.
        private var isApplyingOptions = false
        private var appliedSizes: SizeKey?
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
        /// How far the Message column's text is scrolled sideways while lines do not wrap. The table itself
        /// never scrolls sideways, so the other columns stay put (see `MessageCellView`).
        private var messageScroll = MessageScroll()
        /// Which axis the scroll gesture in progress belongs to, so a sideways swipe never also moves the rows.
        private var axisLock = ScrollAxisLock()
        private var scrollMonitor: Any?
        /// True while the Message scroller is being set from `messageScroll`, so that is not taken for the user
        /// dragging it.
        private var isSyncingScroller = false
        /// Whether the delegate answers `tableView(_:heightOfRow:)`. A table that has it may ask for the
        /// height of many rows when it reloads, which is wasted work for 500,000 equal rows, so it is hidden
        /// unless lines wrap. Lock-guarded because `responds(to:)` is nonisolated.
        private let heightOfRowEnabled = OSAllocatedUnfairLock(initialState: false)
        private var fullHeightPass: Task<Void, Never>?
        /// The wrap width every row's height was last computed for. Differs from `wrapColumns` while a resize
        /// is still being applied.
        private var heightsColumns = 0
        /// How often AppKit asked for a row height since launch; stays 0 while lines do not wrap.
        private var heightCalls = 0
        /// `LOGCATNIP_DEBUG=1` times reloads and height passes for the table's debug summary.
        static let debugEnabled = ProcessInfo.processInfo.environment["LOGCATNIP_DEBUG"] == "1"
        private var lastReload: (rows: Int, milliseconds: Double)?
        private var lastHeightPass: Duration?
        private var lastAnchor: (row: Int, before: Double, after: Double)?
        /// Paragraph styles for highlighted (attributed) cells, matching the line breaking of plain cells.
        private let truncatingStyle: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            return style
        }()
        private let middleTruncatingStyle: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingMiddle
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
                case .process: tableColumn.width = 190
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
            // A layout saved before the Process column existed restores it after Message, where it would sit
            // off screen behind the widest column. Put it back after Package.
            let processIndex = tableView.column(withIdentifier: Column.process.identifier)
            let levelIndex = tableView.column(withIdentifier: Column.level.identifier)
            if processIndex > tableView.column(withIdentifier: Column.message.identifier), levelIndex >= 0 {
                tableView.moveColumn(processIndex, toColumn: levelIndex)
            }
            tableView.copyHandler = { [weak self] in self?.copySelection() }
            tableView.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
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
            // The table is as wide as the view, so this scroller only shows when the window is narrower than
            // the pinned columns; the Message column has its own (see `LogScrollView`).
            scrollView.hasHorizontalScroller = true
            scrollView.horizontalScrollElasticity = .none
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
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(messageScrollerDidScroll(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.messageScroller.contentView
            )
            // Sideways gestures are taken here rather than in a `scrollWheel(with:)` override of the scroll
            // view, because a subclass that overrides it loses responsive scrolling, which keeps 500,000 rows
            // smooth.
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, MainActor.assumeIsolated({ self.handleScrollWheel(event) }) else { return event }
                return nil
            }
            return scrollView
        }

        func update(session: LogSession, fontSize: Double, viewOptions: LogViewOptions, wrapLines: Bool) {
            var needsReload = false
            var fontChanged = false
            // The viewport is captured before anything changes, while the old heights are still in place.
            var anchor: ViewportAnchor?
            var selection = IndexSet()
            if self.session === session {
                selection = tableView.selectedRowIndexes
                if self.wrapLines != wrapLines { anchor = captureAnchor() }
            }
            if self.session !== session {
                unbindSession()
                self.session = session
                session.onRowsChanged = { [weak self] change in self?.apply(change) }
                session.find.table = self
                session.find.onChange = { [weak self] change in self?.applyFind(change) }
                session.tableDebug = self
                // The new session's options may equal the old one's, but the columns were not set up for them.
                self.viewOptions = nil
                needsReload = true
            }
            if font.map({ Double($0.pointSize) }) != fontSize {
                let regular = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
                font = regular
                italicFont = NSFontManager.shared.convert(regular, toHaveTrait: .italicFontMask)
                tableView.rowHeight = ceil(fontSize * 1.5)
                charWidth = ("M" as NSString).size(withAttributes: [.font: regular]).width
                textLineHeight = Self.wrappedLineHeight(regular)
                fontChanged = true
                needsReload = true
            }
            if self.wrapLines != wrapLines {
                self.wrapLines = wrapLines
                setHeightOfRowEnabled(wrapLines)
                // Wrapped text has no sideways extent, and the unwrapped text starts at its left edge.
                setMessageOffset(0, flash: false)
                let clipView = scrollView.contentView
                clipView.scroll(to: NSPoint(x: 0, y: clipView.bounds.origin.y))
                scrollView.reflectScrolledClipView(clipView)
                needsReload = true
            }
            if self.viewOptions != viewOptions || fontChanged {
                // Column widths come from the options and the font, so a font change redoes them too. A change
                // of widths alone (a drag, or choosing a preset with other widths) leaves every cell as it was.
                let widthsOnly = !fontChanged && (self.viewOptions.map { viewOptions.differsOnlyInWidths(from: $0) } ?? false)
                self.viewOptions = viewOptions
                formatter = LogLineFormatter(options: viewOptions)
                applyViewOptions()
                if !widthsOnly { needsReload = true }
            }
            if needsReload {
                resetMessageWidth()
                wrapColumns = currentWrapColumns()
                reloadAll()
                // Reloading drops the selection; the rows are the same ones, so it can simply be put back.
                if !selection.isEmpty { tableView.selectRowIndexes(selection, byExtendingSelection: false) }
                updateFindMarkers()
                if let anchor {
                    restore(anchor, settleFollow: false)
                    // SwiftUI may still lay out after this update, so settle again once it is done.
                    DispatchQueue.main.async { [weak self] in
                        self?.restore(anchor, settleFollow: true)
                    }
                } else if session.autoScroll {
                    scrollToEnd()
                }
            }
        }

        func unbind() {
            unbindSession()
            NotificationCenter.default.removeObserver(self)
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            scrollMonitor = nil
        }

        private func unbindSession() {
            session?.onRowsChanged = nil
            session?.find.onChange = nil
            session?.find.table = nil
            session?.tableDebug = nil
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

        /// Reloads every row. With `LOGCATNIP_DEBUG=1` it also forces all row heights and times the reload,
        /// because computing them is what wrapping costs.
        private func reloadAll() {
            // The reload computes every height, so a pending pass would only repeat it.
            fullHeightPass?.cancel()
            heightsColumns = wrapColumns
            guard Self.debugEnabled else {
                tableView.reloadData()
                return
            }
            let started = ContinuousClock.now
            tableView.reloadData()
            let count = tableView.numberOfRows
            if count > 0 { _ = tableView.rect(ofRow: count - 1) }
            lastReload = (count, Self.milliseconds(ContinuousClock.now - started))
        }

        private static func milliseconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
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
                lastAnchor = (row, offset, Double(tableView.rect(ofRow: row).minY - viewportTop))
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

        /// Sizes the Message column to fill what the other columns leave, so the table is exactly as wide as the
        /// view and never scrolls sideways. The text is as wide as the session's widest line, and scrolls inside
        /// the column (see `messageScroll`). The width comes from the session's line widths, so a line is
        /// readable in full by scrolling before it has ever been drawn; lines whose width is only an estimate
        /// can widen it further once drawn.
        private func updateMessageColumnWidth() {
            guard let message = tableView.tableColumn(withIdentifier: Column.message.identifier) else { return }
            appliedWidestCells = session?.widestLineCells ?? 0
            let spacing = tableView.intercellSpacing.width
            let others = tableView.tableColumns.reduce(CGFloat(0)) { sum, column in
                column === message || column.isHidden ? sum : sum + column.width + spacing
            }
            // Rounded down so a fraction of a point never makes the table wider than the view, which would
            // bring back the whole-table scroller.
            let fill = floor(scrollView.contentView.bounds.width - others - spacing)
            let cap = CGFloat(Self.maxMessageCells) * charWidth
            let content = max(CGFloat(min(appliedWidestCells, Self.maxMessageCells)) * charWidth, min(widestMessage, cap))
            // Text fields inset their text by a few points on each side.
            let textWidth = content + 8
            // A window narrower than the other columns plus 100 points has no room to pin them. The table then
            // overflows, and the whole table scrolls sideways with a Message column as wide as its text.
            let pinsColumns = fill >= Self.minimumMessageWidth
            let width = pinsColumns ? fill : wrapLines ? Self.minimumMessageWidth : max(textWidth, Self.minimumMessageWidth)
            if abs(message.width - width) >= 0.5 {
                message.width = width
            }
            setMessageContent(width: wrapLines || !pinsColumns ? 0 : textWidth, viewport: width)
            if wrapLines { wrapWidthDidChange() }
            updateMessageScrollerSpan()
        }

        /// The least the Message column is given before the other columns stop being pinned.
        private static let minimumMessageWidth: CGFloat = 100

        // MARK: Sideways scrolling

        /// Takes the new text and column widths. The offset is pulled back into range, and the Message
        /// scroller follows.
        private func setMessageContent(width: CGFloat, viewport: CGFloat) {
            let oldOffset = messageScroll.offset
            let oldWidth = messageScroll.contentWidth
            let wasScrollable = messageScroll.isScrollable
            messageScroll.resize(contentWidth: Double(width), viewportWidth: Double(viewport))
            if messageScroll.contentWidth != oldWidth {
                forEachMessageCell { $0.contentWidth = width }
            }
            if messageScroll.offset != oldOffset {
                applyMessageOffset()
                syncMessageScroller()
            }
            // Legacy scrollers take a band of their own at the bottom, which changes what the last row has.
            if wasScrollable != messageScroll.isScrollable, session?.autoScroll == true {
                DispatchQueue.main.async { [weak self] in
                    if self?.session?.autoScroll == true { self?.scrollToEnd() }
                }
            }
        }

        /// The Message cells that exist now (the ones on screen, plus a few the table keeps ready).
        private func forEachMessageCell(_ body: (MessageCellView) -> Void) {
            let index = tableView.column(withIdentifier: Column.message.identifier)
            guard index >= 0 else { return }
            tableView.enumerateAvailableRowViews { rowView, _ in
                if let cell = rowView.view(atColumn: index) as? MessageCellView { body(cell) }
            }
        }

        private func applyMessageOffset() {
            let offset = CGFloat(messageScroll.offset)
            forEachMessageCell { $0.offset = offset }
        }

        /// Moves the message text to `x` points from its start, kept within its range. Only the text moves:
        /// no row is redrawn and no cell is made.
        private func setMessageOffset(_ x: Double, flash: Bool) {
            guard messageScroll.scroll(to: x) else { return }
            applyMessageOffset()
            syncMessageScroller()
            if flash { scrollView.messageScroller.flashScrollers() }
        }

        /// Sets the Message scroller's position to the offset without taking that for a drag.
        private func syncMessageScroller() {
            let strip = scrollView.messageScroller
            let target = NSPoint(x: messageScroll.offset, y: 0)
            guard abs(strip.contentView.bounds.origin.x - target.x) > 0.01 else { return }
            isSyncingScroller = true
            strip.contentView.scroll(to: target)
            strip.reflectScrolledClipView(strip.contentView)
            isSyncingScroller = false
        }

        /// The Message scroller was dragged or paged: move the text with it.
        @objc private func messageScrollerDidScroll(_ notification: Notification) {
            guard !isSyncingScroller else { return }
            if messageScroll.scroll(to: scrollView.messageScroller.contentView.bounds.minX) {
                applyMessageOffset()
            }
        }

        /// Shows the Message scroller under the column when its text can scroll, and sets how far.
        private func updateMessageScrollerSpan() {
            let strip = scrollView.messageScroller
            let column = tableView.column(withIdentifier: Column.message.identifier)
            guard !wrapLines, messageScroll.isScrollable, column >= 0 else {
                scrollView.messageSpan = nil
                return
            }
            strip.setTravel(CGFloat(messageScroll.maxOffset))
            let rect = tableView.rect(ofColumn: column)
            scrollView.messageSpan = LogScrollView.MessageSpan(minX: rect.minX, width: rect.width)
            syncMessageScroller()
        }

        /// The Message column moved (dragged to another position), and the scroller moves with it.
        func tableViewColumnDidMove(_ notification: Notification) {
            updateMessageScrollerSpan()
        }

        /// Sideways trackpad and shift-wheel gestures over the log move the message text, not the table.
        /// Returns whether it took the event; everything else goes on to the scroll view untouched.
        private func handleScrollWheel(_ event: NSEvent) -> Bool {
            guard let window = scrollView.window, event.window === window else { return false }
            let inside = scrollView.bounds.contains(scrollView.convert(event.locationInWindow, from: nil))
            return handleScroll(
                dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY),
                precise: event.hasPreciseScrollingDeltas, phase: Self.lockPhase(event.phase),
                momentum: Self.lockPhase(event.momentumPhase), inside: inside
            )
        }

        private static func lockPhase(_ phase: NSEvent.Phase) -> ScrollAxisLock.Phase {
            if phase.contains(.mayBegin) { return .mayBegin }
            if phase.contains(.began) { return .began }
            if phase.contains(.changed) { return .changed }
            if phase.contains(.stationary) { return .stationary }
            if phase.contains(.ended) { return .ended }
            if phase.contains(.cancelled) { return .cancelled }
            return .none
        }

        /// The scroll decision for one event, apart from the event itself so the debug helper can drive it.
        /// A gesture that began over the log keeps moving the text after the pointer leaves it.
        fileprivate func handleScroll(
            dx: Double, dy: Double, precise: Bool, phase: ScrollAxisLock.Phase, momentum: ScrollAxisLock.Phase, inside: Bool
        ) -> Bool {
            let phased = phase != .none || momentum != .none
            if !inside, !(phased && axisLock.locked == .horizontal) {
                if phase == .began { axisLock = ScrollAxisLock() }
                return false
            }
            if wrapLines || !messageScroll.isScrollable {
                axisLock = ScrollAxisLock()
                return false
            }
            guard axisLock.axis(deltaX: dx, deltaY: dy, phase: phase, momentumPhase: momentum) == .horizontal else { return false }
            // A mouse wheel reports lines; three characters per line, like a text view.
            let points = precise ? dx : dx * 3 * Double(charWidth)
            setMessageOffset(messageScroll.offset - points, flash: true)
            return true
        }

        // MARK: View options

        /// Points a text column needs beyond its characters: the cell's inset on both sides.
        private static let columnPadding: CGFloat = 10

        private func columnWidth(characters: Int) -> CGFloat {
            ceil(CGFloat(characters) * charWidth) + Self.columnPadding
        }

        /// What the Time column's header says for a style, and for the zone of the clock styles.
        private static func timeTitle(_ options: LogViewOptions) -> String {
            switch options.timestampStyle {
            case .dateTime, .time: options.timeZone == .utc ? "Time (UTC)" : "Time"
            case .epoch: "Epoch"
            case .sinceStart: "Since Start"
            case .delta: "Δ Time"
            }
        }

        /// Shows and hides the columns, titles them, and sizes them from the session's view options.
        /// Tag, package and process widths are stored in characters, so they follow the font; Time and PID
        /// are sized for the longest text their style prints.
        private func applyViewOptions() {
            guard let options = viewOptions else { return }
            isApplyingOptions = true
            defer { isApplyingOptions = false }
            for column in Column.allCases where column != .message {
                tableView.tableColumn(withIdentifier: column.identifier)?.isHidden = !options.isVisible(column)
            }
            // These two sizes are reset by a change of style or font only, so a width the user dragged to
            // survives unrelated changes such as hiding repeats.
            let sizeKey = SizeKey(time: options.timestampStyle, pid: options.pidStyle, charWidth: charWidth)
            let resize = appliedSizes != sizeKey
            appliedSizes = sizeKey
            if let time = tableView.tableColumn(withIdentifier: Column.time.identifier) {
                time.title = Self.timeTitle(options)
                time.headerToolTip = options.timestampStyle.explanation
                if resize { time.width = ceil(CGFloat(options.timestampStyle.sampleCells) * charWidth) + 12 }
            }
            if let pid = tableView.tableColumn(withIdentifier: Column.pid.identifier) {
                pid.title = options.pidStyle == .pid ? "PID" : "PID-TID"
                if resize { pid.width = ceil(CGFloat(options.pidStyle.sampleCells) * charWidth) + 12 }
            }
            for column in [Column.tag, .package, .process] {
                guard let tableColumn = tableView.tableColumn(withIdentifier: column.identifier),
                      let characters = options.width(of: column)
                else { continue }
                tableColumn.minWidth = columnWidth(characters: LogViewOptions.widthRange.lowerBound)
                tableColumn.maxWidth = columnWidth(characters: LogViewOptions.widthRange.upperBound)
                let target = columnWidth(characters: characters)
                // A drag writes its width back as whole characters, up to half a character and a point from
                // where the mouse is; do not snap the edge under it.
                if abs(tableColumn.width - target) > charWidth / 2 + 1 { tableColumn.width = target }
            }
            updateMessageColumnWidth()
        }

        private struct SizeKey: Equatable {
            let time: TimestampStyle
            let pid: PidStyle
            let charWidth: CGFloat
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
            let started = ContinuousClock.now
            heightsColumns = wrapColumns
            noteHeightsChanged(IndexSet(integersIn: 0..<count))
            if Self.debugEnabled {
                _ = tableView.rect(ofRow: count - 1)
                lastHeightPass = ContinuousClock.now - started
            }
            if let anchor {
                restore(anchor, settleFollow: true)
            } else if session.autoScroll {
                scrollToEnd()
            }
        }

        /// A wrapped row is as tall as its lines need. Spans were measured when the rows were built, so this
        /// is an array read and some arithmetic: AppKit may call it for every row of a 500,000-row table.
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            heightCalls += 1
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
            // Dragging the edge of a Tag, Package or Process column is a change to the view, which makes it
            // Custom; the width is stored in characters.
            if !isApplyingOptions, let session, let kind = Column(rawValue: column.identifier.rawValue),
               let stored = session.viewOptions.width(of: kind)
            {
                let characters = Int(((column.width - Self.columnPadding) / charWidth).rounded())
                if characters != stored { session.viewOptions.setWidth(characters, of: kind) }
            }
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
                if column == .message {
                    let cell = makeMessageCell()
                    let label = cell.label
                    setWrapping(label)
                    label.stringValue = "——— \(entry.message) ———"
                    label.font = italicFont ?? label.font
                    label.textColor = .secondaryLabelColor
                    // The decoration around a marker's text is not in its span.
                    noteMessageWidth(of: label)
                    return cell
                }
                let label = makeLabel(column.identifier)
                label.stringValue = column == .time ? cellText(.time, for: entry, row: row, in: session) : ""
                label.textColor = .tertiaryLabelColor
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

            if column == .message {
                let cell = makeMessageCell()
                let label = cell.label
                label.toolTip = nil
                setWrapping(label)
                let text = logRow.text(in: entry.message)
                label.stringValue = text
                label.textColor = LogColors.text(for: entry.level)
                if !wrapLines, logRow.span.cells > 120 { label.toolTip = text }
                highlightMatches(in: label, text: text, row: row, style: wrapLines ? wrappingStyle : truncatingStyle)
                if !logRow.span.isASCII { noteMessageWidth(of: label) }
                return cell
            }

            let label = makeLabel(column.identifier)
            label.toolTip = nil
            switch column {
            case .time:
                label.stringValue = isFirstLine ? cellText(.time, for: entry, row: row, in: session) : ""
                label.textColor = .secondaryLabelColor
            case .pid:
                label.stringValue = isFirstLine ? cellText(.pid, for: entry, row: row, in: session) : ""
                label.textColor = .secondaryLabelColor
            case .tag:
                let text = isFirstLine ? cellText(.tag, for: entry, row: row, in: session) : ""
                label.stringValue = text
                label.textColor = viewOptions?.colorTags == false ? .secondaryLabelColor : LogColors.tag(entry.tag)
                label.toolTip = isFirstLine ? entry.tag : nil
                // A tag blanked as a repeat has nothing to highlight.
                if !text.isEmpty { highlightMatches(in: label, text: text, row: row, style: middleTruncatingStyle) }
            case .package:
                configurePackageCell(label, for: entry, row: row, in: session, isFirstLine: isFirstLine)
            case .process:
                label.stringValue = isFirstLine ? cellText(.process, for: entry, row: row, in: session) : ""
                label.textColor = .secondaryLabelColor
                label.toolTip = isFirstLine ? session.processName(for: entry) : nil
            case .message, .level:
                break
            }
            return label
        }

        /// The text of one cell, from the formatter that also produces copied lines. The entry above is only
        /// looked up when the column needs it (delta time, or hiding repeats), and it is the entry of the row
        /// above, so filtering and trimming are already accounted for.
        private func cellText(_ column: Column, for entry: LogEntry, row: Int, in session: LogSession) -> String {
            let previous = formatter.needsPrevious(column) ? session.previousEntry(beforeRow: row) : nil
            return formatter.text(
                column, for: entry, previous: previous, sessionStart: session.startTimestamp,
                processName: { session.processName(for: $0) }
            )
        }

        /// The Package cell: the package of the process, `pid-N` in a dimmer color until the process is known.
        private func configurePackageCell(_ label: NSTextField, for entry: LogEntry, row: Int, in session: LogSession, isFirstLine: Bool) {
            guard isFirstLine else {
                label.stringValue = ""
                return
            }
            let process = session.processName(for: entry)
            label.stringValue = cellText(.package, for: entry, row: row, in: session)
            label.textColor = process == nil ? .tertiaryLabelColor : .secondaryLabelColor
            label.toolTip = process
        }

        /// The Message cell, set up for the current mode and sideways position. Its label is configured by the
        /// caller, and reuse never hands back a stale font, tooltip or offset.
        private func makeMessageCell() -> MessageCellView {
            let cell: MessageCellView
            if let reused = tableView.makeView(withIdentifier: Column.message.identifier, owner: nil) as? MessageCellView {
                cell = reused
            } else {
                cell = MessageCellView()
                cell.identifier = Column.message.identifier
            }
            if let font { cell.label.font = font }
            cell.wraps = wrapLines
            cell.contentWidth = CGFloat(messageScroll.contentWidth)
            cell.offset = wrapLines ? 0 : CGFloat(messageScroll.offset)
            return cell
        }

        /// Tags are cut in the middle and package and process names at the front, so the part that tells them
        /// apart stays visible (Android Studio does the same). The Message column has its own cell.
        private func makeLabel(_ identifier: NSUserInterfaceItemIdentifier) -> NSTextField {
            let label: NSTextField
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField {
                label = reused
            } else {
                label = NSTextField(labelWithString: "")
                label.identifier = identifier
                switch identifier {
                case Column.tag.identifier: label.lineBreakMode = .byTruncatingMiddle
                case Column.package.identifier, Column.process.identifier: label.lineBreakMode = .byTruncatingHead
                default: label.lineBreakMode = .byTruncatingTail
                }
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
        private func highlightMatches(in label: NSTextField, text: String, row: Int, style: NSParagraphStyle) {
            guard let isCurrent = session?.find.highlight(forRow: row),
                  let ranges = session?.find.ranges(in: text), !ranges.isEmpty
            else { return }
            let attributed = NSMutableAttributedString(string: text, attributes: [
                .font: label.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: label.textColor ?? NSColor.labelColor,
                .paragraphStyle: style,
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

        // MARK: Keyboard

        /// ←/→ move the message text sideways by eight characters, ⌘←/⌘→ to its start and end, when long lines
        /// scroll instead of wrapping and the table has focus. In a window too narrow to pin the other columns
        /// they scroll the whole table instead. Returns whether it handled the key.
        func handleKey(_ event: NSEvent) -> Bool {
            guard !wrapLines, let key = event.specialKey else { return false }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let move: MessageScroll.Move
            switch (key, modifiers) {
            case (.leftArrow, []): move = .left
            case (.rightArrow, []): move = .right
            case (.leftArrow, .command): move = .start
            case (.rightArrow, .command): move = .end
            default: return false
            }
            let step = Double(8 * charWidth)
            if messageScroll.isScrollable {
                setMessageOffset(messageScroll.offset(after: move, step: step), flash: true)
                return true
            }
            let clip = scrollView.contentView
            guard !tableFits else { return false }
            let maxX = tableView.frame.width - clip.bounds.width
            var x = clip.bounds.origin.x
            switch move {
            case .left: x -= step
            case .right: x += step
            case .start: x = 0
            case .end: x = maxX
            }
            let target = NSRect(x: min(max(0, x), maxX), y: clip.bounds.origin.y, width: clip.bounds.width, height: clip.bounds.height)
            clip.scroll(to: clip.constrainBoundsRect(target).origin)
            scrollView.reflectScrolledClipView(clip)
            return true
        }

        /// Whether the table is no wider than the view, so it has no sideways scrolling of its own.
        fileprivate var tableFits: Bool {
            tableView.frame.width <= scrollView.contentView.bounds.width + 0.5
        }

        // MARK: Copy and menus

        func copySelection() {
            guard !tableView.selectedRowIndexes.isEmpty, let text = copyText(forRows: tableView.selectedRowIndexes) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        /// The text Copy puts on the pasteboard: the visible columns in the order they are shown, so a pasted
        /// line reads like the table.
        fileprivate func copyText(forRows rows: IndexSet) -> String? {
            guard let session else { return nil }
            let columns = tableView.tableColumns.filter { !$0.isHidden }.compactMap { Column(rawValue: $0.identifier.rawValue) }
            return session.text(forRows: rows, columns: columns, formatter: formatter)
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
            guard let options = session?.viewOptions else { return }
            for column in Column.allCases where column != .message {
                let item = NSMenuItem(title: column.menuTitle, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = column.rawValue
                item.state = options.isVisible(column) ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
            for preset in LogViewOptions.Preset.allCases {
                let item = NSMenuItem(title: preset.menuTitle, action: #selector(choosePreset(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = preset.rawValue
                item.state = options.preset == preset ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
            menu.addItem(item("Modify View…", #selector(modifyView)))
        }

        /// Columns are part of the session's view options, so hiding one makes the view Custom.
        @objc private func toggleColumn(_ sender: NSMenuItem) {
            guard let session, let raw = sender.representedObject as? String, let column = Column(rawValue: raw) else { return }
            session.viewOptions.setVisible(column, !session.viewOptions.isVisible(column))
        }

        @objc private func choosePreset(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String, let preset = LogViewOptions.Preset(rawValue: raw) else { return }
            session?.viewOptions = preset.options
        }

        @objc private func modifyView() {
            session?.isModifyingView = true
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

private extension LogColumn {
    var title: String {
        switch self {
        case .time: "Time"
        case .pid: "PID-TID"
        case .tag: "Tag"
        case .package: "Package"
        case .process: "Process"
        case .level: ""
        case .message: "Message"
        }
    }

    var menuTitle: String {
        switch self {
        case .pid: "PID"
        case .level: "Level"
        default: title
        }
    }

    var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }
}

private extension TimestampStyle {
    /// The header's tooltip: what the column's text counts from.
    var explanation: String {
        switch self {
        case .dateTime: "Date and time of the log line (device clock)"
        case .time: "Time of the log line (device clock)"
        case .epoch: "Seconds since 1970 (device clock)"
        case .sinceStart: "Seconds since the first line of this session"
        case .delta: "Time since the previous visible line"
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
    /// Offered every key press first; returns whether it handled the key (sideways scrolling).
    var keyHandler: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

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
    /// fully visible already. Without wrapping, it also moves the message text sideways when the first
    /// highlight is out of sight.
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
            let prefix = (line as NSString).substring(to: highlight.location)
            let matched = (line as NSString).substring(with: highlight)
            // The text starts a few points inside its cell, and while the other columns are pinned the table itself
            // does not scroll sideways.
            let x = 4 + Double(charWidth) * Double(MessageLines.cells(prefix))
            let width = Double(charWidth) * Double(MessageLines.cells(matched))
            if messageScroll.isScrollable {
                if let target = messageScroll.offsetRevealing(x: x, width: width, margin: 40) {
                    setMessageOffset(target, flash: false)
                }
            } else if !tableFits {
                // Too narrow to pin the other columns: the whole table scrolls, as the column is as wide as the text.
                let column = tableView.column(withIdentifier: Column.message.identifier)
                if column >= 0 {
                    let left = tableView.rect(ofColumn: column).minX + CGFloat(x)
                    if left < bounds.minX || left + CGFloat(width) > bounds.maxX {
                        origin.x = max(0, left - 40)
                    }
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

/// What the table reports for `LOGCATNIP_DEBUG` runs, so the soft wrap behavior can be checked from a
/// terminal without looking at the screen.
@MainActor
protocol LogTableDebugging: AnyObject {
    func debugSummary() -> String
    /// Selects `row` alone and scrolls it to `fraction` of the way down the viewport (0 top, 1 bottom);
    /// `following` keeps follow mode.
    func debugSelect(row: Int, at fraction: Double, following: Bool)
    func debugScrollBenchmark(pages: Int) -> String
    /// Sends ←, →, ⌘→ and ⌘← to the table and reports the message offset after each, and whether the other
    /// columns stayed put.
    func debugPressArrowKeys() -> String
    /// Drives sideways scroll gestures, a mouse wheel and a drag of the Message scroller through the same
    /// code the real events use, and reports what each did to the message offset.
    func debugMessageScroll() -> String
    /// `pinned=ok`, or the first way the other columns moved with the message.
    func debugPinned() -> String
    /// The view options, the column order, and the cells on screen, checked against the formatter.
    func debugViewSummary() -> String
    /// What Copy would put on the pasteboard for the last `entries` entries, one per line, with newlines
    /// inside a message written as `\n`.
    func debugCopyText(entries: Int) -> String
}

extension LogTableView.Coordinator: LogTableDebugging {
    /// One line of table state: the mode, the Message column, the selection, and whether any visible message
    /// is clipped (wrapped, taller than its row) or truncated (unwrapped, wider than its column).
    func debugSummary() -> String {
        guard let session else { return "no session" }
        let visible = tableView.rows(in: tableView.visibleRect)
        let range = visible.location..<(visible.location + visible.length)
        let clip = scrollView.contentView
        let insets = clip.contentInsets
        let top = clip.bounds.minY + insets.top
        let bottom = clip.bounds.maxY - insets.bottom
        var selectedText = "-"
        var selectedVisible = "-"
        if let selected = tableView.selectedRowIndexes.first {
            selectedText = String(selected)
            let rect = tableView.rect(ofRow: selected)
            let inView = rect.minY >= top - 0.5 && (rect.maxY <= bottom + 0.5 || rect.height > bottom - top)
            selectedVisible = inView ? "yes" : "no"
        }
        let columnIndex = tableView.column(withIdentifier: Column.message.identifier)
        var clipped = 0
        var truncated = 0
        if columnIndex >= 0 {
            for row in range where row < session.rows.count {
                guard let label = messageLabel(row: row), let cell = label.cell else { continue }
                if wrapLines {
                    let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: 1e7)).height
                    if needed > label.bounds.height + 0.5 { clipped += 1 }
                } else if session.rows[row].span.cells <= Self.maxMessageCells {
                    let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: 1e7, height: label.bounds.height)).width
                    if needed > label.bounds.width + 0.5 { truncated += 1 }
                }
            }
        }
        let messageWidth = tableView.tableColumn(withIdentifier: Column.message.identifier)?.width ?? 0
        let reload = lastReload.map { "\($0.rows)/\(String(format: "%.1f", $0.milliseconds))ms" } ?? "-"
        let height = lastHeightPass.map { "\(String(format: "%.1f", Self.milliseconds($0)))ms" } ?? "-"
        let anchor = lastAnchor.map { "\($0.row):\(String(format: "%.1f", $0.before))->\(String(format: "%.1f", $0.after))" } ?? "-"
        return "calls=\(heightCalls) docH=\(Int(tableView.frame.height)) wrap=\(wrapLines ? "on" : "off") cols=\(wrapColumns) charWidth=\(String(format: "%.2f", charWidth)) "
            + "msgWidth=\(String(format: "%.0f", messageWidth)) widestCells=\(session.widestLineCells) "
            + "selected=\(selectedText) visible=\(range.lowerBound)-\(range.upperBound) selectedVisible=\(selectedVisible) "
            + "clipped=\(clipped) truncated=\(truncated) reload=\(reload) height=\(height) anchor=\(anchor) "
            + "hscroll=\(Int(messageScroll.offset))/\(Int(messageScroll.maxOffset)) viewW=\(Int(clip.bounds.width)) fits=\(tableFits ? "yes" : "no") "
            + "clipX=\(Int(clip.bounds.origin.x)) scroller=\(scrollerSummary())"
    }

    /// The Message scroller: hidden, or the style, where it is (x + width), how wide its document is, where
    /// its clip view is scrolled, and how much of the track the knob takes. In legacy style it also checks
    /// that the strip does not cover any of the rows (`band=ok`).
    fileprivate func scrollerSummary() -> String {
        let strip = scrollView.messageScroller
        guard !strip.isHidden else { return "hidden" }
        let legacy = scrollView.scrollerStyle == .legacy
        let document = Int(strip.documentView?.frame.width ?? 0)
        var text = "\(legacy ? "legacy" : "overlay"):\(Int(strip.frame.minX))+\(Int(strip.frame.width))/doc\(document)/at\(Int(strip.contentView.bounds.minX))"
        if let scroller = strip.horizontalScroller {
            text += "/knob\(String(format: "%.3f", scroller.knobProportion))@\(String(format: "%.3f", scroller.doubleValue))\(scroller.isHidden ? "(hidden)" : "")"
        }
        let column = tableView.column(withIdentifier: Column.message.identifier)
        if column >= 0 { text += "/col\(Int(tableView.rect(ofColumn: column).minX))" }
        if legacy {
            text += strip.frame.intersects(scrollView.contentView.frame.insetBy(dx: 0, dy: 0.5)) ? "/band=OVERLAP" : "/band=ok"
        }
        return text
    }

    /// `ok`, or the first way the other columns moved with the message: the table scrolled sideways while it
    /// fits, a visible column outside the visible rect, or a Message label that is not where the offset says.
    fileprivate func pinCheck() -> String {
        let clip = scrollView.contentView
        let fits = tableFits
        if fits, abs(clip.bounds.origin.x) > 0.01 { return "MOVED(clipX=\(clip.bounds.origin.x))" }
        if fits {
            let visible = tableView.visibleRect
            for column in tableView.tableColumns where !column.isHidden && column.identifier != Column.message.identifier {
                let rect = tableView.rect(ofColumn: tableView.column(withIdentifier: column.identifier))
                if rect.minX < visible.minX - 0.5 || rect.maxX > visible.maxX + 0.5 { return "OFFSCREEN(\(column.identifier.rawValue))" }
            }
        }
        let want = wrapLines ? 0 : -messageScroll.offset
        var failure: String?
        let index = tableView.column(withIdentifier: Column.message.identifier)
        if index >= 0 {
            tableView.enumerateAvailableRowViews { rowView, row in
                guard failure == nil, let cell = rowView.view(atColumn: index) as? MessageCellView else { return }
                if abs(Double(cell.label.frame.minX) - want) > 0.01 {
                    failure = "LABEL(\(row) x=\(cell.label.frame.minX) want=\(want))"
                }
            }
        }
        return failure ?? "ok"
    }

    /// The label of a Message cell that is on screen now.
    fileprivate func messageLabel(row: Int) -> NSTextField? {
        let index = tableView.column(withIdentifier: Column.message.identifier)
        guard index >= 0 else { return nil }
        return (tableView.view(atColumn: index, row: row, makeIfNecessary: false) as? MessageCellView)?.label
    }

    func debugSelect(row: Int, at fraction: Double, following: Bool) {
        guard row >= 0, row < tableView.numberOfRows else { return }
        session?.autoScroll = following
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let clip = scrollView.contentView
        let insets = clip.contentInsets
        let viewport = clip.bounds.height - insets.top - insets.bottom
        let rect = tableView.rect(ofRow: row)
        // 0 puts the row's top at the top of the viewport and 1 puts its bottom at the bottom of it.
        let top = min(max(0, rect.minY - CGFloat(fraction) * max(0, viewport - rect.height)), max(0, tableView.frame.height - viewport))
        isProgrammaticScroll = true
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: top - insets.top))
        scrollView.reflectScrolledClipView(clip)
        isProgrammaticScroll = false
    }

    func debugPressArrowKeys() -> String {
        // A window nobody can see may not have laid out the table since its column was resized.
        scrollView.tile()
        tableView.tile()
        // In a window too narrow to pin the other columns the whole table scrolls instead of the message.
        let wholeTable = !wrapLines && !messageScroll.isScrollable && !tableFits
        let clip = scrollView.contentView
        func position() -> Double { wholeTable ? clip.bounds.origin.x : messageScroll.offset }
        let range = "range=0..\(Int(wholeTable ? tableView.frame.width - clip.bounds.width : messageScroll.maxOffset))"
        var steps: [String] = []
        var pinned = "ok"
        let presses: [(String, Int, NSEvent.ModifierFlags)] = [
            ("→", NSRightArrowFunctionKey, []), ("→", NSRightArrowFunctionKey, []),
            ("⌘→", NSRightArrowFunctionKey, .command), ("←", NSLeftArrowFunctionKey, []),
            ("⌘←", NSLeftArrowFunctionKey, .command), ("⇧→", NSRightArrowFunctionKey, .shift),
        ]
        for (name, key, flags) in presses {
            let characters = String(Character(UnicodeScalar(UInt32(key))!))
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags.union(.numericPad).union(.function), timestamp: 0,
                windowNumber: tableView.window?.windowNumber ?? 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: key == NSLeftArrowFunctionKey ? 123 : 124
            )
            guard let event else { continue }
            let before = position()
            let handled = handleKey(event)
            steps.append("\(name):\(handled ? "scrolled" : "ignored")@\(Int(before))->\(Int(position()))")
            let check = pinCheck()
            if pinned == "ok" { pinned = check }
        }
        let result = "arrow-keys wrap=\(wrapLines ? "on" : "off")\(wholeTable ? " table" : "") \(range) " + steps.joined(separator: " ") + " pinned=\(pinned)"
        if wholeTable {
            clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y))
            scrollView.reflectScrolledClipView(clip)
        }
        return result
    }

    func debugPinned() -> String {
        "pinned=\(pinCheck())"
    }

    func debugMessageScroll() -> String {
        scrollView.tile()
        tableView.tile()
        axisLock = ScrollAxisLock()
        setMessageOffset(0, flash: false)
        var pinned = "ok"
        func check() {
            let result = pinCheck()
            if pinned == "ok" { pinned = result }
        }
        func send(_ dx: Double, _ dy: Double, _ phase: ScrollAxisLock.Phase, _ momentum: ScrollAxisLock.Phase = .none, precise: Bool = true) -> Bool {
            handleScroll(dx: dx, dy: dy, precise: precise, phase: phase, momentum: momentum, inside: true)
        }
        // A sideways swipe with a little vertical wobble, then its momentum.
        let horizontal = [
            send(-30, 2, .began), send(-30, -5, .changed), send(0, 0, .ended),
            send(-10, 0, .none, .began), send(-10, 0, .none, .changed), send(0, 0, .none, .ended),
        ]
        let afterHorizontal = Int(messageScroll.offset)
        check()
        // A mostly vertical swipe that wanders sideways stays the table's.
        let vertical = [send(2, -30, .began), send(-20, -10, .changed), send(0, 0, .ended)]
        let afterVertical = Int(messageScroll.offset)
        // A mouse wheel turned sideways (shift) reports lines, not points.
        let wheel = send(-2, 0, .none, .none, precise: false)
        let afterWheel = Int(messageScroll.offset)
        check()
        // A drag of the Message scroller's knob, which moves its clip view.
        var scroller = "n/a"
        let strip = scrollView.messageScroller
        if !wrapLines, messageScroll.isScrollable {
            isSyncingScroller = false
            strip.contentView.scroll(to: NSPoint(x: min(100, messageScroll.maxOffset), y: 0))
            strip.reflectScrolledClipView(strip.contentView)
            scroller = "\(Int(min(100, messageScroll.maxOffset)))->\(Int(messageScroll.offset))"
            check()
        }
        setMessageOffset(0, flash: false)
        axisLock = ScrollAxisLock()
        check()
        let pixels = pixelCheck()
        return "message-scroll wrap=\(wrapLines ? "on" : "off") max=\(Int(messageScroll.maxOffset)) "
            + "h=consumed\(horizontal.filter { $0 }.count)/\(horizontal.count)@0->\(afterHorizontal) "
            + "v=passed\(vertical.filter { !$0 }.count)/\(vertical.count)@\(afterHorizontal)->\(afterVertical) "
            + "wheel=\(wheel ? "consumed" : "passed")@\(afterVertical)->\(afterWheel) scroller=\(scroller) pinned=\(pinned) pixels=\(pixels)"
    }

    /// Draws the log into a bitmap at offset 0 and again with the text moved, and compares what the other
    /// columns and the Message column show: the columns left of the message must not change by a pixel,
    /// whatever the text does (`pinned-same`), and the message must change (`moved`). `n/a` when the text does
    /// not scroll. This draws the views directly, so it shows where the text is drawn but not what the window
    /// server composites; clipping to the column (`clipsToBounds` on the cell) is a manual check.
    private func pixelCheck() -> String {
        let column = tableView.column(withIdentifier: Column.message.identifier)
        guard !wrapLines, messageScroll.isScrollable, column >= 0 else { return "n/a" }
        func render() -> NSBitmapImageRep? {
            scrollView.layoutSubtreeIfNeeded()
            guard let rep = scrollView.bitmapImageRepForCachingDisplay(in: scrollView.bounds) else { return nil }
            scrollView.cacheDisplay(in: scrollView.bounds, to: rep)
            return rep
        }
        setMessageOffset(0, flash: false)
        guard let before = render() else { return "no-bitmap" }
        setMessageOffset(min(1000, messageScroll.maxOffset), flash: false)
        guard let after = render() else { return "no-bitmap" }
        setMessageOffset(0, flash: false)
        guard let a = before.bitmapData, let b = after.bitmapData, before.bytesPerRow == after.bytesPerRow,
              before.pixelsHigh == after.pixelsHigh, before.bitsPerPixel == 32, after.bitsPerPixel == 32
        else { return "no-bitmap" }
        let scale = Double(before.pixelsWide) / Double(scrollView.bounds.width)
        let content = scrollView.contentView.frame
        let messageLeft = Int((content.minX + tableView.rect(ofColumn: column).minX - scrollView.contentView.bounds.minX) * scale)
        let messageRight = min(before.pixelsWide, Int(content.maxX * scale))
        let pinnedLeft = Int(content.minX * scale)
        // Everything but the bottom rows, where the scroller may be drawn, and the top, where the header is.
        let rows = before.pixelsHigh
        var pinnedDiffs = 0
        var messageDiffs = 0
        for y in 0..<rows {
            let row = y * before.bytesPerRow
            for x in pinnedLeft..<max(pinnedLeft, messageLeft) where memcmp(a + row + x * 4, b + row + x * 4, 4) != 0 {
                pinnedDiffs += 1
            }
            for x in messageLeft..<max(messageLeft, messageRight) where memcmp(a + row + x * 4, b + row + x * 4, 4) != 0 {
                messageDiffs += 1
            }
        }
        return "\(pinnedDiffs == 0 ? "pinned-same" : "PINNED-CHANGED(\(pinnedDiffs))"),\(messageDiffs > 0 ? "moved" : "UNMOVED")"
    }

    /// Scrolls through the whole log one jump per page, so every step draws a fresh page of rows (the worst
    /// case; ordinary scrolling reuses most of what is on screen), and times each step to the end of drawing.
    func debugScrollBenchmark(pages: Int) -> String {
        let clip = scrollView.contentView
        let origin = clip.bounds.origin
        // Wrapped heights are only known for rows that have been on screen, so positions shift as the
        // benchmark scrolls through them; the way back is a row and an offset, not a point.
        let anchor = captureAnchor()
        let follow = session?.autoScroll ?? true
        let count = tableView.numberOfRows
        let travel = max(0, tableView.frame.height - clip.bounds.height)
        let clock = ContinuousClock()
        var times: [Double] = []
        isProgrammaticScroll = true
        for page in 0..<max(1, pages) {
            let started = clock.now
            clip.scroll(to: NSPoint(x: origin.x, y: travel * Double(page) / Double(max(1, pages - 1))))
            scrollView.reflectScrolledClipView(clip)
            tableView.layoutSubtreeIfNeeded()
            scrollView.displayIfNeeded()
            times.append(Self.milliseconds(clock.now - started))
        }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
        isProgrammaticScroll = false
        if let anchor { restore(anchor, settleFollow: false) }
        session?.autoScroll = follow
        times.sort()
        let average = times.reduce(0, +) / Double(max(1, times.count))
        let p95 = times[min(times.count - 1, Int(Double(times.count) * 0.95))]
        var text = "scroll-bench wrap=\(wrapLines ? "on" : "off") rows=\(count) pages=\(times.count) "
            + "avg=\(String(format: "%.2f", average))ms p95=\(String(format: "%.2f", p95))ms max=\(String(format: "%.2f", times.last ?? 0))ms"
        text += sidewaysBenchmark(steps: 50)
        return text
    }

    /// Times moving the message text across its whole range in `steps` jumps, each to the end of drawing, and
    /// leaves the offset where it was. Empty when the text does not scroll.
    private func sidewaysBenchmark(steps: Int) -> String {
        guard !wrapLines, messageScroll.isScrollable else { return "" }
        let saved = messageScroll.offset
        let travel = messageScroll.maxOffset
        let clock = ContinuousClock()
        var times: [Double] = []
        for step in 1...steps {
            let started = clock.now
            setMessageOffset(travel * Double(step) / Double(steps), flash: false)
            scrollView.displayIfNeeded()
            times.append(Self.milliseconds(clock.now - started))
        }
        setMessageOffset(saved, flash: false)
        times.sort()
        let average = times.reduce(0, +) / Double(times.count)
        let p95 = times[min(times.count - 1, Int(Double(times.count) * 0.95))]
        return " sideways steps=\(steps) avg=\(String(format: "%.2f", average))ms p95=\(String(format: "%.2f", p95))ms max=\(String(format: "%.2f", times.last ?? 0))ms"
    }

    /// One line: the options, the column order (hidden columns included, which shows where an autosaved
    /// layout put the Process column), the tag of row 0 and the last few visible rows as they are on screen
    /// (`time|pid|tag|package|process|level|message`, `~` for a hidden column), and a check that every
    /// visible cell equals what the formatter gives now. A cell that was not reloaded after an option change,
    /// a filter or a trim would show as MISMATCH.
    func debugViewSummary() -> String {
        guard let session, let options = viewOptions else { return "no session" }
        let order = tableView.tableColumns.map { ($0.isHidden ? "-" : "") + $0.identifier.rawValue }.joined(separator: ",")
        var row0 = "-"
        if let first = session.rows.first, let entry = session.entry(for: first) {
            row0 = "\"\(cellText(.tag, for: entry, row: 0, in: session))\""
        }
        let visible = tableView.rows(in: tableView.visibleRect)
        let range = visible.location..<(visible.location + visible.length)
        func label(_ column: Column, _ row: Int) -> NSTextField? {
            let index = tableView.column(withIdentifier: column.identifier)
            guard index >= 0, !tableView.tableColumns[index].isHidden else { return nil }
            return tableView.view(atColumn: index, row: row, makeIfNecessary: false) as? NSTextField
        }
        var shown: [String] = []
        var mismatch: String?
        for row in range where row < session.rows.count {
            let logRow = session.rows[row]
            guard let entry = session.entry(for: logRow) else { continue }
            var fields: [String] = []
            for column in [Column.time, .pid, .tag, .package, .process] {
                guard options.isVisible(column) else {
                    fields.append("~")
                    continue
                }
                let actual = label(column, row)?.stringValue
                let expected = logRow.line == 0 ? cellText(column, for: entry, row: row, in: session) : ""
                // Markers show a time and the message only.
                let wanted = entry.kind == .marker && column != .time ? "" : expected
                if let actual, actual != wanted, mismatch == nil { mismatch = "\(row):\(column.rawValue) \"\(actual)\"!=\"\(wanted)\"" }
                fields.append(actual ?? "?")
            }
            let level = options.isVisible(.level) ? ((tableView.view(atColumn: tableView.column(withIdentifier: Column.level.identifier), row: row, makeIfNecessary: false) as? BadgeCellView)?.badge.stringValue ?? "?") : "~"
            let message = messageLabel(row: row)?.stringValue ?? "?"
            if logRow.line == 0 {
                shown.append((fields + [level, String(message.prefix(14))]).joined(separator: "|"))
            }
        }
        let cells = shown.suffix(8).joined(separator: " ; ")
        return "view: \(options.summary) trims=\(session.trimCount) order=\(order) row0=\(row0) cells=[\(cells)] check=\(mismatch.map { "MISMATCH(\($0))" } ?? "ok")"
    }

    func debugCopyText(entries: Int) -> String {
        guard let session else { return "" }
        var lines: [String] = []
        var seen = Set<Int>()
        for index in session.rows.indices.reversed() {
            let row = session.rows[index]
            guard seen.insert(row.entryID).inserted else { continue }
            guard seen.count <= entries else { break }
            let first = index - Int(row.line)
            if let text = copyText(forRows: IndexSet(integer: first)) {
                lines.append(text.replacingOccurrences(of: "\n", with: "\\n"))
            }
        }
        return lines.reversed().joined(separator: " ⏎ ")
    }
}
