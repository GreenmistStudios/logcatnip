import Foundation
import LogcatKit
import Testing
@testable import Logcatnip

@MainActor
@Suite struct SessionSignalTests {
    private static let crash = """
        FATAL EXCEPTION: main
        Process: com.example.app, PID: 100
        java.lang.IllegalStateException: boom
        \tat com.example.app.MainActivity.onCreate(MainActivity.kt:42)
        """

    private static let entries: [LogEntry] = [
        LogEntry(timestamp: 100, pid: 100, tid: 100, level: .info, tag: "App", message: "start"),
        LogEntry(timestamp: 101, pid: 100, tid: 100, level: .error, tag: "AndroidRuntime", message: crash),
        LogEntry(timestamp: 102, pid: 100, tid: 100, level: .info, tag: "Choreographer",
                 message: "Skipped 45 frames!  The application may be doing too much work on its main thread."),
        LogEntry(timestamp: 120, pid: 200, tid: 200, level: .error, tag: "AndroidRuntime", message: crash),
    ]

    @Test func summaryAndVisibleRowsFollowTheFilter() async throws {
        let session = LogSession(source: .file(URL(fileURLWithPath: "/tmp/signals.logcat")), adb: nil, model: AppModel())
        session.show(Self.entries)
        #expect(session.signalSummary.count(of: .crash) == 2)
        #expect(session.signalSummary.count(of: .performance) == 1)
        #expect(session.signalSummary.fatalCount == 2)
        #expect(session.signalSummary.groups.map(\.count).sorted() == [1, 2])
        // Rows: start, 4 crash lines, skipped frames, 4 crash lines.
        #expect(session.visibleSignalRows(kinds: [.crash]) == [1, 6])
        #expect(session.visibleSignalRows(kinds: [.crash, .performance]) == [1, 5, 6])

        let rowsBefore = session.rows.count
        session.filterQuery = "pid:200"
        session.applyFilterNow()
        let deadline = ContinuousClock.now + .seconds(5)
        while session.rows.count == rowsBefore, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        // The filter hides the first crash but the index, keyed by entries, still has it.
        #expect(session.visibleSignalRows(kinds: [.crash]) == [0])
        #expect(session.signalSummary.count(of: .crash) == 2)
        let first = try #require(session.signals.occurrences.first)
        #expect(!session.occurrenceIsVisible(first))
        #expect(session.signals.occurrences.last.map(session.occurrenceIsVisible) == true)

        session.clear()
        #expect(session.signalSummary.isEmpty)
        #expect(session.visibleSignalRows(kinds: Set(SignalKind.allCases)).isEmpty)
    }
}
