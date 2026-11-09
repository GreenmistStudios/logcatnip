import Foundation

/// Timestamp helpers for the formats logcat prints.
public enum LogcatTime {
    /// Parses `sssss.mmm` (from `-v epoch`).
    public static func parseEpoch<S: StringProtocol>(_ text: S) -> Double? {
        Double(text)
    }

    /// Parses `MM-DD` or `YYYY-MM-DD` plus `HH:MM:SS.mmm` into seconds since 1970, in the local time zone.
    /// When the year is missing, the current year is assumed.
    public static func parse<S: StringProtocol>(date: S, time: S, timeZone: TimeZone = .current) -> Double? {
        let dateParts = date.split(separator: "-")
        let year: Int
        let month: Int
        let day: Int
        switch dateParts.count {
        case 2:
            guard let m = Int(dateParts[0]), let d = Int(dateParts[1]) else { return nil }
            year = Calendar(identifier: .gregorian).component(.year, from: Date())
            month = m
            day = d
        case 3:
            guard let y = Int(dateParts[0]), let m = Int(dateParts[1]), let d = Int(dateParts[2]) else { return nil }
            year = y
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
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        guard let base = calendar.date(from: components) else { return nil }
        return base.timeIntervalSince1970 + seconds
    }

    /// Formats a timestamp the way Android Studio's logcat does by default: `yyyy-MM-dd HH:mm:ss.SSS`.
    public static func format(_ timestamp: Double, includeDate: Bool = true, timeZone: TimeZone = .current) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let millis = Int((timestamp - floor(timestamp)) * 1000)
        let time = String(
            format: "%02d:%02d:%02d.%03d",
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0, millis
        )
        guard includeDate else { return time }
        return String(format: "%04d-%02d-%02d ", c.year ?? 0, c.month ?? 0, c.day ?? 0) + time
    }
}
