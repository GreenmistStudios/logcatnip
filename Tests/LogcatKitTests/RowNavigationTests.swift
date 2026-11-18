import Foundation
import Testing
@testable import LogcatKit

private func entry(_ level: LogLevel, _ message: String = "message", kind: LogEntry.Kind = .log) -> LogEntry {
    if kind == .marker { return LogEntry.marker(message, at: 0) }
    return LogEntry(timestamp: 0, pid: 1, tid: 1, level: level, tag: "Tag", message: message)
}

@Suite struct RowNavigationTests {
    @Test func targetWrapsFromSelectionAndViewport() {
        let rows = [3, 8, 12]
        #expect(FindResults.target(in: rows, .next, from: .selection(8...8)) == 12)
        #expect(FindResults.target(in: rows, .next, from: .selection(12...12)) == 3)
        #expect(FindResults.target(in: rows, .previous, from: .selection(3...3)) == 12)
        #expect(FindResults.target(in: rows, .previous, from: .selection(5...9)) == 3)
        #expect(FindResults.target(in: rows, .next, from: .viewport(8...20)) == 8)
        #expect(FindResults.target(in: rows, .previous, from: .viewport(0...2)) == 12)
        #expect(FindResults.target(in: rows, .next, from: .none) == 3)
        #expect(FindResults.target(in: rows, .previous, from: .none) == 12)
    }

    @Test func targetOfOneRowIsThatRow() {
        for anchor in [FindAnchor.none, .selection(5...5), .viewport(0...3), .viewport(9...20)] {
            #expect(FindResults.target(in: [5], .next, from: anchor) == 5)
            #expect(FindResults.target(in: [5], .previous, from: anchor) == 5)
        }
    }

    @Test func noRowsGivesNil() {
        #expect(FindResults.target(in: [], .next, from: .selection(1...1)) == nil)
        #expect(FindResults.target(in: [], .previous, from: .none) == nil)
    }

    @Test func errorIndexNotesFirstLinesOfErrorsOnly() {
        var index = IncrementalRowIndex.errors
        index.note(entry(.info), firstRow: 0)
        index.note(entry(.error, "a\nb\nc"), firstRow: 1)
        index.note(entry(.warn), firstRow: 4)
        index.note(entry(.assert), firstRow: 5)
        index.note(entry(.error, kind: .marker), firstRow: 6)
        #expect(index.rows == [1, 5])
        #expect(index.target(.next, from: .selection(1...1)) == 5)
        #expect(index.target(.next, from: .selection(5...5)) == 1)
    }

    @Test func errorIndexFollowsFrontTrims() {
        var index = IncrementalRowIndex.errors
        for row in [2, 6, 9, 15] {
            index.note(entry(.error), firstRow: row)
        }
        index.removeFront(6)
        #expect(index.rows == [0, 3, 9])
        index.removeFront(0)
        #expect(index.rows == [0, 3, 9])
        index.removeFront(20)
        #expect(index.isEmpty)
        index.note(entry(.error), firstRow: 4)
        #expect(index.rows == [4])
        index.reset()
        #expect(index.rows == [])
    }

    @Test func insertKeepsRowsAscendingAndUnique() {
        var index = IncrementalRowIndex()
        index.note(entry(.error), firstRow: 0)
        #expect(index.isEmpty)
        for row in [4, 9, 2, 9, 12, 0, 7] {
            index.insert(row)
        }
        #expect(index.rows == [0, 2, 4, 7, 9, 12])
        index.removeFront(3)
        #expect(index.rows == [1, 4, 6, 9])
    }

    @Test func customPredicate() {
        var index = IncrementalRowIndex { $0.tag == "Net" }
        index.note(LogEntry(timestamp: 0, pid: 1, tid: 1, level: .info, tag: "Net", message: ""), firstRow: 0)
        index.note(entry(.error), firstRow: 1)
        #expect(index.rows == [0])
    }
}

@Suite struct SignalSummaryTextTests {
    private func summary(_ messages: [(String, LogLevel, String)]) -> SignalSummary {
        var index = SignalIndex()
        index.ingest(messages.enumerated().map { offset, item in
            // A minute apart, so ANRs never merge into one burst.
            LogEntry(id: offset, timestamp: Double(offset) * 60, pid: Int32(100 + offset), tid: 1, level: item.1,
                     tag: item.0, message: item.2)
        })
        return SignalSummary(index)
    }

    private let crash = ("AndroidRuntime", LogLevel.error, "FATAL EXCEPTION: main\njava.lang.IllegalStateException: boom")
    private let anr = ("ActivityManager", LogLevel.error, "ANR in com.example.app\nReason: Input dispatching timed out")
    private let jank = ("Choreographer", LogLevel.info, "Skipped 45 frames!  The application may be doing too much work on its main thread.")

    @Test func emptySummaryHasNoText() {
        #expect(SignalSummary().fatalText == nil)
        #expect(SignalSummary().warningText == nil)
    }

    @Test func singular() {
        let summary = summary([crash, anr, jank])
        #expect(summary.fatalText == "1 crash · 1 ANR")
        #expect(summary.warningText == "1 warning")
    }

    @Test func plural() {
        let summary = summary([crash, crash, anr, anr, jank, jank, jank])
        #expect(summary.fatalText == "2 crashes · 2 ANRs")
        #expect(summary.warningText == "3 warnings")
        #expect(summary.warningCount == 3)
    }

    @Test func onlyWarnings() {
        let summary = summary([jank])
        #expect(summary.fatalText == nil)
        #expect(summary.warningText == "1 warning")
    }

    @Test func onlyANRs() {
        #expect(summary([anr]).fatalText == "1 ANR")
    }
}
