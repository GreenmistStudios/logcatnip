import Foundation

/// The metadata part of a logcat record.
public struct LogcatHeader: Sendable, Equatable {
    public var timestamp: Double
    public var uid: String?
    public var pid: Int32
    public var tid: Int32
    public var level: LogLevel
    public var tag: String

    public init(timestamp: Double, uid: String? = nil, pid: Int32, tid: Int32, level: LogLevel, tag: String) {
        self.timestamp = timestamp
        self.uid = uid
        self.pid = pid
        self.tid = tid
        self.level = level
        self.tag = tag
    }

    func entry(message: String) -> LogEntry {
        LogEntry(timestamp: timestamp, uid: uid, pid: pid, tid: tid, level: level, tag: tag, message: message)
    }
}

/// Parsing for `logcat -v long` output, which Android Studio also uses. Each record is a bracketed header
/// line, the message lines, then a blank line:
///
/// ```
/// [ 1794248132.663  1046: 2093: 1697 W/qdgralloc ]
/// getInterlacedFlag: getMetaData returned 3
///
/// ```
///
/// The header may carry an epoch (`-v epoch`) or a `[YYYY-]MM-DD HH:MM:SS.mmm` time, and an optional uid
/// (`-v uid`) before the pid.
public enum LogcatLongFormat {
    /// `referenceDate` supplies the year of a header that has none (`nil` is now); see
    /// ``LogcatTime/parse(date:time:timeZone:referenceDate:)``. It is optional so that non-header lines, which
    /// are most of a stream, don't read the clock.
    public static func parseHeader(_ line: String, referenceDate: Date? = nil) -> LogcatHeader? {
        parseHeader(Substring(line), referenceDate: referenceDate)
    }

    public static func parseHeader(_ line: Substring, referenceDate: Date? = nil) -> LogcatHeader? {
        let utf8 = line.utf8
        guard utf8.first == UInt8(ascii: "["), utf8.last == UInt8(ascii: "]") else { return nil }
        let inner = line.dropFirst().dropLast()

        // Find the "L/" level marker: a level letter preceded by a space and followed by '/'.
        let bytes = inner.utf8
        var markerIndex: String.Index?
        var previous: UInt8 = UInt8(ascii: " ")
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            let next = bytes.index(after: index)
            if previous == UInt8(ascii: " "), next < bytes.endIndex, bytes[next] == UInt8(ascii: "/"),
               isLevelLetter(byte) {
                markerIndex = index
                break
            }
            previous = byte
            index = next
        }
        guard let marker = markerIndex,
              let level = LogLevel(letter: Character(Unicode.Scalar(bytes[marker])))
        else { return nil }

        let tagStart = inner.index(marker, offsetBy: 2)
        let tag = inner[tagStart...].trimmingTrailingSpaces()

        let tokens = inner[..<marker].split(separator: " ", omittingEmptySubsequences: true)
        guard !tokens.isEmpty else { return nil }

        let timestamp: Double
        let idTokens: ArraySlice<Substring>
        if tokens[0].contains("-") {
            guard tokens.count >= 2,
                  let parsed = LogcatTime.parse(date: tokens[0], time: tokens[1], referenceDate: referenceDate ?? Date())
            else { return nil }
            timestamp = parsed
            idTokens = tokens.dropFirst(2)
        } else {
            guard let parsed = LogcatTime.parseEpoch(tokens[0]) else { return nil }
            timestamp = parsed
            idTokens = tokens.dropFirst()
        }

        // "1046: 2093: 1697" or "10388:32202:32202" or "2093: 1697".
        let ids = idTokens.joined().split(separator: ":", omittingEmptySubsequences: true)
        let uid: String?
        let pidText: Substring
        let tidText: Substring
        switch ids.count {
        case 2:
            uid = nil
            pidText = ids[0]
            tidText = ids[1]
        case 3:
            uid = String(ids[0])
            pidText = ids[1]
            tidText = ids[2]
        default:
            return nil
        }
        guard let pid = Int32(pidText), let tid = Int32(tidText) else { return nil }
        return LogcatHeader(timestamp: timestamp, uid: uid, pid: pid, tid: tid, level: level, tag: String(tag))
    }

    /// Formats an entry so that ``LogcatLongParser`` reads it back unchanged. The time is rounded like the
    /// table's, so Export and the table never show different milliseconds.
    public static func format(_ entry: LogEntry) -> String {
        let time = LogcatTime.formatEpoch(entry.timestamp)
        let uid = entry.uid.map { "\($0): " } ?? ""
        return "[ \(time) \(uid)\(entry.pid): \(entry.tid) \(entry.level.letter)/\(entry.tag) ]\n\(entry.message)\n\n"
    }

    private static func isLevelLetter(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "V"), UInt8(ascii: "D"), UInt8(ascii: "I"), UInt8(ascii: "W"),
             UInt8(ascii: "E"), UInt8(ascii: "F"), UInt8(ascii: "A"):
            true
        default:
            false
        }
    }
}

