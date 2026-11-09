import AppKit
import LogcatKit
import SwiftUI

/// The log table. AppKit's NSTableView keeps scrolling smooth with hundreds of thousands of rows, which
/// SwiftUI's Table does not.
struct LogTableView: NSViewRepresentable {
    let session: LogSession
    var fontSize: Double
    var showDate: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(session: session, fontSize: fontSize, showDate: showDate)
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
        private var showDate = false
        private var isProgrammaticScroll = false

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
                case .message: tableColumn.width = 800
                }
                tableColumn.minWidth = min(tableColumn.minWidth, 20)
                tableView.addTableColumn(tableColumn)
            }
            tableView.style = .plain
            tableView.usesAutomaticRowHeights = false
            tableView.allowsMultipleSelection = true
            tableView.allowsColumnReordering = true
            tableView.allowsColumnResizing = true
            tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
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
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            return scrollView
        }

        func update(session: LogSession, fontSize: Double, showDate: Bool) {
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
                needsReload = true
            }
            if self.showDate != showDate {
                self.showDate = showDate
                tableView.tableColumn(withIdentifier: Column.time.identifier)?.width = showDate ? 175 : 96
                needsReload = true
            }
            if needsReload {
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

        private func scroll(toRow row: Int) {
            isProgrammaticScroll = true
            tableView.scrollRowToVisible(row)
            isProgrammaticScroll = false
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
                    label.stringValue = "——— \(entry.message) ———"
                    label.font = italicFont ?? label.font
                    label.textColor = .secondaryLabelColor
                } else {
                    label.stringValue = column == .time ? LogcatTime.format(entry.timestamp, includeDate: showDate) : ""
                    label.textColor = .tertiaryLabelColor
                }
                return label
            }

            let isFirstLine = logRow.line == 0
            if column == .level {
                let badge = makeBadge()
                if isFirstLine {
                    badge.isHidden = false
                    badge.stringValue = entry.level.letter
                    badge.backgroundColor = LogColors.badgeBackground(for: entry.level)
                    badge.textColor = LogColors.badgeText(for: entry.level)
                } else {
                    badge.isHidden = true
                }
                return badge
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
                let text = Self.line(Int(logRow.line), of: entry.message)
                label.stringValue = text
                label.textColor = LogColors.text(for: entry.level)
                if text.count > 120 { label.toolTip = text }
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

        private func makeBadge() -> NSTextField {
            let identifier = Column.level.identifier
            let badge: NSTextField
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField {
                badge = reused
            } else {
                badge = NSTextField(labelWithString: "")
                badge.identifier = identifier
                badge.alignment = .center
                badge.drawsBackground = true
                badge.isBezeled = false
                badge.wantsLayer = true
                badge.layer?.cornerRadius = 3
            }
            badge.font = NSFont.monospacedSystemFont(ofSize: (font?.pointSize ?? 12) - 1, weight: .bold)
            return badge
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
