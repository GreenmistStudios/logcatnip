import Foundation
import Testing
@testable import LogcatKit

private let utc = TimeZone(identifier: "UTC")!
private let t = 1_794_248_132.663

private func entry(
    id: Int = 0,
    tag: String = "MyTag",
    message: String = "hello",
    level: LogLevel = .info,
    pid: Int32 = 1234,
    tid: Int32 = 5678,
    process: String? = "com.example.app",
    timestamp: Double = t
) -> LogEntry {
    LogEntry(id: id, timestamp: timestamp, pid: pid, tid: tid, level: level, tag: tag, message: message, processName: process)
}

private func formatter(_ options: LogViewOptions) -> LogLineFormatter {
    LogLineFormatter(options: options, localTimeZone: utc)
}

private func cell(
    _ column: LogColumn, _ f: LogLineFormatter, _ entry: LogEntry, previous: LogEntry? = nil, start: Double? = nil
) -> String {
    f.text(column, for: entry, previous: previous, sessionStart: start, processName: { $0.processName })
}

private func hiding(tags: Bool = false, packages: Bool = false, processes: Bool = false) -> LogViewOptions {
    var options = LogViewOptions.standard
    options.setVisible(.process, true)
    options.hideRepeatedTags = tags
    options.hideRepeatedPackages = packages
    options.hideRepeatedProcesses = processes
    return options
}

@Suite struct LogLineFormatterTests {
    @Test func pidStyles() {
        var options = LogViewOptions.standard
        options.pidStyle = .pid
        #expect(cell(.pid, formatter(options), entry()) == "1234")
        options.pidStyle = .pidTid
        #expect(cell(.pid, formatter(options), entry()) == "1234-5678")
    }

    @Test func basicCells() {
        let f = formatter(.standard)
        let e = entry(level: .warn)
        #expect(cell(.time, f, e) == "2026-11-09 18:15:32.663")
        #expect(cell(.tag, f, e) == "MyTag")
        #expect(cell(.package, f, e) == "com.example.app")
        #expect(cell(.process, f, entry(process: "com.example.app:remote")) == "com.example.app:remote")
        #expect(cell(.package, f, entry(process: "com.example.app:remote")) == "com.example.app")
        #expect(cell(.level, f, e) == "W")
        #expect(cell(.message, f, entry(message: "a\nb")) == "a\nb")
    }

    @Test func timeZoneOption() {
        var options = LogViewOptions.standard
        options.timeZone = .utc
        let newYork = TimeZone(identifier: "America/New_York")!
        let f = LogLineFormatter(options: options, localTimeZone: newYork)
        #expect(cell(.time, f, entry()) == "2026-11-09 18:15:32.663")
        options.timeZone = .local
        #expect(cell(.time, LogLineFormatter(options: options, localTimeZone: newYork), entry()) == "2026-11-09 13:15:32.663")
    }

    @Test func hidesRepeatedTag() {
        let f = formatter(hiding(tags: true))
        let a = entry(tag: "X")
        #expect(cell(.tag, f, a, previous: entry(tag: "X")) == "")
        #expect(cell(.tag, f, a, previous: entry(tag: "Y")) == "X")
        #expect(cell(.tag, f, a, previous: nil) == "X")
        #expect(cell(.tag, formatter(hiding(tags: false)), a, previous: entry(tag: "X")) == "X")
        // An empty tag is nothing to hide.
        #expect(cell(.tag, f, entry(tag: ""), previous: entry(tag: "")) == "")
    }

    @Test func neverHidesAfterMarker() {
        let f = formatter(hiding(tags: true, packages: true, processes: true))
        let marker = LogEntry.marker("Device reconnected", at: t)
        let e = entry()
        #expect(cell(.tag, f, e, previous: marker) == "MyTag")
        #expect(cell(.package, f, e, previous: marker) == "com.example.app")
        #expect(cell(.process, f, e, previous: marker) == "com.example.app")
    }

    @Test func hidesRepeatedPackageByDisplayedText() {
        let f = formatter(hiding(packages: true, processes: true))
        let first = entry(process: "com.foo:remote")
        let second = entry(process: "com.foo")
        #expect(cell(.package, f, second, previous: first) == "")
        #expect(cell(.process, f, second, previous: first) == "com.foo")
        #expect(cell(.process, f, entry(process: "com.foo"), previous: second) == "")
    }

    @Test func unknownProcess() {
        let unknown = entry(pid: 12, process: nil)
        let f = formatter(hiding(packages: true))
        #expect(cell(.package, f, unknown) == "pid-12")
        #expect(cell(.process, f, unknown) == "")
        #expect(cell(.package, f, unknown, previous: entry(pid: 12, process: nil)) == "")
        #expect(cell(.package, f, entry(pid: 0, process: nil)) == "")
        #expect(LogLineFormatter.packageText(process: nil, pid: 12) == "pid-12")
        #expect(LogLineFormatter.packageText(process: nil, pid: 0) == "")
        #expect(LogLineFormatter.packageText(process: "com.x:y", pid: 5) == "com.x")
    }

