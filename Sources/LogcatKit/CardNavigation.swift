import Foundation

/// Moves a selection by whole entries for the card layout, where an entry spans one row per message line.
/// AppKit's table moves its selected row one row at a time, so inside a card of several rows ↑ and ↓ would seem
/// stuck; this steps over the card instead.
public enum CardNavigation {
    public enum Direction: Sendable { case up, down }

    /// The rows of the entry that `row` belongs to: its neighbours with the same entry ID. The walk is short
    /// (one step per message line), and it does not need the row's line number, which the kit does not know.
    /// Precondition: `0 <= row < rowCount`.
    public static func entryRows(containing row: Int, rowCount: Int, entryID: (Int) -> Int) -> ClosedRange<Int> {
        let id = entryID(row)
        var first = row
        var last = row
        while first > 0, entryID(first - 1) == id { first -= 1 }
        while last + 1 < rowCount, entryID(last + 1) == id { last += 1 }
        return first...last
    }

    /// The selection after ↑ or ↓ (`extending` for ⇧), and the card to scroll into view. Nil when there are no
    /// rows. Indexes at or past `rowCount` in `selection` are ignored.
    ///
    /// The step starts from the card holding the selection's last (↓) or first (↑) row, so a selection that
    /// find made inside a long entry still moves on to the next card. ⇧ only grows the selection; it does not
    /// shrink back toward an anchor the way AppKit's row-wise ⇧-selection does. At either end a plain arrow
    /// collapses the selection to the end card and ⇧ leaves it alone.
    public static func step(
        _ direction: Direction, extending: Bool, selection: IndexSet, visibleRows: Range<Int>,
        rowCount: Int, entryID: (Int) -> Int
    ) -> (selection: IndexSet, reveal: ClosedRange<Int>)? {
        guard rowCount > 0 else { return nil }
        let selected = selection.filteredIndexSet { $0 < rowCount }
        func card(_ row: Int) -> ClosedRange<Int> {
            entryRows(containing: row, rowCount: rowCount, entryID: entryID)
        }
        guard let firstSelected = selected.first, let lastSelected = selected.last else {
            // Nothing selected: start from the card at the edge of the viewport that the arrow points away from.
            let start: Int
            switch direction {
            case .down: start = visibleRows.isEmpty ? 0 : visibleRows.lowerBound
            case .up: start = visibleRows.isEmpty ? rowCount - 1 : visibleRows.upperBound - 1
            }
            let whole = card(min(max(0, start), rowCount - 1))
            return (IndexSet(integersIn: whole), whole)
        }
        let edge: ClosedRange<Int>
        let target: Int
        switch direction {
        case .down:
            edge = card(lastSelected)
            target = edge.upperBound + 1
        case .up:
            edge = card(firstSelected)
            target = edge.lowerBound - 1
        }
        guard (0..<rowCount).contains(target) else {
            return extending ? (selected, edge) : (IndexSet(integersIn: edge), edge)
        }
        let next = card(target)
        if extending {
            var grown = selected
            grown.insert(integersIn: next)
            return (grown, next)
        }
        return (IndexSet(integersIn: next), next)
    }
}
