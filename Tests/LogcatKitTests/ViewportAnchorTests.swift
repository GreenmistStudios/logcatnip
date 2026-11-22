import Foundation
import Testing
@testable import LogcatKit

@Suite struct ViewportAnchorTests {
    @Test func visibleSelectionIsTheAnchor() {
        let anchor = ViewportAnchor.choose(selectedRows: [50], visibleRows: 40..<60, isFollowing: false)
        #expect(anchor == .row(50, offset: 0, keepInView: true))
    }

    @Test func firstVisibleSelectedRowWins() {
        let anchor = ViewportAnchor.choose(selectedRows: [10, 45, 55], visibleRows: 40..<60, isFollowing: false)
        #expect(anchor == .row(45, offset: 0, keepInView: true))
    }

    @Test func visibleSelectionBeatsFollowing() {
        let anchor = ViewportAnchor.choose(selectedRows: [98], visibleRows: 90..<100, isFollowing: true)
        #expect(anchor == .row(98, offset: 0, keepInView: true))
    }

    @Test func followingWithoutVisibleSelectionStaysAtEnd() {
        #expect(ViewportAnchor.choose(selectedRows: [], visibleRows: 90..<100, isFollowing: true) == .end)
        #expect(ViewportAnchor.choose(selectedRows: [5], visibleRows: 90..<100, isFollowing: true) == .end)
    }

    @Test func offscreenSelectionKeepsReadingPosition() {
        let anchor = ViewportAnchor.choose(selectedRows: [5], visibleRows: 40..<60, isFollowing: false)
        #expect(anchor == .row(40, offset: 0, keepInView: false))
    }

    @Test func noVisibleRowsAndNotFollowingIsNil() {
        #expect(ViewportAnchor.choose(selectedRows: [3], visibleRows: 0..<0, isFollowing: false) == nil)
    }

    @Test func withOffsetFillsTheOffset() {
        #expect(ViewportAnchor.row(3, offset: 0, keepInView: true).withOffset(12) == .row(3, offset: 12, keepInView: true))
        #expect(ViewportAnchor.end.withOffset(5) == .end)
    }

    private func top(
        minY: Double = 1000, height: Double = 18, offset: Double, keepInView: Bool = false,
        viewport: Double = 600, document: Double = 10_000
    ) -> Double {
        ViewportAnchor.restoredTop(
            rowMinY: minY, rowHeight: height, offset: offset, keepInView: keepInView,
            viewportHeight: viewport, documentHeight: document
        )
    }

    @Test func restoredTopKeepsTheOffset() {
        #expect(top(offset: 120) == 880)
    }

    @Test func selectedRowPartlyAboveIsShownFromItsTop() {
        #expect(top(offset: -5, keepInView: true) == 1000)
    }

    @Test func readingAnchorKeepsANegativeOffset() {
        #expect(top(offset: -5, keepInView: false) == 1005)
    }

    @Test func grownSelectedRowStaysOnScreen() {
        // Wrapping grew the row to 54 points; at offset 590 its bottom would fall below the viewport.
        #expect(top(height: 54, offset: 590, keepInView: true) == 1000 - 546)
    }

    @Test func rowTallerThanTheViewportShowsItsTop() {
        #expect(top(height: 900, offset: 100, keepInView: true) == 1000)
    }

    @Test func clampsToTheDocument() {
        #expect(top(minY: 50, offset: 300) == 0)
        #expect(top(minY: 990, offset: 0, document: 1000) == 400)
        #expect(top(minY: 100, offset: 0, document: 300) == 0)
    }
}