/// Incremental parser for `logcat -v long` output arriving in arbitrary chunks.
///
/// A record is emitted when the next header arrives, or at the end of a chunk that finished on the record's
/// terminating blank line, so a live stream shows records without waiting for the next one.
public struct LogcatLongParser: Sendable {
    private var partialLine: [UInt8] = []
    private var pendingHeader: LogcatHeader?
    private var pendingLines: [String] = []
    private var lastHeader: LogcatHeader?
    private var lastLineWasBlank = false
    private let referenceDate: Date?

    /// `referenceDate` supplies the year of headers that have none (a saved file's modification date). `nil`
    /// means now, read per header, which is right for a live stream.
    public init(referenceDate: Date? = nil) {
        self.referenceDate = referenceDate
    }

    public mutating func feed(_ data: Data) -> [LogEntry] {
        var output: [LogEntry] = []
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var lineStart = 0
            for (offset, byte) in buffer.enumerated() where byte == 0x0A {
                if partialLine.isEmpty {
                    consume(line: decode(buffer[lineStart..<offset]), into: &output)
                } else {
                    partialLine.append(contentsOf: buffer[lineStart..<offset])
                    consume(line: decode(partialLine[...]), into: &output)
                    partialLine.removeAll(keepingCapacity: true)
                }
                lineStart = offset + 1
            }
            if lineStart < buffer.count {
                partialLine.append(contentsOf: buffer[lineStart...])
            }
        }
        if lastLineWasBlank && partialLine.isEmpty {
            flush(into: &output)
        }
        return output
    }

    /// Emits whatever is buffered. Call when the stream ends.
    public mutating func finish() -> [LogEntry] {
        var output: [LogEntry] = []
        if !partialLine.isEmpty {
            consume(line: decode(partialLine[...]), into: &output)
            partialLine.removeAll()
        }
        flush(into: &output)
        return output
    }

    /// Parses a complete text (for example a saved file).
    public static func parse(_ text: String, referenceDate: Date = Date()) -> [LogEntry] {
        var parser = LogcatLongParser(referenceDate: referenceDate)
        var entries = parser.feed(Data(text.utf8))
        entries += parser.finish()
        return entries
    }

    private mutating func consume(line rawLine: String, into output: inout [LogEntry]) {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if let header = LogcatLongFormat.parseHeader(line, referenceDate: referenceDate) {
            flush(into: &output)
            pendingHeader = header
            lastHeader = header
            lastLineWasBlank = false
            return
        }
        if line.hasPrefix("--------- ") {
            // "--------- beginning of main" / "switch to system".
            flush(into: &output)
            lastLineWasBlank = false
            return
        }
        lastLineWasBlank = line.isEmpty
        if pendingHeader != nil {
            pendingLines.append(line)
        } else if !line.isEmpty, let header = lastHeader {
            // A continuation that arrived after the record was already flushed (a blank line inside a
            // message split across reads). Keep it, attributed to the same record metadata.
            pendingHeader = header
            pendingLines.append(line)
        }
    }

    private mutating func flush(into output: inout [LogEntry]) {
        guard let header = pendingHeader else { return }
        while let last = pendingLines.last, last.isEmpty {
            pendingLines.removeLast()
        }
        output.append(header.entry(message: pendingLines.joined(separator: "\n")))
        pendingHeader = nil
        pendingLines.removeAll(keepingCapacity: true)
    }

    private func decode<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        String(decoding: bytes, as: UTF8.self)
    }
}

/// Parsing for the `threadtime` format (the `adb logcat` default and what bug reports contain), used when
/// importing files:
///
/// ```
/// 11-09 13:11:17.123  1234  5678 I ActivityManager: Start proc 4321:com.example/u0a123
/// ```
///
/// Also accepts a leading year, an epoch time, and a uid column.
public enum LogcatThreadtimeFormat {
    /// `referenceDate` supplies the year of a line that has none; see ``LogcatTime/parse(date:time:timeZone:referenceDate:)``.
    public static func parseLine(_ line: String, referenceDate: Date = Date()) -> LogEntry? {
        parseLine(Substring(line), referenceDate: referenceDate)
    }

