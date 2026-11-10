import Foundation
import Testing
@testable import LogcatKit

@Suite struct MessageLinesTests {
    private func lines(_ message: String) -> [MessageLine] {
        MessageLines.lines(of: message)
    }

    private func texts(_ message: String) -> [String] {
        lines(message).map { $0.text(in: message) }
    }

    @Test func singleLineASCII() {
        let message = "hello world"
        let result = lines(message)
        #expect(result == [MessageLine(utf8Offset: 0, utf8Count: 11, cells: 11, isASCII: true)])
        #expect(result[0].text(in: message) == message)
    }

    @Test func emptyMessageIsOneEmptyLine() {
        #expect(lines("") == [MessageLine(utf8Offset: 0, utf8Count: 0, cells: 0, isASCII: true)])
    }

    @Test func splitsOnNewlinesKeepingEmptyLines() {
        let message = "a\n\nbc\n"
        let result = lines(message)
        #expect(result.map(\.utf8Offset) == [0, 2, 3, 6])
        #expect(result.map(\.utf8Count) == [1, 0, 2, 0])
        #expect(texts(message) == ["a", "", "bc", ""])
    }

    @Test func matchesFinderSplit() {
        // LogFinder splits with this exact call, and its line numbers must agree with the rows built here.
        for message in ["x", "a\nb", "\n", "a\n\n", "日本\nabc😀\nz", "\n\n\n", "tail\n"] {
            let expected = message.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            #expect(texts(message) == expected, "message: \(message.debugDescription)")
        }
    }

    @Test func carriageReturnIsPartOfTheLine() {
        // One row per "\n" byte, as the row builder has always counted. (A Character split would treat
        // "\r\n" as a single character and not split; the rows follow the bytes.)
        #expect(texts("a\r\nb") == ["a\r", "b"])
    }

    @Test func textUsesUTF8Offsets() {
        let message = "日本\nabc😀\nz"
        let result = lines(message)
        #expect(result.count == 3)
        #expect(result[0].utf8Offset == 0 && result[0].utf8Count == 6)
        #expect(result[1].utf8Offset == 7 && result[1].utf8Count == 7)
        #expect(result[2].utf8Offset == 15 && result[2].utf8Count == 1)
        #expect(result[1].text(in: message) == "abc😀")
        #expect(result[2].text(in: message) == "z")
    }

    @Test func wideScalarsCountTwo() {
        #expect(lines("日本語")[0].cells == 6)
        #expect(!lines("日本語")[0].isASCII)
        #expect(lines("a😀b")[0].cells == 4)
        // Cyrillic is below U+1100: one cell each, even though it is not ASCII.
        #expect(lines("Привет")[0].cells == 6)
        #expect(!lines("Привет")[0].isASCII)
    }

    @Test func wideBoundaryIsU1100() {
        #expect(lines("\u{10FF}")[0].cells == 1)
        #expect(lines("\u{1100}")[0].cells == 2)
        #expect(lines("\u{FFFF}")[0].cells == 2)
        #expect(lines("\u{10000}")[0].cells == 2)
    }

    @Test func tabCountsEightCells() {
        let frame = "at com.example.Foo.bar(Foo.kt:12)"
        let line = lines("\t" + frame)[0]
        #expect(line.cells == Int32(MessageLines.tabCells + frame.count))
        #expect(!line.isASCII)
    }

    @Test func controlCharactersAreNotASCII() {
        #expect(lines("a\rb")[0].cells == 3)
        #expect(!lines("a\rb")[0].isASCII)
        #expect(lines("a~b")[0].isASCII)
        #expect(!lines("a\u{7F}b")[0].isASCII)
    }

    @Test func cellsOfText() {
        #expect(MessageLines.cells("ab日") == 4)
        #expect(MessageLines.cells(Substring("\t")) == 8)
        #expect(MessageLines.cells("") == 0)
    }

    @Test func spanCellsAgreeWithCellsOfText() {
        let message = "plain\n\tat a.b(C.kt:1)\n日本語 mixed é\n😀😀\n\u{1100}x\r"
        for line in lines(message) {
            #expect(Int(line.cells) == MessageLines.cells(line.text(in: message)))
        }
    }

    @Test func wrappedLineCount() {
        func line(_ cells: Int32) -> MessageLine {
            MessageLine(utf8Offset: 0, utf8Count: cells, cells: cells, isASCII: true)
        }
        #expect(line(0).wrappedLineCount(columns: 10) == 1)
        #expect(line(10).wrappedLineCount(columns: 10) == 1)
        #expect(line(11).wrappedLineCount(columns: 10) == 2)
        #expect(line(2000).wrappedLineCount(columns: 100) == 20)
        #expect(line(2000).wrappedLineCount(columns: 0) == 2000)
    }

    @Test func markerDecorationFits() {
        let fits = MessageLine(utf8Offset: 0, utf8Count: 92, cells: 92, isASCII: true)
        let wraps = MessageLine(utf8Offset: 0, utf8Count: 93, cells: 93, isASCII: true)
        #expect(fits.wrappedLineCount(columns: 100, extraCells: 8) == 1)
        #expect(wraps.wrappedLineCount(columns: 100, extraCells: 8) == 2)
    }
}
