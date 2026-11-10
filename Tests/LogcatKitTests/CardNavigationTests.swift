import Foundation
import Testing
@testable import LogcatKit

@Suite struct CardNavigationTests {
    /// Entry IDs per row: entry 10 is row 0, entry 11 a three-line card (rows 1-3), entry 12 row 4 and entry 13
    /// two lines (rows 5-6).
    let ids = [10, 11, 11, 11, 12, 13, 13]

    func step(
        _ direction: CardNavigation.Direction, _ selection: [Int], extending: Bool = false, visible: Range<Int> = 0..<7
    ) -> (rows: [Int], reveal: ClosedRange<Int>)? {
        let ids = ids
        guard let result = CardNavigation.step(
            direction, extending: extending, selection: IndexSet(selection), visibleRows: visible,
            rowCount: ids.count, entryID: { ids[$0] }
        ) else { return nil }
        return (Array(result.selection), result.reveal)
    }

    @Test func entryRowsSpansTheEntry() {
        let ids = ids
        func rows(_ row: Int) -> ClosedRange<Int> {
            CardNavigation.entryRows(containing: row, rowCount: ids.count, entryID: { ids[$0] })
        }
        #expect(rows(2) == 1...3)
        #expect(rows(1) == 1...3)
        #expect(rows(0) == 0...0)
        #expect(rows(4) == 4...4)
        #expect(rows(6) == 5...6)
        #expect(rows(5) == 5...6)
    }

    @Test func downLeavesAMultiRowCard() throws {
        let result = try #require(step(.down, [1, 2, 3]))
        #expect(result.rows == [4])
        #expect(result.reveal == 4...4)
    }

    @Test func downEntersAMultiRowCard() throws {
        let result = try #require(step(.down, [0]))
        #expect(result.rows == [1, 2, 3])
        #expect(result.reveal == 1...3)
    }

    @Test func upLeavesAndEntersCards() throws {
        #expect(try #require(step(.up, [5, 6])).rows == [4])
        #expect(try #require(step(.up, [4])).rows == [1, 2, 3])
        #expect(try #require(step(.up, [1, 2, 3])).rows == [0])
    }

    @Test func stepsFromThePartOfACardFindSelected() throws {
        #expect(try #require(step(.down, [2])).rows == [4])
        #expect(try #require(step(.up, [2])).rows == [0])
    }

    @Test func shiftAddsTheAdjacentCard() throws {
        let down = try #require(step(.down, [1, 2, 3], extending: true))
        #expect(down.rows == [1, 2, 3, 4])
        #expect(down.reveal == 4...4)
        let again = try #require(step(.down, [1, 2, 3, 4], extending: true))
        #expect(again.rows == [1, 2, 3, 4, 5, 6])
        #expect(again.reveal == 5...6)
        let up = try #require(step(.up, [4], extending: true))
        #expect(up.rows == [1, 2, 3, 4])
        #expect(up.reveal == 1...3)
    }

    @Test func stopsAtTheEnds() throws {
        let last = try #require(step(.down, [5, 6]))
        #expect(last.rows == [5, 6])
        #expect(last.reveal == 5...6)
        #expect(try #require(step(.up, [0])).rows == [0])
        // Collapses to the end card.
        #expect(try #require(step(.up, [0, 1, 2, 3, 4])).rows == [0])
        let all = try #require(step(.down, [1, 2, 3, 4, 5, 6], extending: true))
        #expect(all.rows == [1, 2, 3, 4, 5, 6])
        #expect(all.reveal == 5...6)
        #expect(try #require(step(.up, [0, 1, 2, 3], extending: true)).rows == [0, 1, 2, 3])
    }

    @Test func noSelectionUsesTheViewport() throws {
        for extending in [false, true] {
            #expect(try #require(step(.down, [], extending: extending, visible: 2..<5)).rows == [1, 2, 3])
            #expect(try #require(step(.up, [], extending: extending, visible: 2..<5)).rows == [4])
            #expect(try #require(step(.down, [], extending: extending, visible: 0..<0)).rows == [0])
            #expect(try #require(step(.up, [], extending: extending, visible: 0..<0)).rows == [5, 6])
        }
    }

    @Test func ignoresRowsPastTheEnd() throws {
        #expect(try #require(step(.down, [9], visible: 2..<5)).rows == [1, 2, 3])
    }

    @Test func emptyTable() {
        let result = CardNavigation.step(
            .down, extending: false, selection: IndexSet(), visibleRows: 0..<0, rowCount: 0, entryID: { _ in 0 }
        )
        #expect(result == nil)
    }

    @Test func singleRowEntriesMoveOneRow() throws {
        let ids = [1, 2, 3]
        func move(_ direction: CardNavigation.Direction, from row: Int) -> [Int]? {
            CardNavigation.step(
                direction, extending: false, selection: IndexSet(integer: row), visibleRows: 0..<3,
                rowCount: ids.count, entryID: { ids[$0] }
            ).map { Array($0.selection) }
        }
        #expect(move(.down, from: 1) == [2])
        #expect(move(.up, from: 1) == [0])
    }
}
