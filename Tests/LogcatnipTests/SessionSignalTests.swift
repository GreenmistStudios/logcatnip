import AppKit
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
    @Test func navigationRevealsFatalRowsAndErrorsAndFollowsTheFilter() async throws {
        let session = LogSession(source: .file(URL(fileURLWithPath: "/tmp/signals.logcat")), adb: nil, model: AppModel())
        let table = FakeTable()
        session.find.table = table
        session.show(Self.entries)
        #expect(session.hasCrashTargets)
        #expect(session.hasErrorTargets)
        #expect(session.errorRows.rows == [1, 6])
        #expect(session.fatalAnchorIDs == Set(session.signals.occurrences.filter { $0.kind.isFatal }.flatMap(\.anchorEntryIDs)))
        #expect(session.isFatalAnchor(1))
        #expect(!session.isFatalAnchor(2))

        session.navigateSignal(.next, kinds: SignalKind.fatal)
        #expect(table.revealed == [1])
        table.anchor = .selection(1...1)
        session.navigateSignal(.next, kinds: SignalKind.fatal)
        table.anchor = .selection(6...6)
        session.navigateSignal(.next, kinds: SignalKind.fatal)
        session.navigateSignal(.previous, kinds: SignalKind.fatal)
        #expect(table.revealed == [1, 6, 1, 1])
        session.navigateSignal(.next, kinds: [.performance])
        #expect(table.revealed.last == 5)
        table.anchor = .viewport(2...5)
        session.navigateError(.next)
        session.navigateError(.previous)
        #expect(table.revealed.suffix(2) == [6, 1])

        let rowsBefore = session.rows.count
        session.filterQuery = "pid:200"
        session.applyFilterNow()
        let deadline = ContinuousClock.now + .seconds(5)
        while session.rows.count == rowsBefore, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        // The filter stays put: only the second crash is left to visit.
        #expect(session.errorRows.rows == [0])
        table.anchor = .none
        session.navigateSignal(.next, kinds: SignalKind.fatal)
        #expect(table.revealed.last == 0)
        #expect(session.filterQuery == "pid:200")
        let hidden = try #require(session.signals.occurrences.first)
        let count = table.revealed.count
        session.revealOccurrence(id: hidden.id)
        #expect(table.revealed.count == count)

        session.filterQuery = "tag:App"
        session.applyFilterNow()
        while session.hasCrashTargets, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!session.hasCrashTargets)
        #expect(!session.hasErrorTargets)
    }

    /// `level:ERROR` hides InputDispatcher's and WindowManager's reports of the ANR, but ActivityManager's
    /// still shows it: visible, navigable and tinted on that row.
    @Test func anrStaysVisibleThroughItsActivityManagerReport() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("LogcatKitTests/Fixtures/anr.logcat")
        let entries = LogFileImporter.parse(try String(contentsOf: url, encoding: .utf8))
        let session = LogSession(source: .file(url), adb: nil, model: AppModel())
        let table = FakeTable()
        session.find.table = table
        session.show(entries)
        let anr = try #require(session.signals.occurrences.first)
        #expect(session.signals.occurrences.count == 1)
        #expect(anr.anchorEntryIDs.count == 3)
        // A tick per report, but one stop per occurrence.
        #expect(session.fatalAnchorRows.count == 3)
        #expect(session.visibleSignalRows(kinds: SignalKind.fatal).count == 1)

        try await refilter(session, "level:ERROR")
        let row = try #require(session.visibleRow(ofOccurrence: anr.id))
        let entry = try #require(session.entry(for: session.rows[row]))
        #expect(entry.tag == "ActivityManager")
        #expect(entry.message.hasPrefix("ANR in "))
        #expect(session.occurrenceIsVisible(anr))
        #expect(session.isFatalAnchor(entry.id))
        #expect(session.hasCrashTargets)
        #expect(session.visibleSignalRows(kinds: SignalKind.fatal) == [row])
        session.navigateSignal(.next, kinds: SignalKind.fatal)
        session.revealOccurrence(id: anr.id)
        #expect(table.revealed == [row, row])
    }

    /// The anchor sets and rows kept from index changes match a recompute from scratch through appends, an
    /// anchor joining an occurrence whose row is already shown, refilters, and a front trim that promotes a
    /// later anchor of the burst.
    @Test func anchorRowsMatchARecomputeFromScratch() async throws {
        let defaults = UserDefaults.standard
        let savedLimit = defaults.object(forKey: SettingsKey.maxEntries)
        defaults.set(10_000, forKey: SettingsKey.maxEntries)
        defer { defaults.set(savedLimit, forKey: SettingsKey.maxEntries) }

        let session = LogSession(source: .file(URL(fileURLWithPath: "/tmp/anchors.logcat")), adb: nil, model: AppModel())
        let window = "4f2b1c9 com.example.app/com.example.app.MainActivity (server)"
        func filler(_ count: Int, from time: Double) -> [LogEntry] {
            (0..<count).map { LogEntry(timestamp: time + Double($0) / 1000, pid: 7, tid: 7, level: .info, tag: "Feed", message: "item \($0)") }
        }
        let inputDispatcher = LogEntry(timestamp: 1000, pid: 1523, tid: 1688, level: .warn, tag: "InputDispatcher",
                                       message: "Window \(window) is unresponsive: \(window) is not responding. Waited 5001ms for MotionEvent")
        let windowManager = LogEntry(timestamp: 1000.1, pid: 1523, tid: 1722, level: .info, tag: "WindowManager",
                                     message: "ANR in Window{4f2b1c9 u0 com.example.app/com.example.app.MainActivity}. Reason:\(window) is not responding.")
        let activityManager = LogEntry(timestamp: 1005, pid: 1523, tid: 16251, level: .error, tag: "ActivityManager",
                                       message: "ANR in com.example.app (com.example.app/.MainActivity)\nPID: 16110\nReason: Input dispatching timed out")
        let crash = LogEntry(timestamp: 1006, pid: 16110, tid: 16110, level: .error, tag: "AndroidRuntime", message: Self.crash)
        let jank = LogEntry(timestamp: 1007, pid: 16110, tid: 16110, level: .info, tag: "Choreographer",
                            message: "Skipped 45 frames!  The application may be doing too much work on its main thread.")

        // Ids 0-4 filler, 5 InputDispatcher.
        session.show(filler(5, from: 990) + [inputDispatcher])
        try check(session)
        // Id 6 joins the ANR after its first row was shown.
        session.show([windowManager])
        #expect(session.signals.occurrences.map(\.anchorEntryIDs) == [[5, 6]])
        try check(session)
        // Ids 7-1106 filler, 1107 ActivityManager, 1108 the crash, 1109 jank.
        session.show(filler(1100, from: 1001) + [activityManager, crash, jank])
        #expect(session.signals.occurrences.first?.anchorEntryIDs == [5, 6, 1107])
        try check(session)

        try await refilter(session, "level:ERROR")
        try check(session)
        let anrRow = try #require(session.visibleRow(ofOccurrence: 5))
        #expect(session.rows[anrRow].entryID == 1107)
        try await refilter(session, "")
        try check(session)

        // 10,010 entries: the trim keeps the newest 9,000, ids 1010 on. InputDispatcher's and WindowManager's
        // reports go, so ActivityManager's stands for the ANR.
        session.show(filler(8900, from: 1010))
        #expect(session.firstEntryID == 1010)
        #expect(session.signals.occurrences.map(\.id).prefix(1) == [1107])
        #expect(session.signals.occurrences.first?.anchorEntryIDs == [1107])
        #expect(!session.fatalAnchorIDs.contains(5))
        try check(session)
        try await refilter(session, "level:ERROR")
        try check(session)
        #expect(session.visibleSignalRows(kinds: SignalKind.fatal).count == 2)
        #expect(session.visibleSignalRows(kinds: SignalKind.warnings).isEmpty)
        try await refilter(session, "-tag:ActivityManager")
        try check(session)
        #expect(!session.occurrenceIsVisible(id: 1107))
    }

    /// Recomputes every anchor row from the occurrences and the rows, and compares.
    private func check(_ session: LogSession, sourceLocation: SourceLocation = #_sourceLocation) throws {
        var rowOf: [Int: Int] = [:]
        for (index, row) in session.rows.enumerated() where row.line == 0 {
            rowOf[row.entryID] = index
        }
        let occurrences = session.signals.occurrences
        let fatal = occurrences.filter(\.kind.isFatal)
        let warnings = occurrences.filter { !$0.kind.isFatal }
        #expect(session.fatalAnchorIDs == Set(fatal.flatMap(\.anchorEntryIDs)), sourceLocation: sourceLocation)
        #expect(session.warningAnchorIDs == Set(warnings.flatMap(\.anchorEntryIDs)), sourceLocation: sourceLocation)
        #expect(session.fatalAnchorRows.rows == fatal.flatMap(\.anchorEntryIDs).compactMap { rowOf[$0] }.sorted(),
                sourceLocation: sourceLocation)
        #expect(session.warningAnchorRows.rows == warnings.flatMap(\.anchorEntryIDs).compactMap { rowOf[$0] }.sorted(),
                sourceLocation: sourceLocation)
        func firstRows(_ occurrences: [SignalOccurrence]) -> [Int] {
            occurrences.compactMap { $0.anchorEntryIDs.lazy.compactMap { rowOf[$0] }.first }.sorted()
        }
        #expect(session.visibleSignalRows(kinds: SignalKind.fatal) == firstRows(fatal), sourceLocation: sourceLocation)
        #expect(session.visibleSignalRows(kinds: SignalKind.warnings) == firstRows(warnings), sourceLocation: sourceLocation)
        #expect(session.visibleSignalRows(kinds: Set(SignalKind.allCases)) == firstRows(occurrences), sourceLocation: sourceLocation)
        for occurrence in occurrences {
            #expect(session.visibleRow(ofOccurrence: occurrence.id) == firstRows([occurrence]).first, sourceLocation: sourceLocation)
        }
        #expect(session.hasCrashTargets == !firstRows(fatal).isEmpty, sourceLocation: sourceLocation)
    }

    private func refilter(_ session: LogSession, _ query: String) async throws {
        let generation = session.visibilityGeneration
        session.filterQuery = query
        session.applyFilterNow()
        let deadline = ContinuousClock.now + .seconds(5)
        while session.visibilityGeneration == generation {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for the refilter")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class FakeTable: FindTableNavigating {
    var anchor = FindAnchor.none
    var revealed: [Int] = []

    var findAnchor: FindAnchor { anchor }
    var selectedRowIndexes: IndexSet { IndexSet() }
    func revealFindMatch(row: Int, highlight: NSRange?) { revealed.append(row) }
    func focusTable() {}
}
