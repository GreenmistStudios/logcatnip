import Foundation

/// The formats Save As… offers. `.logcat` is first and the default: it is the only one that keeps process names,
/// the device and the filter, and Android Studio opens it.
public enum LogSaveFormat: String, CaseIterable, Sendable, Identifiable {
    case logcat
    case long
    case threadtime
    case plainText

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .logcat: "Logcat (.logcat, Android Studio compatible)"
        case .long: "logcat -v long"
        case .threadtime: "Threadtime"
        case .plainText: "Plain text as displayed"
        }
    }

    public var fileExtension: String {
        self == .logcat ? LogcatFile.fileExtension : "txt"
    }

    /// Only the plain text keeps Logcatnip's markers ("Device disconnected" …); the others are logcat formats.
    public var includesMarkers: Bool { self == .plainText }

    /// `"<base>_<yyyy-MM-dd_HHmmss>.<ext>"`, like Android Studio's `<device>-Android-<release>_<timestamp>`. A `/` or
    /// `:` in `base` would be a path separator in the panel, so they become `-`.
    public func suggestedFileName(base: String, date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(
            format: "%04d-%02d-%02d_%02d%02d%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
        let safe = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(safe)_\(stamp).\(fileExtension)"
    }

    /// The name typed in the save panel, with its extension switched to this format's. Only `logcat` and `txt`
    /// extensions are replaced: a name like `bugreport.zip` keeps its `.zip` and gains the new one, and so does a
    /// device name such as `Medium Phone API 37.0`, whose `.0` is not an extension.
    public func fileName(switching name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        let stem = (ext == "logcat" || ext == "txt") ? (name as NSString).deletingPathExtension : name
        return "\(stem).\(fileExtension)"
    }
}

extension LogcatThreadtimeFormat {
    /// One line per message line, exactly as `logcat -v threadtime` prints them (`"%s %5d %5d %c %-8s: %s"`, time as
    /// `MM-DD HH:MM:SS.mmm`), so grep and other tools read it. There is no uid column, because Android Studio's
    /// THREADTIME pattern has none. Each line ends with `\n`.
    public static func format(_ entry: LogEntry, timeZone: TimeZone = .current) -> String {
        var prefix = LogcatTime.formatMonthDay(entry.timestamp, timeZone: timeZone)
        prefix += " "
        prefix += padded(entry.pid, to: 5)
        prefix += " "
        prefix += padded(entry.tid, to: 5)
        prefix += " "
        prefix += entry.level.letter
        prefix += " "
        prefix += entry.tag
        // logcat pads by bytes, and so does this, which keeps the columns of ASCII tags aligned.
        let missing = 8 - entry.tag.utf8.count
        if missing > 0 { prefix += String(repeating: " ", count: missing) }
        prefix += ": "

        var output = ""
        output.reserveCapacity(entry.message.utf8.count + prefix.utf8.count + 16)
        // An empty message still prints its line, as logcat does.
        for line in entry.message.split(separator: "\n", omittingEmptySubsequences: false) {
            output += prefix
            output += line
            output += "\n"
        }
        return output
    }

    private static func padded(_ value: Int32, to width: Int) -> String {
        let text = String(value)
        return text.utf8.count >= width ? text : String(repeating: " ", count: width - text.utf8.count) + text
    }
}

/// A line as the table shows it, the same fields Copy uses: time with date, PID-TID, tag, the Package column (process
/// name, `pid-N` while unknown), level and message, joined by single spaces with empty fields left out. Markers are
/// `--------- <text>`, as in logcat. Multi-line messages keep their newlines.
public enum LogPlainTextFormat {
    public static func line(for entry: LogEntry, processName: String?, timeZone: TimeZone = .current) -> String {
        if entry.kind == .marker { return "--------- \(entry.message)" }
        let package = processName ?? (entry.pid > 0 ? "pid-\(entry.pid)" : "")
        var line = LogcatTime.format(entry.timestamp, includeDate: true, timeZone: timeZone)
        line += " \(entry.pid)-\(entry.tid)"
        if !entry.tag.isEmpty { line += " " + entry.tag }
        if !package.isEmpty { line += " " + package }
        line += " " + entry.level.letter
        if !entry.message.isEmpty { line += " " + entry.message }
        return line
    }
}
