import Foundation

/// Parses `log stream --style ndjson` output (Apple's unified logging) into `LogEntry` values, so iOS
/// simulator logs share the table, filters and crash highlighting with logcat.
///
/// Mapping:
/// - level: `Debug` → D, `Info` and `Default` → I, `Error` → E, `Fault` → A
/// - tag: `subsystem:category`, or the subsystem alone; without a subsystem (NSLog and most system
///   frameworks), the name of the library that logged (`UIKitCore`), else the process name
/// - process: the executable name, so `package:` and `process:` match the app
/// - uid, pid, tid: `userID`, `processID`, `threadID`
///
/// Each line is one JSON object; JSON escapes newlines in strings, so a raw newline always ends a record.
public struct UnifiedLogParser: Sendable {
    private var partial = Data()

    public init() {}

    /// Parses the complete lines in `data` and keeps any trailing partial line for the next call.
    public mutating func feed(_ data: Data) -> [LogEntry] {
        partial.append(data)
        guard let lastNewline = partial.lastIndex(of: 0x0A) else { return [] }
        let complete = partial[partial.startIndex..<lastNewline]
        let entries = Self.parseLines(complete)
        partial = Data(partial[partial.index(after: lastNewline)...])
        return entries
    }

    /// Parses whatever is left once the stream ended.
    public mutating func finish() -> [LogEntry] {
        defer { partial = Data() }
        return Self.parseLines(partial)
    }

    public static func parseLines(_ data: Data) -> [LogEntry] {
        let decoder = JSONDecoder()
        var entries: [LogEntry] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let entry = parseLine(line, decoder: decoder) {
                entries.append(entry)
            }
        }
        return entries
    }

    public static func parseLine(_ line: String) -> LogEntry? {
        parseLine(Data(line.utf8), decoder: JSONDecoder())
    }

    private static func parseLine(_ line: Data, decoder: JSONDecoder) -> LogEntry? {
        // `log` prints status text such as "Filtering the log data using ..." in some modes; skip anything that
        // isn't an object rather than failing the stream.
        guard line.first == UInt8(ascii: "{"),
              let event = try? decoder.decode(Event.self, from: line),
              event.eventType == "logEvent",
              let timestamp = event.timestamp.flatMap(parseTimestamp)
        else { return nil }

        let process = event.processImagePath.map(lastPathComponent) ?? ""
        let subsystem = event.subsystem ?? ""
        let category = event.category ?? ""
        let tag: String
        if !subsystem.isEmpty {
            tag = category.isEmpty ? subsystem : "\(subsystem):\(category)"
        } else if let sender = event.senderImagePath.map(lastPathComponent), !sender.isEmpty {
            tag = sender
        } else {
            tag = process
        }
        return LogEntry(
            timestamp: timestamp,
            uid: event.userID.map(String.init),
            pid: Int32(truncatingIfNeeded: event.processID ?? 0),
            tid: Int32(truncatingIfNeeded: event.threadID ?? 0),
            level: level(forMessageType: event.messageType),
            tag: tag,
            message: event.eventMessage ?? "",
            processName: process.isEmpty ? nil : process
        )
    }

    public static func level(forMessageType type: String?) -> LogLevel {
        switch type {
        case "Debug": .debug
        case "Error": .error
        case "Fault": .assert
        default: .info // Info, Default, and anything newer
        }
    }

    private static func lastPathComponent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// Parses `2026-11-12 15:10:50.131397-0500` into seconds since 1970. Done by hand because a
    /// `DateFormatter` per line is too slow for a busy simulator, and the format is fixed.
    public static func parseTimestamp(_ text: String) -> Double? {
        var text = text
        return text.withUTF8 { bytes -> Double? in
            // yyyy-MM-dd HH:mm:ss[.f+]±hhmm
            guard bytes.count >= 24 else { return nil }
            func number(_ start: Int, _ length: Int) -> Int? {
                var value = 0
                for index in start..<(start + length) {
                    let digit = Int(bytes[index]) - 48
                    guard digit >= 0, digit <= 9 else { return nil }
                    value = value * 10 + digit
                }
                return value
            }
            guard bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"), bytes[10] == UInt8(ascii: " "),
                  bytes[13] == UInt8(ascii: ":"),
                  bytes[16] == UInt8(ascii: ":"),
                  let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
                  let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2)
            else { return nil }

            var index = 19
            var fraction = 0.0
            if bytes[index] == UInt8(ascii: ".") {
                index += 1
                var scale = 0.1
                while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
                    fraction += Double(bytes[index] - 48) * scale
                    scale /= 10
                    index += 1
                }
            }
            guard index + 5 == bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-"),
                  let offsetHours = number(index + 1, 2), let offsetMinutes = number(index + 3, 2)
            else { return nil }
            let offset = (offsetHours * 3600 + offsetMinutes * 60) * (bytes[index] == UInt8(ascii: "-") ? -1 : 1)

            let days = daysFromCivil(year: year, month: month, day: day)
            let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offset
            return Double(seconds) + fraction
        }
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar (Howard Hinnant's algorithm).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private struct Event: Decodable {
        var eventType: String?
        var messageType: String?
        var timestamp: String?
        var processID: Int64?
        var threadID: Int64?
        var userID: Int64?
        var subsystem: String?
        var category: String?
        var processImagePath: String?
        var senderImagePath: String?
        var eventMessage: String?
    }
}
