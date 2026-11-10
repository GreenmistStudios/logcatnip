import Foundation
import Testing
@testable import LogcatKit

private let utc = TimeZone(identifier: "UTC")!
/// 2026-11-09 18:15:32.663 UTC.
private let t = 1_794_248_132.663

@Suite struct TimestampStyleTests {
    @Test func dateTime() {
        #expect(LogcatTime.format(t, style: .dateTime, timeZone: utc) == "2026-11-09 18:15:32.663")
    }

    @Test func time() {
        #expect(LogcatTime.format(t, style: .time, timeZone: utc) == "18:15:32.663")
    }

    @Test func localZone() {
        let newYork = TimeZone(identifier: "America/New_York")!
        #expect(LogcatTime.format(t, style: .time, timeZone: newYork) == "13:15:32.663")
        #expect(LogcatTime.format(t, style: .dateTime, timeZone: newYork) == "2026-11-09 13:15:32.663")
    }

    @Test func epoch() {
        #expect(LogcatTime.format(t, style: .epoch, timeZone: utc) == "1794248132.663")
    }

    @Test func epochRounds() {
        #expect(LogcatTime.format(1_794_248_132.9996, style: .epoch) == "1794248133.000")
        #expect(LogcatTime.format(1_794_248_132.0004, style: .epoch) == "1794248132.000")
    }

    @Test func zoneIgnoredByRelativeStyles() {
        let newYork = TimeZone(identifier: "America/New_York")!
        #expect(LogcatTime.format(t, style: .epoch, timeZone: newYork) == "1794248132.663")
        #expect(LogcatTime.format(t, style: .sinceStart, timeZone: newYork, sessionStart: t - 1) == "+1.000s")
    }

    @Test func sinceStart() {
        #expect(LogcatTime.format(1012.345, style: .sinceStart, sessionStart: 1000) == "+12.345s")
        #expect(LogcatTime.format(1000, style: .sinceStart, sessionStart: 1000) == "+0.000s")
        #expect(LogcatTime.format(1000 + 3725.12, style: .sinceStart, sessionStart: 1000) == "+3725.120s")
        #expect(LogcatTime.format(1000 - 0.004, style: .sinceStart, sessionStart: 1000) == "-0.004s")
        #expect(LogcatTime.format(t, style: .sinceStart, sessionStart: nil) == "+0.000s")
    }

    @Test func sinceStartKeepsMillisecondsAtEpochScale() {
        // 0.663 - 0.660 is not exactly 0.003 in floating point; whole milliseconds are.
        #expect(LogcatTime.format(t, style: .sinceStart, sessionStart: 1_794_248_132.660) == "+0.003s")
    }

    @Test func delta() {
        #expect(LogcatTime.format(t, style: .delta, previous: nil) == "Δ —")
        #expect(LogcatTime.format(t, style: .delta, previous: 1_794_248_132.660) == "Δ 3 ms")
        #expect(LogcatTime.format(t, style: .delta, previous: t) == "Δ 0 ms")
        #expect(LogcatTime.format(t, style: .delta, previous: t - 1.234) == "Δ 1.234 s")
        #expect(LogcatTime.format(t, style: .delta, previous: t + 0.002) == "Δ -2 ms")
        #expect(LogcatTime.format(t, style: .delta, previous: t - 0.999) == "Δ 999 ms")
        #expect(LogcatTime.format(t, style: .delta, previous: t - 1.000) == "Δ 1.000 s")
        #expect(LogcatTime.format(t, style: .delta, previous: t + 1.5) == "Δ -1.500 s")
    }

    @Test func sampleCellsFit() {
        let widest: [TimestampStyle: String] = [
            .dateTime: "2026-11-09 18:15:32.663",
            .time: "18:15:32.663",
            .epoch: "1794248132.663",
            .sinceStart: "+99999.999s",
            .delta: "Δ 99999.999 s",
        ]
        for style in TimestampStyle.allCases {
            let sample = try! #require(widest[style])
            #expect(MessageLines.cells(sample) <= style.sampleCells, "\(style)")
        }
        // Android's default pid_max is 32768, and a six-digit pid still fits.
        #expect(PidStyle.pid.sampleCells >= "123456".count)
        #expect(PidStyle.pidTid.sampleCells >= "32768-32768".count)
    }
}
