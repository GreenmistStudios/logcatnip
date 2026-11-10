import AppKit
import LogcatKit
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
        private let scrollView = NSScrollView()
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
        /// Width of the widest message line rendered so far; the Message column grows to fit it so long
        /// lines scroll horizontally instead of truncating.
        private var widestMessage: CGFloat = 0
        private var messageWidthUpdatePending = false

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
                self.session?.onRowsChanged = nil
                self.session = session
                session.onRowsChanged = { [weak self] change in self?.apply(change) }
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
                tableView.reloadData()
                if session.autoScroll { scrollToEnd() }
            }
        }

        func unbind() {
            session?.onRowsChanged = nil
            NotificationCenter.default.removeObserver(self)
        }

        // MARK: Updates

        private func apply(_ change: LogSession.RowsChange) {
            guard let session else { return }
            switch change {
            case .appended:
                tableView.noteNumberOfRowsChanged()
                if session.autoScroll { scrollToEnd() }
            case let .reloaded(removedFront):
                let selectedIDs = selectedEntryIDs()
                let firstVisible = tableView.rows(in: tableView.visibleRect).location
                // Trimming the front of the buffer keeps the width so the view doesn't jump; a new filter
                // or a clear measures again.
                if removedFront == 0 { resetMessageWidth() }
                tableView.reloadData()
                restoreSelection(selectedIDs)
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

        // MARK: Message column width

        private func resetMessageWidth() {
            widestMessage = 0
            updateMessageColumnWidth()
        }

        private func noteMessageWidth(of label: NSTextField) {
            guard !wrapLines else { return }
            let width = ceil(label.attributedStringValue.size().width)
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

        /// Makes the Message column as wide as its widest line, and at least wide enough to fill the view.
        private func updateMessageColumnWidth() {
            guard let message = tableView.tableColumn(withIdentifier: Column.message.identifier) else { return }
            let spacing = tableView.intercellSpacing.width
            let others = tableView.tableColumns.reduce(CGFloat(0)) { sum, column in
                column === message || column.isHidden ? sum : sum + column.width + spacing
            }
            let fill = scrollView.contentView.bounds.width - others - spacing
            // Text fields inset their text by a few points on each side.
            let width = wrapLines ? max(fill, 100) : max(widestMessage + 8, fill, 100)
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

        /// Character cells the text takes. Scalars from Hangul Jamo up (CJK, emoji) render about twice as
        /// wide as Latin text, so they count as two; overestimating only leaves a little spare space.
        private static func columns(_ text: String) -> Int {
            var count = 0
            for scalar in text.unicodeScalars {
                count += scalar.value < 0x1100 ? 1 : 2
            }
            return count
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
                let count = tableView.numberOfRows
                guard wrapLines, count > 0 else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<count))
                }
                if session?.autoScroll == true { scrollToEnd() }
            }
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard wrapLines, let session, row < session.rows.count else { return tableView.rowHeight }
            let logRow = session.rows[row]
            guard let entry = session.entry(for: logRow) else { return tableView.rowHeight }
            // Markers add six characters of decoration around the message.
            let length = entry.kind == .marker
                ? Self.columns(entry.message) + 6
                : Self.columns(Self.line(Int(logRow.line), of: entry.message))
            let lines = max(1, (length + wrapColumns - 1) / wrapColumns)
            guard lines > 1 else { return tableView.rowHeight }
            return tableView.rowHeight + CGFloat(lines - 1) * textLineHeight
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
            guard !isProgrammaticScroll, let session, let document = scrollView.documentView else { return }
            let visible = scrollView.contentView.bounds
            let atBottom = visible.maxY >= document.frame.height - tableView.rowHeight * 1.5
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
            case .package:
                let process = session.processName(for: entry)
                label.stringValue = isFirstLine ? (process ?? (entry.pid > 0 ? "pid-\(entry.pid)" : "")) : ""
                label.textColor = process == nil ? .tertiaryLabelColor : .secondaryLabelColor
                label.toolTip = isFirstLine ? process : nil
            case .message:
                setWrapping(label)
                let text = Self.line(Int(logRow.line), of: entry.message)
                label.stringValue = text
                label.textColor = LogColors.text(for: entry.level)
                if !wrapLines, text.count > 120 { label.toolTip = text }
                noteMessageWidth(of: label)
            case .level:
                break
            }
            return label
        }

        private static func line(_ index: Int, of message: String) -> String {
            if index == 0, !message.contains("\n") { return message }
            var current = 0
            for line in message.split(separator: "\n", omittingEmptySubsequences: false) {
                if current == index { return String(line) }
                current += 1
            }
            return ""
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
            if !entry.tag.isEmpty {
                if session.ignoreList.ignoresTag(entry.tag) {
                    menu.addItem(item("Stop Ignoring Tag “\(entry.tag)”", #selector(stopIgnoringTag), entry.tag))
                } else {
                    menu.addItem(item("Ignore Tag “\(entry.tag)” Everywhere", #selector(ignoreTag), entry.tag))
                }
            }
            if let process = session.processName(for: entry) {
                let package = LogEntry.packageName(forProcess: process)
                menu.addItem(item("Show Only Package “\(package)”", #selector(addTerm), "package=:\(LogSession.quoted(package))"))
                menu.addItem(item("Hide Package “\(package)”", #selector(addTerm), "-package=:\(LogSession.quoted(package))"))
                if session.ignoreList.ignoresPackage(package) {
                    menu.addItem(item("Stop Ignoring Package “\(package)”", #selector(stopIgnoringPackage), package))
                } else {
                    menu.addItem(item("Ignore Package “\(package)” Everywhere", #selector(ignorePackage), package))
                }
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

        @objc private func ignoreTag(_ sender: NSMenuItem) {
            guard let tag = sender.representedObject as? String else { return }
            session?.ignoreTagEverywhere(tag)
        }

        @objc private func stopIgnoringTag(_ sender: NSMenuItem) {
            guard let tag = sender.representedObject as? String else { return }
            session?.stopIgnoringTag(tag)
        }

        @objc private func ignorePackage(_ sender: NSMenuItem) {
            guard let package = sender.representedObject as? String else { return }
            session?.ignorePackageEverywhere(package)
        }

        @objc private func stopIgnoringPackage(_ sender: NSMenuItem) {
            guard let package = sender.representedObject as? String else { return }
            session?.stopIgnoringPackage(package)
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

/// Routes Edit > Copy (⌘C) to the coordinator.
final class LogNSTableView: NSTableView {
    var copyHandler: (() -> Void)?

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