    public static func parseLine(_ line: Substring, referenceDate: Date = Date()) -> LogEntry? {
        let tokens = line.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true)
        guard tokens.count >= 4 else { return nil }

        var cursor = 0
        let timestamp: Double
        if tokens[0].contains("-") {
            guard let parsed = LogcatTime.parse(date: tokens[0], time: tokens[1], referenceDate: referenceDate) else { return nil }
            timestamp = parsed
            cursor = 2
        } else {
            guard tokens[0].contains("."), let parsed = LogcatTime.parseEpoch(tokens[0]) else { return nil }
            timestamp = parsed
            cursor = 1
        }

        guard let levelIndex = tokens.indices.first(where: { index in
            index > cursor + 1 && tokens[index].count == 1 && LogLevel(letter: tokens[index].first!) != nil
        }) else { return nil }
        let ids = tokens[cursor..<levelIndex]
        let uid: String?
        let pidText: Substring
        let tidText: Substring
        switch ids.count {
        case 2:
            uid = nil
            pidText = ids[ids.startIndex]
            tidText = ids[ids.startIndex + 1]
        case 3:
            uid = String(ids[ids.startIndex])
            pidText = ids[ids.startIndex + 1]
            tidText = ids[ids.startIndex + 2]
        default:
            return nil
        }
        guard let pid = Int32(pidText), let tid = Int32(tidText),
              let level = LogLevel(letter: tokens[levelIndex].first!)
        else { return nil }

        let tag: String
        let message: String
        if levelIndex + 1 < tokens.count {
            let rest = line[tokens[levelIndex + 1].startIndex...]
            if let separator = rest.range(of: ": ") {
                tag = String(rest[..<separator.lowerBound].trimmingTrailingSpaces())
                message = String(rest[separator.upperBound...])
            } else if rest.hasSuffix(":") {
                tag = String(rest.dropLast().trimmingTrailingSpaces())
                message = ""
            } else {
                tag = String(rest.trimmingTrailingSpaces())
                message = ""
            }
        } else {
            tag = ""
            message = ""
        }
        return LogEntry(timestamp: timestamp, uid: uid, pid: pid, tid: tid, level: level, tag: tag, message: message)
    }

    /// Parses a whole threadtime file. Consecutive lines from the same record (same time, pid, tid, level and
    /// tag, as logcat prints multi-line messages) are merged into one entry. One `referenceDate` serves every
    /// line, so a file never straddles two guesses of the year.
    public static func parse(_ text: String, referenceDate: Date = Date()) -> [LogEntry] {
        var entries: [LogEntry] = []
        text.enumerateLines { line, _ in
            guard let entry = parseLine(line, referenceDate: referenceDate) else { return }
            if var last = entries.last,
               last.timestamp == entry.timestamp, last.pid == entry.pid, last.tid == entry.tid,
               last.level == entry.level, last.tag == entry.tag {
                last.message += "\n" + entry.message
                entries[entries.count - 1] = last
            } else {
                entries.append(entry)
            }
        }
        return entries
    }
}

/// Picks the right parser for a saved log file.
public enum LogFileImporter {
    /// `referenceDate` supplies the year of lines that have none; see ``LogcatTime/parse(date:time:timeZone:referenceDate:)``.
    public static func parse(_ text: String, referenceDate: Date = Date()) -> [LogEntry] {
        let firstLine = text.split(separator: "\n", maxSplits: 20, omittingEmptySubsequences: true)
            .first { !$0.hasPrefix("---------") }
        if let firstLine, firstLine.hasPrefix("[") {
            return LogcatLongParser.parse(text, referenceDate: referenceDate)
        }
        return LogcatThreadtimeFormat.parse(text, referenceDate: referenceDate)
    }

    /// Reads and parses a saved log. Its modification date stands in for the year that threadtime and legacy
    /// long lines lack; a file without one (or with unreadable attributes) falls back to now.
    public static func load(contentsOf url: URL) throws -> [LogEntry] {
        let data = try Data(contentsOf: url)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return parse(String(decoding: data, as: UTF8.self), referenceDate: modified ?? Date())
    }
}

extension StringProtocol where SubSequence == Substring {
    func trimmingTrailingSpaces() -> Substring {
        var end = endIndex
        while end > startIndex {
            let previous = index(before: end)
            guard self[previous] == " " || self[previous] == "\t" else { break }
            end = previous
        }
        return self[startIndex..<end]
    }
}
