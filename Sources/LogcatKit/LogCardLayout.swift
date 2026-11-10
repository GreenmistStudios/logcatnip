import Foundation

/// Where the parts of a card sit, in points. A card spans the rows of one entry (one row per message line, as
/// in the table, so find, selection and scrolling keep working by row): the first row adds the top padding and
/// the header, the last row adds the footer, the bottom padding and the gap to the next card. Keeping the
/// geometry here makes the row heights plain arithmetic the table can call for every row.
public struct LogCardLayout: Sendable, Equatable {
    /// A row's first line of text: the table's row height.
    public var lineHeight: Double
    /// Each further wrapped line of a row.
    public var wrappedLineHeight: Double
    /// Level badge, tag and time; 0 when the card has no header.
    public var headerHeight: Double
    /// PID/TID and package; 0 when the card has no footer.
    public var footerHeight: Double
    /// Inside the card, above the header and below the footer.
    public var padding: Double
    /// Between two cards.
    public var gap: Double
    /// From the column edge to the card edge, each side.
    public var inset: Double
    /// From the card edge to its text, each side.
    public var horizontalPadding: Double

    public init(
        lineHeight: Double,
        wrappedLineHeight: Double,
        headerHeight: Double,
        footerHeight: Double,
        padding: Double,
        gap: Double,
        inset: Double,
        horizontalPadding: Double
    ) {
        self.lineHeight = lineHeight
        self.wrappedLineHeight = wrappedLineHeight
        self.headerHeight = headerHeight
        self.footerHeight = footerHeight
        self.padding = padding
        self.gap = gap
        self.inset = inset
        self.horizontalPadding = horizontalPadding
    }

    /// The message text of one row that wraps to `wrappedLines` lines (at least one).
    public func messageHeight(wrappedLines: Int) -> Double {
        lineHeight + Double(max(0, wrappedLines - 1)) * wrappedLineHeight
    }

    /// The height of one row of a card: `line` is the row's index within its entry.
    public func rowHeight(line: Int, isLastLine: Bool, wrappedLines: Int) -> Double {
        var height = messageHeight(wrappedLines: wrappedLines)
        if line == 0 { height += padding + headerHeight }
        if isLastLine { height += footerHeight + padding + gap }
        return height
    }

    /// A marker is a plain line with the gap below, not a card.
    public func markerHeight(wrappedLines: Int) -> Double {
        messageHeight(wrappedLines: wrappedLines) + gap
    }

    /// Where a row's message text starts, below the header on the first row.
    public func messageTop(line: Int) -> Double {
        line == 0 ? padding + headerHeight : 0
    }

    /// Characters per wrapped line in a column `columnWidth` wide. `textInset` is the label's own inset
    /// (8, as the table's wrapped columns use). At least 1.
    public func wrapColumns(columnWidth: Double, charWidth: Double, textInset: Double = 8) -> Int {
        guard charWidth > 0 else { return 1 }
        let available = columnWidth - 2 * inset - 2 * horizontalPadding - textInset
        return max(1, Int(available / charWidth))
    }
}
