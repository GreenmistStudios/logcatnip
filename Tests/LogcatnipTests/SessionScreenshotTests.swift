import AppKit
import Foundation
import LogcatKit
import SwiftUI
import Testing
@testable import Logcatnip

/// Screenshots of the session view: filter bar, log table and status bar. See `Snapshot` for how
/// references are recorded and compared.
@MainActor
@Suite(.serialized)
struct SessionScreenshotTests {
    private let size = CGSize(width: 1000, height: 340)

    init() {
        // The table autosaves column widths and visibility; start every test from the defaults.
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasSuffix("LogTable") {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func session(appearance: NSAppearance.Name) async throws {
        let session = makeSession()
        try await Snapshot.assertSnapshot(
            of: content(session),
            named: appearance == .aqua ? "session-light" : "session-dark",
            size: size,
            appearance: appearance
        )
    }

    @Test func wrappedLines() async throws {
        let session = makeSession()
        try await Snapshot.assertSnapshot(
            of: content(session, wrapLines: true),
            named: "session-wrapped",
            // Tall enough not to scroll: rows under the header would show through, because its blur
            // material is not captured.
            size: CGSize(width: 820, height: 480)
        )
    }

    @Test func dateAndLargerFont() async throws {
        let session = makeSession()
        try await Snapshot.assertSnapshot(
            of: content(session, fontSize: 14, showDate: true),
            named: "session-date-14pt",
            size: CGSize(width: 1000, height: 400)
        )
    }

    @Test func filtered() async throws {
        let session = makeSession()
        session.filterQuery = "level:WARN"
        session.applyFilterNow()
        // Warn, error and assert entries, plus the marker, which passes every filter.
        try await waitUntil { session.visibleCount == 4 }
        try await Snapshot.assertSnapshot(of: content(session), named: "session-filtered", size: size)
    }

    @Test func invalidFilter() async throws {
        let session = makeSession()
        session.filterQuery = "tag:Net & (level:WARN"
        session.applyFilterNow()
        #expect(session.filterError != nil)
        try await Snapshot.assertSnapshot(of: content(session), named: "session-filter-error", size: size)
    }

    @Test func pausedLiveSession() async throws {
        let session = makeSession(status: .streaming)
        session.isPaused = true
        try await Snapshot.assertSnapshot(of: content(session), named: "session-paused", size: size)
    }

    // MARK: Helpers

    private func content(
        _ session: LogSession,
        fontSize: Double = 12,
        showDate: Bool = false,
        wrapLines: Bool = false
    ) -> some View {
        SessionContent(session: session, fontSize: fontSize, showDate: showDate, wrapLines: wrapLines)
    }

    private func makeSession(status: LogSession.Status = .loaded) -> LogSession {
        let session = LogSession(source: .file(URL(fileURLWithPath: "/tmp/sample.logcat.txt")), adb: nil, model: AppModel())
        session.show(Fixtures.entries, status: status)
        return session
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for the session to update")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// A short log covering each level, a stack trace, a marker, an unknown process and a long line.
enum Fixtures {
    /// Built in the local time zone so the rendered times are the same on every machine.
    static func time(_ hour: Int, _ minute: Int, _ second: Int, _ millis: Int) -> Double {
        let components = DateComponents(year: 2026, month: 11, day: 10, hour: hour, minute: minute, second: second)
        let date = Calendar(identifier: .gregorian).date(from: components)!
        return date.timeIntervalSince1970 + Double(millis) / 1000
    }

    static let app = "com.example.catnip"

    static let entries: [LogEntry] = [
        LogEntry(timestamp: time(9, 41, 0, 12), pid: 1234, tid: 1234, level: .verbose, tag: "Choreographer",
                 message: "Frame time 16.6 ms", processName: app),
        LogEntry(timestamp: time(9, 41, 0, 105), pid: 1234, tid: 1251, level: .debug, tag: "OkHttp",
                 message: "--> GET https://api.example.com/v1/cats?page=2", processName: app),
        LogEntry(timestamp: time(9, 41, 0, 230), pid: 1234, tid: 1234, level: .info, tag: "ActivityManager",
                 message: "Displayed com.example.catnip/.MainActivity: +412ms", processName: app),
        LogEntry(timestamp: time(9, 41, 1, 7), pid: 812, tid: 840, level: .warn, tag: "PackageManager",
                 message: "Not granting permission android.permission.POST_NOTIFICATIONS", processName: "system_server"),
        LogEntry(timestamp: time(9, 41, 1, 500), pid: 4321, tid: 4321, level: .info, tag: "Zygote",
                 message: "Process 4321 started"),
        LogEntry(timestamp: time(9, 41, 2, 333), pid: 1234, tid: 1251, level: .debug, tag: "CatRepository",
                 message: "Loaded 24 cats from cache in 3 ms; refreshing from the network because the cache is older than 15 minutes and the user pulled to refresh",
                 processName: app),
        LogEntry(timestamp: time(9, 41, 3, 900), pid: 1234, tid: 1234, level: .error, tag: "AndroidRuntime",
                 message: """
                 FATAL EXCEPTION: main
                 java.lang.IllegalStateException: Bowl is empty
                 \tat com.example.catnip.Bowl.serve(Bowl.kt:42)
                 \tat com.example.catnip.MainActivity.onCreate(MainActivity.kt:18)
                 """,
                 processName: app),
        LogEntry.marker("Device disconnected", at: time(9, 41, 4, 0)),
        LogEntry(timestamp: time(9, 41, 9, 450), pid: 1, tid: 1, level: .assert, tag: "init",
                 message: "Reboot requested", processName: "init"),
    ]
}
