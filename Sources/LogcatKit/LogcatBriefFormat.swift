import Foundation

/// `L/Tag(pid): message`, with an optional time in front: `-v brief`, `-v time`
/// (`11-10 08:01:51.178 D/WM-Processor(26351): …`) and Firebase Crashlytics logs
/// (`05-16 07:39:26.519: D/AOC(1054): …`, Android Studio's FIREBASE format). None of them has a tid, so it is 0, as
/// in Android Studio. `-v brief` has no time either, so each of its lines gets the file's reference date.
public enum LogcatBriefFormat {
    public static func parseLine(_ line: String, referenceDate: Date = Date()) -> LogEntry? {
        parseLine(Substring(line), referenceDate: referenceDate)
    }

    public static func parseLine(_ line: Substring, referenceDate: Date = Date()) -> LogEntry? {
        parse(line: line, referenceDate: referenceDate)?.entry
    }

    /// Parses a whole text. Lines of one record share a time, pid and tag, so they merge as in the threadtime
    /// parser, except when the lines have no time at all (`-v brief`): then equal times mean nothing and every
    /// line stays an entry of its own.
    public static func parse(_ text: String, referenceDate: Date = Date()) -> [LogEntry] {
        var parser = BriefTextParser(referenceDate: referenceDate)
        var entries: [LogEntry] = []
        text.enumerateLines { line, _ in
            if let entry = parser.consume(Substring(line)) { entries.append(entry) }
        }
        if let last = parser.finish() { entries.append(last) }
        return entries
    }

    /// `hasTime` is false when the line carried no time and the entry has the reference date.
    static func parse(line: Substring, referenceDate: Date) -> (entry: LogEntry, hasTime: Bool)? {
        var body = line
        var timestamp = referenceDate.timeIntervalSince1970
        var hasTime = false
        if let first = line.utf8.first, first >= UInt8(ascii: "0"), first <= UInt8(ascii: "9") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3 else { return nil }
            // Firebase puts a colon after the time.
            let time = parts[1].hasSuffix(":") ? parts[1].dropLast() : parts[1]
            guard let parsed = LogcatTime.parse(date: parts[0], time: time, referenceDate: referenceDate) else { return nil }
            timestamp = parsed
            hasTime = true
            body = parts[2]
        }

        let bytes = body.utf8
        guard bytes.count >= 4, let levelByte = bytes.first,
              let level = LogLevel(letter: Character(Unicode.Scalar(levelByte))),
              bytes[bytes.index(after: bytes.startIndex)] == UInt8(ascii: "/")
        else { return nil }

        // The tag runs to the first "(" that opens a "(pid): " or a "(pid):" at the end, like Android Studio's
        // lazy `(?<tag>.+?(?=\())\((?<pid>\d+)\): `. A tag may itself contain parentheses.
        let tagStart = bytes.index(bytes.startIndex, offsetBy: 2)
        var open = tagStart
        while open < bytes.endIndex {
            if bytes[open] == UInt8(ascii: "("), let close = pidEnd(in: bytes, after: open) {
                let pidDigits = body[bytes.index(after: open)..<close]
                    .drop(while: { $0 == " " })
                guard let pid = Int32(pidDigits) else { return nil }
                let tag = body[tagStart..<open].trimmingTrailingSpaces()
                guard !tag.isEmpty else { return nil }
                // `close` is the ")": a colon follows, then a space (or the end of the line, for an empty message).
                let space = bytes.index(close, offsetBy: 2)
                let message = space < bytes.endIndex ? String(body[bytes.index(after: space)...]) : ""
                return (LogEntry(timestamp: timestamp, pid: pid, tid: 0, level: level, tag: String(tag), message: message), hasTime)
            }
            open = bytes.index(after: open)
        }
        return nil
    }

    /// If `open` starts `(  123):` followed by a space or the end of the line, the index of the `)`.
    private static func pidEnd(in bytes: Substring.UTF8View, after open: Substring.UTF8View.Index) -> Substring.UTF8View.Index? {
        var index = bytes.index(after: open)
        while index < bytes.endIndex, bytes[index] == UInt8(ascii: " ") { index = bytes.index(after: index) }
        let digitsStart = index
        while index < bytes.endIndex, bytes[index] >= UInt8(ascii: "0"), bytes[index] <= UInt8(ascii: "9") {
            index = bytes.index(after: index)
        }
        guard index > digitsStart, index < bytes.endIndex, bytes[index] == UInt8(ascii: ")") else { return nil }
        let colon = bytes.index(after: index)
        guard colon < bytes.endIndex, bytes[colon] == UInt8(ascii: ":") else { return nil }
        let next = bytes.index(after: colon)
        guard next == bytes.endIndex || bytes[next] == UInt8(ascii: " ") else { return nil }
        return index
    }
}

/// Line by line parsing of brief-style text, for ``LogcatBriefFormat/parse(_:referenceDate:)`` and the chunked reader.
struct BriefTextParser {
    private var merger = RecordMerger()
    private let referenceDate: Date

    init(referenceDate: Date) {
        self.referenceDate = referenceDate
    }

    /// Returns the entry this line completes, if any.
    mutating func consume(_ line: Substring) -> LogEntry? {
        guard let (entry, hasTime) = LogcatBriefFormat.parse(line: line, referenceDate: referenceDate) else { return nil }
        // Without a time, "same time" is true of every line, so nothing can be merged.
        return hasTime ? merger.add(entry) : entry
    }

    mutating func finish() -> LogEntry? {
        merger.flush()
    }
}