    @Test func hideRepeatedAfterFiltering() throws {
        let entries = [entry(id: 0, tag: "X"), entry(id: 1, tag: "Y"), entry(id: 2, tag: "X")]
        let f = formatter(hiding(tags: true))
        func tags(visible: [LogEntry]) -> [String] {
            visible.enumerated().map { index, e in
                cell(.tag, f, e, previous: index > 0 ? visible[index - 1] : nil)
            }
        }
        #expect(tags(visible: entries) == ["X", "Y", "X"])
        let filter = try LogFilter("-tag=:Y")
        let context = FilterContext(now: t)
        let visible = entries.filter { filter.matches($0, context: context) }
        #expect(visible.count == 2)
        #expect(tags(visible: visible) == ["X", ""])
    }

    @Test func hideRepeatedAfterTrimming() {
        let f = formatter(hiding(tags: true))
        let a = entry(id: 0, tag: "X")
        let a2 = entry(id: 1, tag: "X")
        #expect(cell(.tag, f, a2, previous: a) == "")
        // The first row of a trimmed buffer has no row above it, so it shows its tag.
        #expect(cell(.tag, f, a2, previous: nil) == "X")
    }

    @Test func deltaUsesPreviousVisibleEntry() throws {
        let entries = [
            entry(id: 0, tag: "X", timestamp: 100.000),
            entry(id: 1, tag: "Y", timestamp: 100.100),
            entry(id: 2, tag: "X", timestamp: 100.250),
        ]
        var options = LogViewOptions.standard
        options.timestampStyle = .delta
        let f = formatter(options)
        let all = entries.enumerated().map { cell(.time, f, $1, previous: $0 > 0 ? entries[$0 - 1] : nil) }
        #expect(all == ["Δ —", "Δ 100 ms", "Δ 150 ms"])

        let filter = try LogFilter("tag:X")
        let context = FilterContext(now: 100)
        let visible = entries.filter { filter.matches($0, context: context) }
        #expect(cell(.time, f, visible[1], previous: visible[0]) == "Δ 250 ms")
    }

    @Test func sinceStartUsesSessionStart() {
        var options = LogViewOptions.standard
        options.timestampStyle = .sinceStart
        let f = formatter(options)
        #expect(cell(.time, f, entry(timestamp: 112.5), start: 100) == "+12.500s")
    }

    @Test func markersShowOnlyTimeAndMessage() {
        let f = formatter(.standard)
        let marker = LogEntry.marker("Device disconnected", at: t)
        #expect(cell(.time, f, marker) == "2026-11-09 18:15:32.663")
        for column in [LogColumn.pid, .tag, .package, .process] {
            #expect(cell(column, f, marker) == "", "\(column)")
        }
        #expect(cell(.message, f, marker) == "Device disconnected")
    }

    @Test func needsPrevious() {
        #expect(!formatter(.standard).needsPrevious(.tag))
        #expect(!formatter(.standard).needsPrevious(.time))
        #expect(formatter(hiding(tags: true)).needsPrevious(.tag))
        #expect(!formatter(hiding(tags: true)).needsPrevious(.package))
        var delta = LogViewOptions.standard
        delta.timestampStyle = .delta
        #expect(formatter(delta).needsPrevious(.time))
        #expect(!formatter(delta).needsPrevious(.tag))
    }

    // MARK: Copy

    private func copy(
        _ f: LogLineFormatter, _ e: LogEntry, previous: LogEntry? = nil, start: Double? = nil, columns: [LogColumn]
    ) -> String {
        f.copyLine(for: e, previous: previous, sessionStart: start, processName: { $0.processName }, columns: columns)
    }

    @Test func copyLineStandard() {
        let columns: [LogColumn] = [.time, .pid, .tag, .package, .level, .message]
        #expect(copy(formatter(.standard), entry(), columns: columns)
            == "2026-11-09 18:15:32.663 1234-5678 MyTag com.example.app I hello")
    }

    @Test func copyLineCompact() {
        #expect(copy(formatter(.compact), entry(), columns: [.time, .tag, .level, .message]) == "18:15:32.663 MyTag I hello")
    }

    @Test func copyLineFollowsColumnOrder() {
        #expect(copy(formatter(.standard), entry(), columns: [.message, .tag]) == "hello MyTag")
    }

    @Test func copyLineIgnoresHideRepeated() {
        let f = formatter(hiding(tags: true, packages: true))
        let previous = entry()
        #expect(copy(f, entry(), previous: previous, columns: [.tag, .package, .message]) == "MyTag com.example.app hello")
    }

    @Test func copyLineSkipsEmptyFields() {
        let f = formatter(hiding())
        let unknown = entry(pid: 12, process: nil)
        #expect(copy(f, unknown, columns: [.package, .process, .message]) == "pid-12 hello")
    }

    @Test func copyLineMultiLineMessage() {
        let e = entry(message: "a\n\tat b")
        #expect(copy(formatter(.compact), e, columns: [.tag, .message]) == "MyTag a\n\tat b")
    }

    @Test func copyLineMarker() {
        let marker = LogEntry.marker("Device disconnected", at: t)
        #expect(copy(formatter(.standard), marker, columns: [.time, .tag, .message]) == "--------- Device disconnected")
    }

    @Test func copyLineDelta() {
        var options = LogViewOptions.standard
        options.timestampStyle = .delta
        let previous = entry(timestamp: t - 0.003)
        #expect(copy(formatter(options), entry(), previous: previous, columns: [.time, .tag, .message]) == "Δ 3 ms MyTag hello")
    }
}
