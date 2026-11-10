import Foundation

/// Where one "\n"-separated line of a message sits and how wide it is in a monospaced font, so the table can
/// size and draw rows without splitting the message for every cell.
public struct MessageLine: Sendable, Equatable {
    /// Start of the line in the message's UTF-8 bytes.
    public var utf8Offset: Int32
    public var utf8Count: Int32
    /// Character cells, one per advance of the monospaced font: see `MessageLines.cells(_:)`.
    public var cells: Int32
    /// Printable ASCII only (0x20...0x7E), so `cells` times the advance is the exact rendered width.
    public var isASCII: Bool

    public init(utf8Offset: Int32, utf8Count: Int32, cells: Int32, isASCII: Bool) {
        self.utf8Offset = utf8Offset
        self.utf8Count = utf8Count
        self.cells = cells
        self.isASCII = isASCII
    }

    /// The line's text. Returns `message` itself when the line is the whole message, which is the common
    /// case and costs no allocation.
    public func text(in message: String) -> String {
        let utf8 = message.utf8
        if utf8Offset == 0, Int(utf8Count) == utf8.count { return message }
        let start = utf8.index(utf8.startIndex, offsetBy: Int(utf8Offset))
        let end = utf8.index(start, offsetBy: Int(utf8Count))
        return String(message[start..<end])
    }

    /// Visual lines when wrapped at `columns` cells, at least 1; `columns` below 1 counts as 1.
    /// `extraCells` is decoration drawn around the text (the dashes around a marker).
    public func wrappedLineCount(columns: Int, extraCells: Int = 0) -> Int {
        let width = max(1, columns)
        return max(1, (Int(cells) + extraCells + width - 1) / width)
    }
}

public enum MessageLines {
    /// A tab advances to the next tab stop (28 pt in AppKit's default paragraph style); 8 cells is at least
    /// that at every font size the app offers (9-20 pt), so wrapped heights never clip.
    public static let tabCells = 8

    /// Calls `body` for each line, in order, splitting on "\n" bytes with empty lines kept (a trailing
    /// newline gives a trailing empty line). That is how the session builds its rows and how `LogFinder`
    /// numbers lines. Allocation-free for native strings.
    public static func forEach(in message: String, _ body: (MessageLine) -> Void) {
        var message = message
        message.withUTF8 { bytes in
            var start = 0
            var ascii = true
            for index in 0..<bytes.count {
                let byte = bytes[index]
                if byte == 0x0A {
                    body(line(bytes, start..<index, ascii: ascii))
                    start = index + 1
                    ascii = true
                } else if byte < 0x20 || byte > 0x7E {
                    ascii = false
                }
            }
            body(line(bytes, start..<bytes.count, ascii: ascii))
        }
    }

    public static func lines(of message: String) -> [MessageLine] {
        var result: [MessageLine] = []
        forEach(in: message) { result.append($0) }
        return result
    }

    /// Cells for text: one per scalar below U+1100, two from U+1100 up (CJK and emoji render about twice
    /// as wide), `tabCells` per tab. Overestimating only leaves spare room; underestimating would clip.
    public static func cells(_ text: some StringProtocol) -> Int {
        var count = 0
        for scalar in text.unicodeScalars {
            if scalar.value == 0x09 {
                count += tabCells
            } else {
                count += scalar.value < 0x1100 ? 1 : 2
            }
        }
        return count
    }

    private static func line(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>, ascii: Bool) -> MessageLine {
        let count = range.count
        return MessageLine(
            utf8Offset: Int32(range.lowerBound),
            utf8Count: Int32(count),
            cells: Int32(ascii ? count : cells(utf8: bytes, range)),
            isASCII: ascii
        )
    }

    /// `cells(_:)` over UTF-8 bytes, so a non-ASCII line needs no String. A Swift string is valid UTF-8, but
    /// a stray or truncated sequence still counts one cell and cannot run past the line.
    private static func cells(utf8 bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> Int {
        var count = 0
        var index = range.lowerBound
        while index < range.upperBound {
            let byte = bytes[index]
            switch byte {
            case 0x09:
                count += tabCells
                index += 1
            case 0xC2..<0xE0:
                // Two bytes: U+0080...U+07FF.
                count += 1
                index += 2
            case 0xE0..<0xF0:
                // Three bytes: U+0800...U+FFFF, wide from U+1100 (E1 84 80).
                let wide = byte >= 0xE2 || (byte == 0xE1 && index + 1 < range.upperBound && bytes[index + 1] >= 0x84)
                count += wide ? 2 : 1
                index += 3
            case 0xF0...:
                // Four bytes: U+10000 and up.
                count += 2
                index += 4
            default:
                count += 1
                index += 1
            }
        }
        return count
    }
}
