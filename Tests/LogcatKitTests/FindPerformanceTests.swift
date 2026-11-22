import Foundation
import Testing
@testable import LogcatKit

/// Timings for a 500,000-row table. Run with `LOGCATNIP_PERF_TESTS=1 swift test --filter FindPerformance`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LOGCATNIP_PERF_TESTS"] == "1"))
struct FindPerformanceTests {
    private struct Table {
        var entries: [LogEntry] = []
        var rows: [(entryID: Int, line: Int32)] = []

        init(entryCount: Int) {
            entries.reserveCapacity(entryCount)
            rows.reserveCapacity(entryCount * 2)
            for id in 0..<entryCount {
                let message = "request \(id) took \(id % 900) ms\n  at com.example.Foo.bar(Foo.kt:\(id % 300))"
                entries.append(LogEntry(id: id, timestamp: 1_000_000, pid: 1, tid: 1, level: .info, tag: "Perf", message: message))
                rows.append((id, 0))
                rows.append((id, 1))
            }
        }

        func scan(_ finder: LogFinder) -> [Int] {
            finder.matchingRows(in: 0..<rows.count, row: { rows[$0] }, entry: { entries[$0] })
        }
    }

    private func time<T>(_ label: String, _ body: () -> T) -> (T, Duration) {
        let clock = ContinuousClock()
        var value: T?
        let duration = clock.measure { value = body() }
        print("[perf] \(label): \(duration)")
        return (value!, duration)
    }

    @Test func scan500kRows() throws {
        let table = Table(entryCount: 250_000)
        #expect(table.rows.count == 500_000)

        let plain = try LogFinder("foo")
        let (plainRows, plainTime) = time("plain 'foo' over 500k rows") { table.scan(plain) }
        #expect(plainRows.count == 250_000)
        #expect(plainTime < .seconds(10))

        let regex = try LogFinder(#"took 1\d\d ms"#, options: FindOptions(regex: true))
        let (regexRows, regexTime) = time("regex over 500k rows") { table.scan(regex) }
        #expect(!regexRows.isEmpty)
        #expect(regexTime < .seconds(10))
    }

    @Test func rangesOnALongLine() throws {
        let line = String(repeating: "abc foo defg ", count: 16)
        let finder = try LogFinder("foo")
        let (_, duration) = time("1,000 x ranges(in:) on \(line.utf16.count) chars") {
            (0..<1000).reduce(0) { total, _ in total + finder.ranges(in: line).count }
        }
        #expect(duration < .seconds(1))
    }

    @Test func markerLayoutForEveryOtherRow() {
        let rows = Array(stride(from: 0, to: 500_000, by: 2))
        let (runs, duration) = time("ScrollMarkerLayout.runs for 250k marked rows") {
            ScrollMarkerLayout.runs(rows: rows, rowCount: 500_000, trackLength: 1000)
        }
        #expect(!runs.isEmpty)
        #expect(duration < .milliseconds(10))
    }
}
