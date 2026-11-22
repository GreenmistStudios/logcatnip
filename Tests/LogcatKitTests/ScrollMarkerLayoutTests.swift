import Testing
@testable import LogcatKit

@Suite struct ScrollMarkerLayoutTests {
    @Test func emptyInputs() {
        #expect(ScrollMarkerLayout.runs(rows: [], rowCount: 100, trackLength: 100) == [])
        #expect(ScrollMarkerLayout.runs(rows: [1], rowCount: 0, trackLength: 100) == [])
        #expect(ScrollMarkerLayout.runs(rows: [1], rowCount: 100, trackLength: 0) == [])
    }

    @Test func singleRowInLargeTable() {
        #expect(ScrollMarkerLayout.runs(rows: [50], rowCount: 100, trackLength: 100) == [50..<52])
    }

    @Test func adjacentRowsMerge() {
        #expect(ScrollMarkerLayout.runs(rows: [0, 1], rowCount: 100, trackLength: 100, minLength: 1) == [0..<2])
    }

    @Test func rowTallerThanAPixelFillsItsSpan() {
        #expect(ScrollMarkerLayout.runs(rows: [5], rowCount: 10, trackLength: 100) == [50..<60])
    }

    @Test func runAtTheEndIsShiftedBack() {
        #expect(ScrollMarkerLayout.runs(rows: [999], rowCount: 1000, trackLength: 10) == [8..<10])
    }

    @Test func nearbyRunsMergeAfterExtension() {
        // 5..<6 grows to 5..<7 and then touches 7..<8.
        #expect(ScrollMarkerLayout.runs(rows: [5, 7], rowCount: 100, trackLength: 100) == [5..<9])
    }

    @Test func everyRowMarkedIsOneRun() {
        let rows = Array(0..<500_000)
        #expect(ScrollMarkerLayout.runs(rows: rows, rowCount: 500_000, trackLength: 1000) == [0..<1000])
    }

    @Test func rowsBeyondCountAreIgnored() {
        #expect(ScrollMarkerLayout.runs(rows: [5, 200], rowCount: 100, trackLength: 100) == [5..<7])
    }
}
