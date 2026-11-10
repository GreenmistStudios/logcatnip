import Foundation

/// What to hold still when the table's row heights change (soft wrap toggled, wrap width changed), so the
/// selected entry, or the reading position, stays where it was.
public enum ViewportAnchor: Equatable, Sendable {
    /// Keep this row's top `offset` points below the viewport top. `keepInView` (a selected row) also clamps
    /// the offset so the row's top, and its bottom when it fits, stay visible after it grew.
    case row(Int, offset: Double, keepInView: Bool)
    /// Following new logs: stay at the end.
    case end

    /// The first visible selected row; else `.end` when following; else the first visible row. Nil when no
    /// row is visible and the view is not following. The offset starts at 0: the caller measures it with
    /// `withOffset`, because only the table knows row positions.
    public static func choose(selectedRows: IndexSet, visibleRows: Range<Int>, isFollowing: Bool) -> ViewportAnchor? {
        if !visibleRows.isEmpty,
           let selected = selectedRows.integerGreaterThanOrEqualTo(visibleRows.lowerBound),
           selected < visibleRows.upperBound
        {
            return .row(selected, offset: 0, keepInView: true)
        }
        if isFollowing { return .end }
        if let first = visibleRows.first { return .row(first, offset: 0, keepInView: false) }
        return nil
    }

    public func withOffset(_ offset: Double) -> ViewportAnchor {
        guard case let .row(row, _, keepInView) = self else { return self }
        return .row(row, offset: offset, keepInView: keepInView)
    }

    /// The viewport top, in document coordinates, that puts the anchored row back where it was after the
    /// layout changed, kept within the document. A selected row is also kept on screen: with its new
    /// height its offset is limited to what leaves its bottom visible (a row taller than the viewport
    /// shows its top).
    public static func restoredTop(
        rowMinY: Double, rowHeight: Double, offset: Double, keepInView: Bool,
        viewportHeight: Double, documentHeight: Double
    ) -> Double {
        var offset = offset
        if keepInView {
            offset = max(0, min(offset, viewportHeight - rowHeight))
        }
        let maxTop = max(0, documentHeight - viewportHeight)
        return min(max(0, rowMinY - offset), maxTop)
    }
}
