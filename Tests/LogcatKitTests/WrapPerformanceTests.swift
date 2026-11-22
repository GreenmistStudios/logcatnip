import Foundation
import Testing
@testable import LogcatKit

/// Timings for the span work behind a 500,000-row table. Run with
/// `LOGCATNIP_PERF_TESTS=1 swift test --filter WrapPerformance`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LOGCATNIP_PERF_TESTS"] == "1"))
struct WrapPerformanceTests {
    /// 450,000 messages that make 540,000 lines: mostly short ASCII, 5% 2,000-character lines, 5% CJK and
    /// emoji, 10% tab-indented traces.
    private static func messages() -> [String] {
        var messages: [String] = []
        messages.reserveCapacity(450_000)
        let filler = String(repeating: "abcdefghij", count: 20)
        for index in 0..<450_000 {
            switch index % 20 {
            case 0:
                messages.append("long-\(index) " + String(repeating: "x", count: 2000))
            case 1:
                messages.append("日本語のログ \(index) 😀 " + String(repeating: "漢字", count: 60))
            case 2, 3:
                messages.append("java.lang.IllegalStateException \(index)\n\tat com.example.Foo.bar(Foo.kt:\(index % 300))\n\tat com.example.Baz.qux(Baz.kt:12)")
            default:
                messages.append("request \(index) took \(index % 900) ms " + filler.prefix(40 + index % 160))
            }
        }
        return messages
    }

    private func time<T>(_ label: String, _ body: () -> T) -> (T, Duration) {
        let clock = ContinuousClock()
        var value: T?
        let duration = clock.measure { value = body() }
        print("[perf] \(label): \(duration)")
        return (value!, duration)
    }

    @Test func spansFor500kRows() {
        let messages = Self.messages()
        let (lines, duration) = time("spans for \(messages.count) messages") { () -> Int in
            var count = 0
            var widest = 0
            for message in messages {
                MessageLines.forEach(in: message) { line in
                    count += 1
                    widest = max(widest, Int(line.cells))
                }
            }
            return count
        }
        #expect(lines >= 500_000)
        // Generous: a debug build runs this loop about two orders of magnitude slower than a release build.
        #expect(duration < .seconds(30))
    }

    @Test func wrappedCountsFor500kRows() {
        var spans: [MessageLine] = []
        for message in Self.messages() {
            MessageLines.forEach(in: message) { spans.append($0) }
        }
        let (total, duration) = time("wrappedLineCount for \(spans.count) rows") {
            spans.reduce(0) { $0 + $1.wrappedLineCount(columns: 120) }
        }
        #expect(total >= spans.count)
        #expect(duration < .seconds(1))
    }
}
