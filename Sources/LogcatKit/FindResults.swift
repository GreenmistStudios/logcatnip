import Foundation

public enum FindDirection: Sendable {
    case next
    case previous
}

/// Where a jump to the next or previous match starts from.
public enum FindAnchor: Sendable, Equatable {
    /// An empty table.
    case none
    /// The selected rows: next goes past the last one, previous before the first. This is Android
    /// Studio's behaviour, which starts from the caret.
    case selection(ClosedRange<Int>)
    /// The visible rows, when nothing is selected: next goes to the first match at or below the top row,
    /// previous to the last match at or above the bottom row.
    case viewport(ClosedRange<Int>)
}

/// Matching row indexes of a find query over a log table whose rows are appended at the end, trimmed from
/// the front, or replaced. Scans run off the main thread, so a `ScanRequest` records the state it
/// started from: results that arrive after a trim are shifted, and results from before a reset are
/// dropped.
public struct FindResults: Sendable, Equatable {
    public struct ScanRequest: Sendable, Equatable {
        public let generation: Int
        /// Value of `trimmedRows` when the request was made.
        public let trimmedRows: Int
        /// Rows to scan, as indexes at the time of the request.
        public let range: Range<Int>
    }

    /// Matching row indexes, ascending.
    public private(set) var rows: [Int] = []
    /// Rows `0..<searchedRowCount` have been scanned.
    public private(set) var searchedRowCount = 0
    public private(set) var generation = 0
    /// Rows removed from the front since the last reset.
    private var trimmedRows = 0

    public init() {}

    public var count: Int { rows.count }

    /// Forgets every match, for a new query or a table whose rows were replaced.
    public mutating func reset() {
        rows.removeAll(keepingCapacity: true)
        searchedRowCount = 0
        trimmedRows = 0
        generation += 1
    }

    /// The rows not scanned yet, or nil when everything is.
    public func nextScan(rowCount: Int) -> ScanRequest? {
        guard searchedRowCount < rowCount else { return nil }
        return ScanRequest(generation: generation, trimmedRows: trimmedRows, range: searchedRowCount..<rowCount)
    }

    /// Adds the matches of a finished scan. Returns the rows the scan covered, as current indexes, or nil
    /// when it is stale because the results were reset after it started. Only one scan may be in flight
    /// at a time, so its matches always sort after the existing ones.
    @discardableResult
    public mutating func complete(_ request: ScanRequest, matches: [Int]) -> Range<Int>? {
        guard request.generation == generation else { return nil }
        let shift = trimmedRows - request.trimmedRows
        if shift == 0 {
            rows.append(contentsOf: matches)
        } else {
            rows.append(contentsOf: matches.lazy.map { $0 - shift }.filter { $0 >= 0 })
        }
        searchedRowCount = max(searchedRowCount, request.range.upperBound - shift)
        return max(0, request.range.lowerBound - shift)..<max(0, request.range.upperBound - shift)
    }

    /// Rows were dropped from the top of the table (buffer trimming).
    public mutating func removeFront(_ count: Int) {
        guard count > 0 else { return }
        trimmedRows += count
        let first = lowerBound(count)
        rows.removeFirst(first)
        for index in rows.indices {
            rows[index] -= count
        }
        searchedRowCount = max(0, searchedRowCount - count)
    }

    public func contains(_ row: Int) -> Bool {
        let index = lowerBound(row)
        return index < rows.count && rows[index] == row
    }

    /// Position of `row` among the matches, from 0.
    public func ordinal(of row: Int) -> Int? {
        let index = lowerBound(row)
        return index < rows.count && rows[index] == row ? index : nil
    }

    /// The match to jump to, wrapping around at either end. Nil when there are no matches.
    public func target(_ direction: FindDirection, from anchor: FindAnchor) -> Int? {
        guard let first = rows.first, let last = rows.last else { return nil }
        switch (direction, anchor) {
        case (.next, .none):
            return first
        case (.previous, .none):
            return last
        case let (.next, .selection(range)):
            return element(atOrAfter: upperBound(range.upperBound)) ?? first
        case let (.previous, .selection(range)):
            return element(before: lowerBound(range.lowerBound)) ?? last
        case let (.next, .viewport(range)):
            return element(atOrAfter: lowerBound(range.lowerBound)) ?? first
        case let (.previous, .viewport(range)):
            return element(before: upperBound(range.upperBound)) ?? last
        }
    }

    private func element(atOrAfter index: Int) -> Int? {
        index < rows.count ? rows[index] : nil
    }

    private func element(before index: Int) -> Int? {
        index > 0 ? rows[index - 1] : nil
    }

    /// Index of the first match `>= value`.
    private func lowerBound(_ value: Int) -> Int {
        var low = 0
        var high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if rows[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Index of the first match `> value`.
    private func upperBound(_ value: Int) -> Int {
        var low = 0
        var high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if rows[mid] <= value { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
