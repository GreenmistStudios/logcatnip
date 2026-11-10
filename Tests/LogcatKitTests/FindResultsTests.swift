import Foundation
import Testing
@testable import LogcatKit

private func results(_ rows: [Int], searched: Int) -> FindResults {
    var results = FindResults()
    let request = results.nextScan(rowCount: searched)!
    results.complete(request, matches: rows)
    return results
}

@Suite struct FindResultsTests {
    @Test func scanAppendsMatchesAndAdvances() {
        var results = FindResults()
        let first = results.nextScan(rowCount: 10)
        #expect(first?.range == 0..<10)
        results.complete(first!, matches: [2, 5])
        #expect(results.rows == [2, 5])
        #expect(results.searchedRowCount == 10)
        #expect(results.nextScan(rowCount: 10) == nil)

        let second = results.nextScan(rowCount: 15)
        #expect(second?.range == 10..<15)
        #expect(results.complete(second!, matches: [11]) == 10..<15)
        #expect(results.rows == [2, 5, 11])
        #expect(results.count == 3)
    }

    @Test func emptyTableHasNothingToScan() {
        #expect(FindResults().nextScan(rowCount: 0) == nil)
    }

    @Test func removeFrontShiftsMatches() {
        var results = results([2, 5, 9], searched: 10)
        results.removeFront(4)
        #expect(results.rows == [1, 5])
        #expect(results.searchedRowCount == 6)
    }

    @Test func removeFrontPastEverythingEmptiesResults() {
        var results = results([2, 5], searched: 10)
        results.removeFront(30)
        #expect(results.rows == [])
        #expect(results.searchedRowCount == 0)
    }

    @Test func trimDuringScanRebasesResults() {
        var results = FindResults()
        let request = results.nextScan(rowCount: 20)!
        results.removeFront(5)
        let covered = results.complete(request, matches: [3, 7, 19])
        #expect(results.rows == [2, 14])
        #expect(results.searchedRowCount == 15)
        #expect(covered == 0..<15)
    }

    @Test func staleScanIsDropped() {
        var results = FindResults()
        let request = results.nextScan(rowCount: 20)!
        results.reset()
        #expect(results.complete(request, matches: [3]) == nil)
        #expect(results.rows == [])
        #expect(results.searchedRowCount == 0)
        #expect(results.nextScan(rowCount: 20)?.range == 0..<20)
    }

    @Test func nextAndPreviousWrap() {
        let results = results([3, 8, 12], searched: 20)
        #expect(results.target(.next, from: .selection(8...8)) == 12)
        #expect(results.target(.next, from: .selection(12...12)) == 3)
        #expect(results.target(.previous, from: .selection(3...3)) == 12)
        #expect(results.target(.previous, from: .selection(5...9)) == 3)
        #expect(results.target(.next, from: .selection(5...9)) == 12)
    }

    @Test func nextFromViewport() {
        let results = results([3, 8, 12], searched: 20)
        #expect(results.target(.next, from: .viewport(8...20)) == 8)
        #expect(results.target(.next, from: .viewport(13...20)) == 3)
        #expect(results.target(.previous, from: .viewport(0...10)) == 8)
        #expect(results.target(.previous, from: .viewport(0...2)) == 12)
        #expect(results.target(.next, from: .none) == 3)
        #expect(results.target(.previous, from: .none) == 12)
    }

    @Test func noMatchesGivesNil() {
        let results = FindResults()
        for anchor in [FindAnchor.none, .selection(1...2), .viewport(0...9)] {
            #expect(results.target(.next, from: anchor) == nil)
            #expect(results.target(.previous, from: anchor) == nil)
        }
    }

    @Test func ordinal() {
        let results = results([3, 8, 12], searched: 20)
        #expect(results.ordinal(of: 8) == 1)
        #expect(results.ordinal(of: 9) == nil)
        #expect(results.contains(12))
        #expect(!results.contains(13))
    }

    // MARK: Scenario

    private struct Row {
        var entryID: Int
        var line: Int32
    }

    /// Mirrors `LogSession`'s row table: one row per message line, entries trimmed from the front.
    private struct Table {
        var entries: [Int: LogEntry] = [:]
        var rows: [Row] = []

        mutating func append(_ entry: LogEntry) {
            entries[entry.id] = entry
            appendRows(of: entry)
        }

        mutating func appendRows(of entry: LogEntry) {
            let lines = entry.message.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            for line in 0..<lines {
                rows.append(Row(entryID: entry.id, line: Int32(line)))
            }
        }

        /// Drops every entry below `id`; returns the number of rows removed from the front.
        mutating func trim(below id: Int) -> Int {
            let removed = rows.prefix { $0.entryID < id }.count
            rows.removeFirst(removed)
            for key in entries.keys where key < id {
                entries[key] = nil
            }
            return removed
        }

        func bruteForce(_ finder: LogFinder) -> [Int] {
            rows.indices.filter { index in
                let row = rows[index]
                return entries[row.entryID].map { finder.matchingLines(of: $0).contains(row.line) } ?? false
            }
        }

        func scan(_ request: FindResults.ScanRequest, _ finder: LogFinder) -> [Int] {
            finder.matchingRows(
                in: request.range,
                row: { (rows[$0].entryID, rows[$0].line) },
                entry: { entries[$0] }
            )
        }

        func scanToCompletion(_ results: inout FindResults, _ finder: LogFinder) {
            while let request = results.nextScan(rowCount: rows.count) {
                results.complete(request, matches: scan(request, finder))
            }
        }
    }

    private static func makeEntry(_ id: Int) -> LogEntry {
        let message = if id % 11 == 0 {
            "x\nneedle tail\ny"
        } else if id % 7 == 0 {
            "needle \(id)"
        } else {
            "plain \(id)"
        }
        return LogEntry(
            id: id, timestamp: 1_000_000, pid: 1, tid: 1, level: .info,
            tag: id % 50 == 0 ? "NeedleTag" : "Tag", message: message
        )
    }

    @Test func countMatchesBruteForceAcrossFilterTrimAndAppend() throws {
        let finder = try LogFinder("needle")
        var table = Table()
        var results = FindResults()

        // 1. Initial rows, full scan.
        for id in 0..<1000 { table.append(Self.makeEntry(id)) }
        table.scanToCompletion(&results, finder)
        #expect(results.rows == table.bruteForce(finder))
        #expect(!results.rows.isEmpty)

        // 2. Trim the first 100 entries.
        results.removeFront(table.trim(below: 100))
        #expect(results.rows == table.bruteForce(finder))

        // 3. Append 200 entries, scan incrementally.
        for id in 1000..<1200 { table.append(Self.makeEntry(id)) }
        table.scanToCompletion(&results, finder)
        #expect(results.rows == table.bruteForce(finder))

        // 4. A scan that is running while the table is trimmed.
        for id in 1200..<1250 { table.append(Self.makeEntry(id)) }
        let request = try #require(results.nextScan(rowCount: table.rows.count))
        let matches = table.scan(request, finder)
        results.removeFront(table.trim(below: 130))
        results.complete(request, matches: matches)
        table.scanToCompletion(&results, finder)
        #expect(results.rows == table.bruteForce(finder))

        // 5. Refilter to even entry ids.
        let even = table.entries.values.filter { $0.id % 2 == 0 }.sorted { $0.id < $1.id }
        table.rows = []
        for entry in even { table.appendRows(of: entry) }
        results.reset()
        table.scanToCompletion(&results, finder)
        #expect(results.rows == table.bruteForce(finder))
    }
}
