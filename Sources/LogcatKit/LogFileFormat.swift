import Foundation

/// The kinds of log file Logcatnip opens. Detection mirrors Android Studio's `LogcatFileIo.getLogcatFileType`
/// (zips by extension, everything else by sniffing the first lines), plus `-v long`, `-v time` and `-v brief`.
public enum LogFileFormat: String, Sendable, Equatable {
    /// Android Studio's Save Logcat file: JSON with metadata and messages.
    case logcatJSON
    /// `logcat -v long`, what Logcatnip's Export wrote before `.logcat`.
    case long
    /// `logcat -v threadtime`, optionally with `-v uid`, `-v year` or `-v epoch`.
    case threadtime
    /// The text of a bug report (`dumpstate`).
    case bugreport
    /// `adb bugreport` output: a zip with the bug report text inside.
    case bugreportZip
    /// `L/Tag(pid): message` lines: `-v brief`, `-v time` and Firebase Crashlytics logs.
    case brief

    /// How much of a file ``detect(prefix:pathExtension:)`` needs. Android Studio reads one line; a few lines of
    /// even a long-lined file fit comfortably.
    public static let sniffLength = 64 * 1024

    /// Detection looks at this many non-blank lines. Android Studio checks only the first, but a banner or a
    /// stray header line before the first record is common in files that were pasted or trimmed by hand, and the
    /// importer this replaces looked at 20.
    private static let linesExamined = 10

    /// Looks at the first lines in `prefix`, which should be the first ``sniffLength`` bytes of the file.
    public static func detect(prefix: Data, pathExtension: String) -> LogFileFormat? {
        if pathExtension.lowercased() == "zip" || prefix.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            return .bugreportZip
        }
        return detectText(prefix: prefix)
    }

    /// Detects text already in memory. A zip can't be text, so it never returns ``bugreportZip``.
    public static func detect(text: String) -> LogFileFormat? {
        detectText(prefix: Data(text.utf8.prefix(sniffLength)))
    }

    private static func detectText(prefix: Data) -> LogFileFormat? {
        var text = String(decoding: prefix, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        // A prefix cut in the middle of a line would show half a record as the last line.
        if prefix.count >= sniffLength, lines.count > 1 { lines.removeLast() }

        var examined = 0
        for var line in lines {
            if line.hasSuffix("\r") { line = line.dropLast() }
            if line.allSatisfy(\.isWhitespace) || line.hasPrefix("--------- ") { continue }
            if let format = detect(line: line) { return format }
            examined += 1
            if examined == linesExamined { break }
        }
        return nil
    }

    private static func detect(line: Substring) -> LogFileFormat? {
        if line.first(where: { !$0.isWhitespace }) == "{" { return .logcatJSON }
        // Android Studio's BUGREPORT_FILE is exactly 56 equals signs; allow for other dumpstate versions.
        if line.count >= 40, line.allSatisfy({ $0 == "=" }) { return .bugreport }
        if LogcatLongFormat.parseHeader(line) != nil { return .long }
        if LogcatThreadtimeFormat.parseLine(line) != nil { return .threadtime }
        if LogcatBriefFormat.parseLine(line) != nil { return .brief }
        return nil
    }
}
