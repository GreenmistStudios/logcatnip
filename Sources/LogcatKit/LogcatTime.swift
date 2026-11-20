import Foundation

/// Timestamp helpers for the formats logcat prints.
public enum LogcatTime {
    /// Parses `sssss.mmm` (from `-v epoch`).
    public static func parseEpoch<S: StringProtocol>(_ text: S) -> Double? {
        Double(text)
    }

    /// Parses `MM-DD` or `YYYY-MM-DD` plus `HH:MM:SS.mmm` into seconds since 1970, in `timeZone`.
    ///
    /// Threadtime and legacy long lines carry no year. It comes from `referenceDate`, the file's modification
    /// date for an import or now for a live stream: a log can't be written after it was saved, so a time more
    /// than a day after the reference belongs to the year before. The day of slack absorbs clock and time zone
    /// differences between the device and the Mac. A year in the text (`-v year`) is used as is.
    public static func parse<S: StringProtocol>(
        date: S, time: S, timeZone: TimeZone = .current, referenceDate: Date = Date()
    ) -> Double? {
        let dateParts = date.split(separator: "-")
        let explicitYear: Int?
        let month: Int
        let day: Int
        switch dateParts.count {
        case 2:
            guard let m = Int(dateParts[0]), let d = Int(dateParts[1]) else { return nil }
            explicitYear = nil
            month = m
            day = d
        case 3:
            guard let y = Int(dateParts[0]), let m = Int(dateParts[1]), let d = Int(dateParts[2]) else { return nil }
            explicitYear = y
            month = m
            day = d
        default:
            return nil
        }
        let timeParts = time.split(separator: ":")
        guard timeParts.count == 3,
              let hour = Int(timeParts[0]),
              let minute = Int(timeParts[1]),
              let seconds = Double(timeParts[2])
        else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func epoch(year: Int) -> Double? {
            let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
            return calendar.date(from: components).map { $0.timeIntervalSince1970 + seconds }
        }

        if let explicitYear { return epoch(year: explicitYear) }
        let referenceYear = calendar.component(.year, from: referenceDate)
        guard let result = epoch(year: referenceYear) else { return nil }
        // Feb 29 needs no special case: in a common year it normalizes to Mar 1, which lands past the reference
        // and falls back to the previous year, a leap year when the log really has a Feb 29.
        if result > referenceDate.timeIntervalSince1970 + 86_400 {
            return epoch(year: referenceYear - 1) ?? result
        }
        return result
    }

    /// Whole milliseconds, rounded. Every printed time goes through this, so the table, Copy and Export agree
    /// even when the stored double sits just below a millisecond (1794248132.663 is stored as ...132.66299).
    public static func milliseconds(_ timestamp: Double) -> Int64 {
        Int64((timestamp * 1000).rounded())
    }

    /// Formats a timestamp the way Android Studio's logcat does by default: `yyyy-MM-dd HH:mm:ss.SSS`.
    public static func format(_ timestamp: Double, includeDate: Bool = true, timeZone: TimeZone = .current) -> String {
        let (seconds, millis) = split(milliseconds(timestamp))
        let date = Date(timeIntervalSince1970: Double(seconds))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let time = String(
            format: "%02d:%02d:%02d.%03d",
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0, millis
        )
        guard includeDate else { return time }
        return String(format: "%04d-%02d-%02d ", c.year ?? 0, c.month ?? 0, c.day ?? 0) + time
    }

    /// `sssss.mmm`, the `-v epoch` form Export writes. It shares ``milliseconds(_:)`` with ``format(_:includeDate:timeZone:)``
    /// rather than using `%.3f`, so a time reads the same in the table and in an exported file.
    public static func formatEpoch(_ timestamp: Double) -> String {
        let (seconds, millis) = split(milliseconds(timestamp))
        return "\(seconds)." + String(format: "%03d", millis)
    }

    /// Floored split, so a negative count still has milliseconds in 0...999. Logcat never prints one.
    private static func split(_ milliseconds: Int64) -> (seconds: Int64, millis: Int) {
        let seconds = milliseconds >= 0 ? milliseconds / 1000 : (milliseconds - 999) / 1000
        return (seconds, Int(milliseconds - seconds * 1000))
    }

    /// `MM-DD HH:MM:SS.mmm`, the only `-T` form pre-Nougat logcat accepts.
    public static func formatMonthDay(_ timestamp: Double, timeZone: TimeZone = .current) -> String {
        String(format(timestamp, includeDate: true, timeZone: timeZone).dropFirst(5))
    }
}
