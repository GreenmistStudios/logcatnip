import Foundation
import Testing
@testable import LogcatKit

@Suite("logcat arguments")
struct LogcatArgumentsTests {
    @Test func modernFormatSupportedByApiLevel() {
        #expect(ADB.LogcatOptions.modernFormatSupported(apiLevel: nil))
        #expect(!ADB.LogcatOptions.modernFormatSupported(apiLevel: 23))
        #expect(ADB.LogcatOptions.modernFormatSupported(apiLevel: 24))
        #expect(ADB.LogcatOptions.modernFormatSupported(apiLevel: 37))
    }

    @Test func modernArgumentsUseEpochTail() {
        let arguments = ADB.logcatArguments(serial: "s", options: .init(since: 1794248132.663))
        #expect(arguments == ["-s", "s", "logcat", "-v", "long", "-v", "epoch", "-v", "uid", "-T", "1794248132.663"])
    }

    @Test func legacyTailTimeUsesMonthDayForm() throws {
        let tz = try #require(TimeZone(identifier: "America/New_York"))
        let t = try #require(LogcatTime.parse(date: "11-10", time: "14:03:07.123", timeZone: tz))
        let arguments = ADB.logcatArguments(
            serial: "s", options: .init(buffers: ["main"], since: t, modernFormat: false), timeZone: tz
        )
        #expect(arguments == ["-s", "s", "logcat", "-v", "long", "-b", "main", "-T", "11-10 14:03:07.123"])
    }

    @Test func monthDayFormatRoundTrips() throws {
        let tz = try #require(TimeZone(identifier: "America/New_York"))
        let t = try #require(LogcatTime.parse(date: "11-10", time: "14:03:07.123", timeZone: tz))
        #expect(LogcatTime.formatMonthDay(t, timeZone: tz) == "11-10 14:03:07.123")

        // Rounding: .9995 s must carry into the next second rather than print .1000.
        let late = try #require(LogcatTime.parse(date: "11-10", time: "14:03:07.999", timeZone: tz))
        #expect(LogcatTime.formatMonthDay(late, timeZone: tz) == "11-10 14:03:07.999")
        #expect(LogcatTime.formatMonthDay(late + 0.0004, timeZone: tz) == "11-10 14:03:07.999")
        #expect(LogcatTime.formatMonthDay(late + 0.0006, timeZone: tz) == "11-10 14:03:08.000")

        let utc = try #require(TimeZone(identifier: "UTC"))
        let u = try #require(LogcatTime.parse(date: "11-10", time: "14:03:07.123", timeZone: utc))
        #expect(LogcatTime.formatMonthDay(u, timeZone: utc) == "11-10 14:03:07.123")
    }
}
