import Foundation
import Testing
@testable import LogcatKit

private func entry(tag: String = "Tag", message: String = "hello") -> LogEntry {
    LogEntry(timestamp: 1_000_000, pid: 100, tid: 101, level: .info, tag: tag, message: message)
}

private func ranges(_ query: String, in text: String, _ options: FindOptions = FindOptions()) throws -> [NSRange] {
    try LogFinder(query, options: options).ranges(in: text)
}

@Suite struct FindTests {
    @Test func emptyQueryMatchesNothing() throws {
        let finder = try LogFinder("")
        #expect(finder.isEmpty)
        #expect(!finder.matches("abc"))
        #expect(finder.ranges(in: "abc") == [])
        #expect(finder.matchingLines(of: entry(message: "abc")) == [])
    }

    @Test func plainFindIsCaseInsensitiveByDefault() throws {
        #expect(try ranges("world", in: "Hello World") == [NSRange(location: 6, length: 5)])
        #expect(try ranges("world", in: "Hello World", FindOptions(matchCase: true)) == [])
        #expect(try ranges("World", in: "Hello World", FindOptions(matchCase: true)) == [NSRange(location: 6, length: 5)])
    }

    @Test func plainQueryWithRegexCharactersIsLiteral() throws {
        #expect(try ranges("a.c(", in: "xa.c(y") == [NSRange(location: 1, length: 4)])
        #expect(try ranges("a.c(", in: "xabc(y") == [])
    }

    @Test func regexFind() throws {
        let found = try ranges(#"\d{3}"#, in: "id 123 and 4567", FindOptions(regex: true))
        #expect(found == [NSRange(location: 3, length: 3), NSRange(location: 11, length: 3)])
    }

    @Test func invalidRegexThrows() {
        #expect(throws: FindError(message: "Invalid regular expression")) {
            try LogFinder("(", options: FindOptions(regex: true))
        }
        // The same text is fine as a literal query.
        #expect((try? LogFinder("(")) != nil)
    }

    @Test func wholeWord() throws {
        let whole = FindOptions(wholeWord: true)
        #expect(try ranges("foo", in: "foo food foo_bar (foo)", whole)
            == [NSRange(location: 0, length: 3), NSRange(location: 18, length: 3)])
        #expect(try ranges("fo+", in: "foo food", FindOptions(regex: true, wholeWord: true)) == [NSRange(location: 0, length: 3)])
    }

    @Test func zeroLengthMatchesAreIgnored() throws {
        let regex = FindOptions(regex: true)
        let finder = try LogFinder("x*", options: regex)
        #expect(finder.ranges(in: "abc") == [])
        #expect(!finder.matches("abc"))
        #expect(finder.ranges(in: "axxb") == [NSRange(location: 1, length: 2)])
        #expect(finder.matches("axxb"))
    }

    @Test func rangesAreUTF16() throws {
        #expect(try ranges("error", in: "日本 error").first?.location == 3)
        #expect(try ranges("error", in: "😀 error").first?.location == 3)
    }

    @Test func matchingLinesSearchesTagOnFirstLineOnly() throws {
        let e = entry(tag: "NetworkTag", message: "line one\nnetwork two\nthree")
        #expect(try LogFinder("network").matchingLines(of: e) == [0, 1])
        #expect(try LogFinder("three").matchingLines(of: e) == [2])
        #expect(try LogFinder("tag").matchingLines(of: e) == [0])
    }

    @Test func matchingLinesKeepsTrailingEmptyLine() throws {
        let e = entry(tag: "X", message: "a\n")
        #expect(try LogFinder("a").matchingLines(of: e) == [0])
        // The empty second line is a row of its own but can never match: empty matches are ignored.
        #expect(try LogFinder("x*", options: FindOptions(regex: true)).matchingLines(of: e) == [0])
    }

    @Test func markersNeverMatch() throws {
        let marker = LogEntry.marker("Device disconnected")
        #expect(try LogFinder("Device").matchingLines(of: marker) == [])
    }

    @Test func matchingRowsSplitsEachEntryOnce() throws {
        let entries = [
            0: entry(message: "foo"),
            1: entry(message: "a\nfoo\nb"),
            2: entry(message: "bar"),
        ]
        let rows: [(entryID: Int, line: Int32)] = [(0, 0), (1, 0), (1, 1), (1, 2), (2, 0)]
        let finder = try LogFinder("foo")

        var lookups = 0
        let all = finder.matchingRows(
            in: 0..<rows.count,
            row: { rows[$0] },
            entry: { id in
                lookups += 1
                return entries[id]
            }
        )
        #expect(all == [0, 2])
        #expect(lookups == 3)

        // A range that starts in the middle of an entry still maps lines correctly.
        let tail = finder.matchingRows(in: 2..<5, row: { rows[$0] }, entry: { entries[$0] })
        #expect(tail == [2])
    }

    @Test func matchingRowsSkipsTrimmedEntries() throws {
        let finder = try LogFinder("foo")
        let rows: [(entryID: Int, line: Int32)] = [(0, 0), (1, 0)]
        let found = finder.matchingRows(in: 0..<2, row: { rows[$0] }, entry: { $0 == 1 ? entry(message: "foo") : nil })
        #expect(found == [1])
    }

    @Test func cancellationStopsAScan() throws {
        let finder = try LogFinder("foo")
        let e = entry(message: "foo")
        let found = finder.matchingRows(in: 0..<100_000, row: { ($0, 0) }, entry: { _ in e }, isCancelled: { true })
        #expect(found.count < 100_000)
    }
}
