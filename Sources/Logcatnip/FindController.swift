import AppKit
import Foundation
import LogcatKit
import Observation

/// What the log table offers the find controller: where a jump starts from, and how to show a match.
@MainActor
protocol FindTableNavigating: AnyObject {
    var findAnchor: FindAnchor { get }
    var selectedRowIndexes: IndexSet { get }
    /// Selects `row` alone and scrolls to it. `highlight` is the first match in the row's message line,
    /// so the table can scroll sideways to it.
    func revealFindMatch(row: Int, highlight: NSRange?)
    func focusTable()
}

enum FindChange {
    /// Matches changed anywhere; the table redraws what is visible.
    case all
    /// Only matches in these rows changed.
    case rows(Range<Int>)
}

/// Find-in-results state for one session: the query, its options and the matching rows, kept current as
/// rows stream in, are trimmed, or are refiltered. Searches the rows the table shows, after the filter.
@MainActor
@Observable
final class FindController {
    var isVisible = false
    var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    var matchCase = false {
        didSet { if matchCase != oldValue { applyNow() } }
    }
    var regex = false {
        didSet { if regex != oldValue { applyNow() } }
    }
    var wholeWord = false {
        didSet { if wholeWord != oldValue { applyNow() } }
    }
    /// Incremented to ask the find field to take focus.
    private(set) var focusRequest = 0
    private(set) var error: FindError?
    private(set) var matchCount = 0
    /// 0-based position of the current match among the matches.
    private(set) var currentIndex: Int?
    /// A full search is running, which is the only time an empty result may still grow.
    private(set) var isSearching = false

    @ObservationIgnored weak var session: LogSession?
    @ObservationIgnored weak var table: (any FindTableNavigating)?
    @ObservationIgnored var onChange: ((FindChange) -> Void)?
    /// Nil when find is inactive: the bar is hidden, the query is empty, or the pattern is invalid.
    @ObservationIgnored private(set) var finder: LogFinder?
    @ObservationIgnored private(set) var results = FindResults()
    /// Row index of the current match.
    @ObservationIgnored private(set) var currentRow: Int?
    /// The current match as a stable identity, because row indexes move when rows are trimmed or refiltered.
    @ObservationIgnored private var currentMatch: LogSession.Row?
    /// The find field uses this to focus once per `focusRequest`, even if the bar is created after it.
    @ObservationIgnored var handledFocusRequest = 0

    @ObservationIgnored private var scanWorker: Task<[Int], Never>?
    @ObservationIgnored private var scanGeneration: Int?
    @ObservationIgnored private var pendingNavigation: FindDirection?
    @ObservationIgnored private var queryPending = false
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var debugCheck: (key: [Int], verdict: String)?

    var isActive: Bool { finder != nil }

    /// Whether the current results are still being computed for the current query.
    private var isScanning: Bool { scanGeneration == results.generation }

    // MARK: Bar

    /// Shows the bar and asks the field to take focus. An open bar is only refocused.
    func show() {
        isVisible = true
        focusRequest += 1
        if !isActive, !query.isEmpty { applyNow() }
    }

    /// Hides the bar and clears highlights, ticks and the current match. The query and options stay for
    /// the next time.
    func hide() {
        guard isVisible else { return }
        isVisible = false
        deactivate()
        error = nil
        table?.focusTable()
    }

    private func deactivate() {
        debounce?.cancel()
        debounce = nil
        queryPending = false
        scanWorker?.cancel()
        scanGeneration = nil
        pendingNavigation = nil
        finder = nil
        results.reset()
        currentMatch = nil
        publish()
        onChange?(.all)
    }

    // MARK: Query

