import Foundation

/// Ascending row indexes of the entries a predicate picks, kept in step with a log table whose rows are
/// appended at the end, trimmed from the front, or replaced. Each entry is marked once, on the row of its
/// first line, so a stack trace counts as one stop. Appends and trims cost only the rows they touch, so
/// nothing is rescanned on each flush.
public struct IncrementalRowIndex: Sendable {
    /// Nil for an index whose rows come only from ``insert(_:)``, because what it picks changes over time
    /// (such as the anchor entries of signals).
    public let predicate: (@Sendable (LogEntry) -> Bool)?
    /// Ascending.
    public private(set) var rows: [Int] = []

    public init(predicate: @escaping @Sendable (LogEntry) -> Bool) {
        self.predicate = predicate
    }

    /// An index the caller fills with ``insert(_:)``.
    public init() {
        predicate = nil
    }

    /// Log entries of level error and above; markers never count.
    public static let errors = IncrementalRowIndex { $0.kind == .log && $0.level >= .error }

    public var count: Int { rows.count }
    public var isEmpty: Bool { rows.isEmpty }

    /// Records `entry` if it matches. `firstRow` is the row of its first line, and must not be below a row
    /// noted before.
    public mutating func note(_ entry: LogEntry, firstRow: Int) {
        if predicate?(entry) == true { rows.append(firstRow) }
    }

    /// Adds `row`, keeping the rows ascending and unique. Appending is the common case; a row above the
    /// last costs a binary search and an array insert, for an entry that joined the index after its row was
    /// already shown.
    public mutating func insert(_ row: Int) {
        guard let last = rows.last, row <= last else {
            rows.append(row)
            return
        }
        let index = FindResults.lowerBound(row, in: rows)
        if rows[index] != row { rows.insert(row, at: index) }
    }

    /// Rows were dropped from the top of the table (buffer trimming).
    public mutating func removeFront(_ count: Int) {
        guard count > 0 else { return }
        let first = FindResults.lowerBound(count, in: rows)
        rows.removeFirst(first)
        for index in rows.indices {
            rows[index] -= count
        }
    }

    /// Forgets every row, for a table whose rows were replaced.
    public mutating func reset() {
        rows.removeAll(keepingCapacity: true)
    }

    /// The row to jump to, wrapping around at either end. Nil when nothing matches.
    public func target(_ direction: FindDirection, from anchor: FindAnchor) -> Int? {
        FindResults.target(in: rows, direction, from: anchor)
    }
}
