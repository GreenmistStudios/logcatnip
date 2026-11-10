import Testing
@testable import LogcatKit

@Suite struct LogCardLayoutTests {
    let layout = LogCardLayout(
        lineHeight: 18, wrappedLineHeight: 15, headerHeight: 22, footerHeight: 16,
        padding: 6, gap: 6, inset: 6, horizontalPadding: 10
    )

    @Test func singleLineCard() {
        // padding + header + message + footer + padding + gap
        #expect(layout.rowHeight(line: 0, isLastLine: true, wrappedLines: 1) == 6 + 22 + 18 + 16 + 6 + 6)
    }

    @Test func firstLineOfLongerEntry() {
        #expect(layout.rowHeight(line: 0, isLastLine: false, wrappedLines: 1) == 46)
    }

    @Test func middleLineWrapped() {
        #expect(layout.rowHeight(line: 1, isLastLine: false, wrappedLines: 3) == 48)
    }

    @Test func lastLine() {
        #expect(layout.rowHeight(line: 2, isLastLine: true, wrappedLines: 1) == 46)
    }

    @Test func entryTotal() {
        let rows = [
            layout.rowHeight(line: 0, isLastLine: false, wrappedLines: 1),
            layout.rowHeight(line: 1, isLastLine: false, wrappedLines: 3),
            layout.rowHeight(line: 2, isLastLine: true, wrappedLines: 1),
        ]
        // Two paddings, header, footer, gap and five lines of text (3 x 18 + 2 x 15).
        let total: Double = rows.reduce(0, +)
        let expected: Double = (6.0 * 2.0 + 22.0 + 16.0 + 6.0) + (18.0 * 3.0 + 15.0 * 2.0)
        #expect(total == expected)
        #expect(total == 140)
    }

    @Test func noHeaderNoFooter() {
        var bare = layout
        bare.headerHeight = 0
        bare.footerHeight = 0
        #expect(bare.rowHeight(line: 0, isLastLine: true, wrappedLines: 1) == 6 + 18 + 6 + 6)
    }

    @Test func messageTop() {
        #expect(layout.messageTop(line: 0) == 28)
        #expect(layout.messageTop(line: 1) == 0)
    }

    @Test func markerHeight() {
        #expect(layout.markerHeight(wrappedLines: 2) == 18 + 15 + 6)
        #expect(layout.markerHeight(wrappedLines: 0) == 24)
    }

    @Test func wrapColumns() {
        // (800 - 2 * 6 - 2 * 10 - 8) / 7.2 = 105.55
        #expect(layout.wrapColumns(columnWidth: 800, charWidth: 7.2) == 105)
        #expect(layout.wrapColumns(columnWidth: 10, charWidth: 7.2) == 1)
    }
}
