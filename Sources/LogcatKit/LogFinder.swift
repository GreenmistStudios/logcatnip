import Foundation

public struct FindOptions: Sendable, Equatable {
    public var matchCase: Bool
    public var regex: Bool
    public var wholeWord: Bool

    public init(matchCase: Bool = false, regex: Bool = false, wholeWord: Bool = false) {
        self.matchCase = matchCase
        self.regex = regex
        self.wholeWord = wholeWord
    }
}

public struct FindError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// A compiled find query. Plain text, regex and whole word all compile to one `NSRegularExpression`, so
/// counting matches and highlighting them can never disagree.
public struct LogFinder: Sendable {
    public let query: String
    public let options: FindOptions
    /// Nil for an empty query, which matches nothing.
    private let compiled: CompiledRegex?

    public init(_ query: String, options: FindOptions = FindOptions()) throws(FindError) {
        self.query = query
        self.options = options
        guard !query.isEmpty else {
            compiled = nil
            return
        }
        var pattern = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord {
            // Wrapped in a group so alternations in a regex query stay inside the word boundaries.
            pattern = "(?<!\\w)(?:\(pattern))(?!\\w)"
        }
        do {
            compiled = CompiledRegex(regex: try NSRegularExpression(
                pattern: pattern,
                options: options.matchCase ? [] : [.caseInsensitive]
            ))
        } catch {
            throw FindError(message: "Invalid regular expression")
        }
    }

    public var isEmpty: Bool { compiled == nil }

    /// UTF-16 ranges of the non-empty matches, which is what `NSAttributedString` wants. Zero-length
    /// matches (the regex `x*`) are dropped: there is nothing to highlight and they would match every row.
    public func ranges(in text: String) -> [NSRange] {
        guard let regex = compiled?.regex else { return [] }
        let full = NSRange(location: 0, length: text.utf16.count)
        return regex.matches(in: text, range: full).map(\.range).filter { $0.length > 0 }
    }

    /// Whether `text` has a non-empty match. Stops at the first one.
    public func matches(_ text: String) -> Bool {
        guard let regex = compiled?.regex else { return false }
        var found = false
        let full = NSRange(location: 0, length: text.utf16.count)
        regex.enumerateMatches(in: text, range: full) { match, _, stop in
            if let match, match.range.length > 0 {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// Message lines of `entry` that match, as row line numbers. Line 0 also matches on the tag, because
    /// the table shows the tag on the first row of an entry only. Markers never match.
    public func matchingLines(of entry: LogEntry) -> [Int32] {
        var lines: [Int32] = []
        appendMatchingLines(of: entry, to: &lines)
        return lines
    }

    private func appendMatchingLines(of entry: LogEntry, to lines: inout [Int32]) {
        guard compiled != nil, entry.kind == .log else { return }
        let message = entry.message
        // Same split as the session's row builder: one row per "\n", trailing empty lines included.
        guard message.utf8.contains(0x0A) else {
            if matches(message) || matches(entry.tag) { lines.append(0) }
            return
        }
        for (index, line) in message.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let text = String(line)
            if matches(text) || (index == 0 && matches(entry.tag)) {
                lines.append(Int32(index))
            }
        }
    }

    /// Indexes in `range` of the rows that match. `row(i)` gives a row's entry id and line, and
    /// `entry(id)` looks an entry up (nil when it was trimmed). Rows of one entry are adjacent, so each
    /// entry is split once however many rows it spans. `isCancelled` is polled so a superseded scan
    /// stops early; its partial result must be discarded.
    public func matchingRows(
        in range: Range<Int>,
        row: (Int) -> (entryID: Int, line: Int32),
        entry: (Int) -> LogEntry?,
        isCancelled: () -> Bool = { false }
    ) -> [Int] {
        guard compiled != nil else { return [] }
        var found: [Int] = []
        var lastID: Int?
        var lines: [Int32] = []
        for index in range {
            if index & 0xFFF == 0, isCancelled() { break }
            let (entryID, line) = row(index)
            if entryID != lastID {
                lastID = entryID
                lines.removeAll(keepingCapacity: true)
                if let entry = entry(entryID) {
                    appendMatchingLines(of: entry, to: &lines)
                }
            }
            if lines.contains(line) { found.append(index) }
        }
        return found
    }
}