    private func queryChanged() {
        queryPending = true
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.applyNow()
        }
    }

    /// Compiles the query and searches again from the first row. An invalid pattern clears the matches
    /// and reports the error.
    func applyNow() {
        debounce?.cancel()
        debounce = nil
        queryPending = false
        scanWorker?.cancel()
        scanGeneration = nil
        pendingNavigation = nil
        currentMatch = nil
        results.reset()
        do {
            let compiled = try LogFinder(query, options: FindOptions(matchCase: matchCase, regex: regex, wholeWord: wholeWord))
            error = nil
            finder = isVisible && !compiled.isEmpty ? compiled : nil
        } catch {
            self.error = error
            finder = nil
        }
        publish()
        onChange?(.all)
        scheduleScan()
    }

    // MARK: Navigation

    /// Jumps to the next or previous match, wrapping around. With the bar hidden it opens the bar
    /// without taking focus. When the search has not found anything yet, the jump happens when it does.
    func navigate(_ direction: FindDirection) {
        guard !query.isEmpty else {
            NSSound.beep()
            return
        }
        if !isVisible {
            isVisible = true
            applyNow()
        } else if queryPending || (finder == nil && error == nil) {
            applyNow()
        }
        guard finder != nil else {
            NSSound.beep()
            return
        }
        jump(direction)
    }

    private func jump(_ direction: FindDirection) {
        if let row = results.target(direction, from: table?.findAnchor ?? .none) {
            pendingNavigation = nil
            select(row)
        } else if isScanning {
            pendingNavigation = direction
        } else {
            NSSound.beep()
        }
    }

    private func select(_ row: Int) {
        guard let session, row < session.rows.count else { return }
        currentMatch = session.rows[row]
        publish()
        onChange?(.all)
        table?.revealFindMatch(row: row, highlight: firstHighlight(inRow: row))
    }

    /// The first match in a row's message line, for horizontal scrolling.
    private func firstHighlight(inRow row: Int) -> NSRange? {
        guard let session, let finder, row < session.rows.count else { return nil }
        let logRow = session.rows[row]
        guard let entry = session.entry(for: logRow), entry.kind == .log else { return nil }
        return finder.ranges(in: logRow.text(in: entry.message)).first
    }

    /// Fills the query from the selected text, else from the first selected row, and applies it at once.
    /// It neither moves focus nor jumps.
    func useSelectionForFind() {
        guard let text = selectionText() else {
            NSSound.beep()
            return
        }
        isVisible = true
        query = regex ? NSRegularExpression.escapedPattern(for: text) : text
        applyNow()
    }

    private func selectionText() -> String? {
        // A field editor's delegate is the text field it edits; the find field's own selection is skipped.
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, !isFindFieldEditor(editor),
           editor.selectedRange().length > 0
        {
            let selected = (editor.string as NSString).substring(with: editor.selectedRange())
            if let line = Self.firstLine(of: selected) { return line }
        }
        guard let session, let index = table?.selectedRowIndexes.first, index < session.rows.count,
              let entry = session.entry(for: session.rows[index])
        else { return nil }
        let message = session.rows[index].text(in: entry.message)
        return Self.firstLine(of: message) ?? Self.firstLine(of: entry.tag)
    }

    private func isFindFieldEditor(_ editor: NSTextView) -> Bool {
        let owner: AnyObject? = editor.delegate
        return owner is FindNSTextField
    }

    private static func firstLine(of text: String) -> String? {
        let line = text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Session hooks

    /// Rows were appended to the table; searches them without blocking the main thread.
    func rowsAppended() {
        scheduleScan()
    }

    /// Rows were dropped from the top of the table. The table reloads right after this.
    func rowsRemovedFront(_ count: Int) {
        guard isActive else { return }
        results.removeFront(count)
        publish()
    }

    /// The rows were replaced (refilter, clear). The table reloads right after this.
    func rowsReplaced() {
        guard isActive else { return }
        scanWorker?.cancel()
        scanGeneration = nil
        results.reset()
        publish()
        scheduleScan()
    }

    // MARK: Scanning

    private func scheduleScan() {
        guard let session, let finder, !isScanning, let request = results.nextScan(rowCount: session.rows.count) else {
            return
        }
        scanGeneration = request.generation
        let isFullScan = request.range.lowerBound == 0
        if isFullScan { isSearching = true }

        let baseID = session.firstEntryID
        let range = request.range
        let rowsSnapshot: [LogSession.Row]
        let entriesSnapshot: [LogEntry]
        let entryOffset: Int
        if isFullScan {
            // Shares the buffers (copy on write), like a refilter. Only a full scan does, because holding the
            // whole entries array while rows keep arriving would copy it on every ingest.
            rowsSnapshot = session.rows
            entriesSnapshot = session.entries
            entryOffset = baseID
        } else {
            rowsSnapshot = Array(session.rows[range])
            let first = rowsSnapshot[0].entryID - baseID
            let last = rowsSnapshot[rowsSnapshot.count - 1].entryID - baseID
            entriesSnapshot = Array(session.entries[first...last])
            entryOffset = rowsSnapshot[0].entryID
        }
        let rowOffset = isFullScan ? 0 : range.lowerBound

        let clock = ContinuousClock()
        let started = clock.now
        let worker = Task.detached(priority: .userInitiated) { () -> [Int] in
            finder.matchingRows(
                in: range,
                row: { index in
                    let row = rowsSnapshot[index - rowOffset]
                    return (row.entryID, row.line)
                },
                entry: { id in
                    let index = id - entryOffset
                    return index >= 0 && index < entriesSnapshot.count ? entriesSnapshot[index] : nil
                },
                isCancelled: { Task.isCancelled }
            )
        }
        scanWorker = worker
        Task { [weak self] in
            let matches = await worker.value
            self?.scanFinished(request, matches: matches, isFullScan: isFullScan, duration: clock.now - started)
        }
    }

    private func scanFinished(_ request: FindResults.ScanRequest, matches: [Int], isFullScan: Bool, duration: Duration) {
        guard scanGeneration == request.generation else { return }
        scanGeneration = nil
        scanWorker = nil
        if isFullScan { isSearching = false }
        guard let covered = results.complete(request, matches: matches) else { return }
        if isFullScan, ProcessInfo.processInfo.environment["LOGCATNIP_DEBUG"] == "1" {
            let milliseconds = Int(duration / .milliseconds(1))
            let line = "[logcatnip] find: scanned \(request.range.count) rows in \(milliseconds) ms, \(matches.count) matches\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        publish()
        onChange?(.rows(covered))
        if let direction = pendingNavigation {
            pendingNavigation = nil
            jump(direction)
        }
        scheduleScan()
    }

    // MARK: Published state

    /// Brings the observed values in line with the results. Assigns only what changed, so SwiftUI does
    /// not redraw the bar for nothing.
    private func publish() {
        if let match = currentMatch, let session {
            currentRow = session.rowIndex(of: match)
            if currentRow == nil { currentMatch = nil }
        } else {
            currentRow = nil
        }
        let count = results.count
        if matchCount != count { matchCount = count }
        let index = currentRow.flatMap { results.ordinal(of: $0) }
        if currentIndex != index { currentIndex = index }
        let searching = isSearching && isScanning
        if isSearching != searching { isSearching = searching }
    }

    // MARK: Table access

    /// Whether `row` matches, and if so whether it is the current match. Called for every visible cell, so
    /// a non-matching row costs one binary search.
    func highlight(forRow row: Int) -> Bool? {
        guard finder != nil, results.contains(row) else { return nil }
        return row == currentRow
    }

    func ranges(in text: String) -> [NSRange] {
        finder?.ranges(in: text) ?? []
    }

    // MARK: Debugging

    /// One line for `LOGCATNIP_DEBUG`. Recounts from scratch on the main thread and compares, so it
    /// shows whether incremental scans, trims and refilters kept the matches exact. The recount runs
    /// once per state, because it takes seconds on a table of 500,000 rows.
    func debugSummary() -> String {
        var check = "pending"
        var searched = 0
        var total = 0
        if let session, let finder {
            total = session.rows.count
            searched = results.searchedRowCount
            if !isScanning, searched == total {
                let key = [results.generation, total, results.count, session.firstEntryID]
                if debugCheck?.key != key {
                    let rows = session.rows
                    let expected = finder.matchingRows(
                        in: 0..<rows.count,
                        row: { (rows[$0].entryID, rows[$0].line) },
                        entry: { session.entry(id: $0) }
                    )
                    let verdict = expected == results.rows ? "ok" : "MISMATCH(\(expected.count) vs \(results.rows.count))"
                    debugCheck = (key, verdict)
                }
                check = debugCheck?.verdict ?? check
            }
        }
        let options = "\(matchCase ? "c" : "-")/\(regex ? "r" : "-")/\(wholeWord ? "w" : "-")"
        return "find=\"\(query)\" opts=\(options) matches=\(matchCount) current=\(currentIndex.map(String.init) ?? "-") "
            + "searching=\(isSearching) searched=\(searched)/\(total) error=\(error?.message ?? "-") check=\(check)"
    }
}
