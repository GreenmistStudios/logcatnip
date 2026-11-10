import Foundation
import Testing
@testable import LogcatKit

private let lane2 = "studio.greenmist.test.lane2"
private let lane2crash = "studio.greenmist.test.lane2crash"

private func logLine(
    pid: Int32,
    level: LogLevel = .info,
    tag: String,
    message: String,
    uid: String = "10234"
) -> LogEntry {
    LogEntry(timestamp: 1_000_000, uid: uid, pid: pid, tid: pid, level: level, tag: tag, message: message)
}

private func activityManager(_ message: String) -> LogEntry {
    logLine(pid: 608, tag: "ActivityManager", message: message, uid: "1000")
}

private func fatalException(pid: Int32) -> LogEntry {
    logLine(
        pid: pid, level: .error, tag: "AndroidRuntime",
        message: "FATAL EXCEPTION: main\nProcess: \(lane2crash), PID: \(pid)\njava.lang.RuntimeException: boom")
}

@Suite struct ProcessMarkerTrackerTests {
    private func tracked(_ package: String) -> Bool { package == "com.mine" }

    @Test func forceStopThenStartEmitsEndedThenStarted() {
        var tracker = ProcessMarkerTracker()
        let first = tracker.started(pid: 4758, process: lane2, uid: 10233, seq: 1)
        #expect(first.map(\.text) == ["PROCESS STARTED (4758) for package \(lane2)"])

        let ended = tracker.ended(pid: 4758, process: lane2, reason: .forceStopped, seq: 5)
        #expect(ended?.text == "PROCESS ENDED (4758) for package \(lane2) (force stopped)")

        let second = tracker.started(pid: 4803, process: lane2, uid: 10233, seq: 9)
        #expect(second.map(\.text) == ["PROCESS STARTED (4803) for package \(lane2)"])
    }

    @Test func crashEntryMarksEndAsCrashed() {
        var tracker = ProcessMarkerTracker()
        _ = tracker.started(pid: 25015, process: lane2crash, uid: 10234, seq: 1)
        tracker.note(fatalException(pid: 25015))
        let ended = tracker.ended(pid: 25015, process: lane2crash, reason: nil, seq: 4)
        #expect(ended?.marker == .ended(.crashed))
        #expect(ended?.text == "PROCESS ENDED (25015) for package \(lane2crash) (crashed)")
    }

    /// Real sequence: the app crashed (pid 25142), then a later `am force-stop` reported the leftover process.
    @Test func crashThenForceStopStaysCrashed() {
        var tracker = ProcessMarkerTracker()
        _ = tracker.started(pid: 25142, process: lane2crash, uid: 10234, seq: 1)
        tracker.note(fatalException(pid: 25142))
        let ended = tracker.ended(pid: 25142, process: lane2crash, reason: .forceStopped, seq: 8)
        #expect(ended?.marker == .ended(.crashed))
    }

    @Test func killReasonCrashIsCrashed() {
        var tracker = ProcessMarkerTracker()
        _ = tracker.started(pid: 20, process: "com.a", uid: nil, seq: 1)
        #expect(tracker.ended(pid: 20, process: "com.a", reason: .crashed, seq: 2)?.marker == .ended(.crashed))
    }

    /// The fatal-signal text is from the comment in Android Studio's `LogcatFilter.kt`.
    @Test func nativeCrashMarksCrashed() {
        var tracker = ProcessMarkerTracker()
        _ = tracker.started(pid: 13445, process: "com.example.native", uid: nil, seq: 1)
        tracker.note(logLine(
            pid: 13445, level: .assert, tag: "libc",
            message: "Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x0 in tid 13445 (tiveapplication), "
                + "pid 13445 (tiveapplication)"))
        #expect(tracker.ended(pid: 13445, process: nil, reason: nil, seq: 5)?.marker == .ended(.crashed))
    }

    @Test func otherErrorsDoNotMarkCrashed() {
        var tracker = ProcessMarkerTracker()
        _ = tracker.started(pid: 608, process: "system_server", uid: nil, seq: 1)
        tracker.note(logLine(pid: 608, level: .error, tag: "ActivityManager", message: "ANR in com.a"))
        _ = tracker.started(pid: 31, process: "com.b", uid: nil, seq: 2)
        tracker.note(logLine(pid: 31, level: .debug, tag: "AndroidRuntime", message: "FATAL EXCEPTION: main"))
        _ = tracker.started(pid: 32, process: "com.c", uid: nil, seq: 3)
        tracker.note(LogEntry.marker("FATAL EXCEPTION"))
        #expect(tracker.ended(pid: 608, process: nil, reason: nil, seq: 9)?.marker == .ended(nil))
        #expect(tracker.ended(pid: 31, process: nil, reason: nil, seq: 9)?.marker == .ended(nil))
        #expect(tracker.ended(pid: 32, process: nil, reason: nil, seq: 9)?.marker == .ended(nil))
    }

    @Test func crashFlagClearsOnRestart() {
        var tracker = ProcessMarkerTracker()
        _ = tracker.started(pid: 7, process: "com.a", uid: nil, seq: 1)
        tracker.note(fatalException(pid: 7))
        #expect(tracker.ended(pid: 7, process: "com.a", reason: nil, seq: 2)?.marker == .ended(.crashed))
        _ = tracker.started(pid: 7, process: "com.a", uid: nil, seq: 3)
        #expect(tracker.ended(pid: 7, process: "com.a", reason: nil, seq: 4)?.marker == .ended(nil))
    }

    @Test func duplicateDeathReportsEmitOnce() {
        var tracker = ProcessMarkerTracker()
        _ = tracker.started(pid: 8, process: "com.a", uid: nil, seq: 1)
        #expect(tracker.ended(pid: 8, process: "com.a", reason: .forceStopped, seq: 2) != nil)
        #expect(tracker.ended(pid: 8, process: "com.a", reason: nil, seq: 3) == nil)
    }

    @Test func duplicateStartIsIgnored() {
        var tracker = ProcessMarkerTracker()
        #expect(tracker.started(pid: 9, process: "com.a", uid: nil, seq: 1).count == 1)
        #expect(tracker.started(pid: 9, process: "com.a", uid: 10001, seq: 2).isEmpty)
        #expect(tracker.liveCount == 1)
    }

    @Test func reusedPidWithoutDeathEndsOldProcess() {
        var tracker = ProcessMarkerTracker()
        _ = tracker.started(pid: 100, process: "com.a", uid: nil, seq: 1)
        let markers = tracker.started(pid: 100, process: "com.b", uid: nil, seq: 5)
        #expect(markers.map(\.text) == [
            "PROCESS ENDED (100) for package com.a",
            "PROCESS STARTED (100) for package com.b",
        ])
    }

    @Test func endOfUnknownProcessStillEmits() {
        var tracker = ProcessMarkerTracker()
        let ended = tracker.ended(pid: 935, process: "WebViewLoader-arm64-v8a", reason: nil, seq: 3)
        #expect(ended?.text == "PROCESS ENDED (935) for package WebViewLoader-arm64-v8a")
        #expect(tracker.ended(pid: 936, process: nil, reason: nil, seq: 4) == nil)
    }

    @Test func remoteProcessTextNamesProcess() {
        var tracker = ProcessMarkerTracker()
        let started = tracker.started(pid: 25768, process: "\(lane2crash):remote", uid: 10234, seq: 1)
        #expect(started.map(\.text) == [
            "PROCESS STARTED (25768) for package \(lane2crash), process \(lane2crash):remote",
        ])
        let ended = tracker.ended(pid: 25768, process: nil, reason: .forceStopped, seq: 2)
        #expect(ended?.text == "PROCESS ENDED (25768) for package \(lane2crash), process \(lane2crash):remote (force stopped)")
    }

    @Test func markerEntryCarriesProcessFields() throws {
        var tracker = ProcessMarkerTracker()
        let marker = try #require(tracker.started(pid: 4758, process: lane2, uid: 10233, seq: 1).first)
        let entry = marker.entry(at: 5)
        #expect(entry.kind == .process(.started))
        #expect(entry.isMarker)
        #expect(entry.pid == 4758)
        #expect(entry.tid == 0)
        #expect(entry.processName == lane2)
        #expect(entry.uid == "10233")
        #expect(entry.tag == "")
        #expect(entry.level == .info)
        #expect(entry.timestamp == 5)
        #expect(entry.message == marker.text)
    }

    // MARK: ps snapshots

    @Test func firstSnapshotIsSilentBaseline() {
        var tracker = ProcessMarkerTracker()
        #expect(tracker.applySnapshot([10: "com.mine"], lookupStartSeq: 0, isTracked: tracked).isEmpty)
        let markers = tracker.applySnapshot([:], lookupStartSeq: 50, isTracked: tracked)
        #expect(markers.map(\.text) == ["PROCESS ENDED (10) for package com.mine"])
    }

    /// The history in the first batch still holds the `Start proc` of a process the baseline saw running.
    @Test func startEventAfterBaselineStillMarksStart() {
        var tracker = ProcessMarkerTracker()
        _ = tracker.applySnapshot([10: "com.mine"], lookupStartSeq: 0, isTracked: tracked)
        let first = tracker.started(pid: 10, process: "com.mine", uid: 10001, seq: 5)
        #expect(first.map(\.text) == ["PROCESS STARTED (10) for package com.mine"])
        #expect(tracker.started(pid: 10, process: "com.mine", uid: 10001, seq: 6).isEmpty)
        #expect(tracker.liveCount == 1)
    }

    @Test func snapshotDiffStartsAndEndsTrackedProcesses() {
        var tracker = ProcessMarkerTracker()
        _ = tracker.applySnapshot([10: "com.mine"], lookupStartSeq: 0, isTracked: tracked)
        let markers = tracker.applySnapshot([11: "com.mine"], lookupStartSeq: 20, isTracked: tracked)
        #expect(markers.map(\.text) == [
            "PROCESS ENDED (10) for package com.mine",
            "PROCESS STARTED (11) for package com.mine",
        ])
        #expect(tracker.applySnapshot([11: "com.mine"], lookupStartSeq: 40, isTracked: tracked).isEmpty)
    }

    @Test func snapshotIgnoresUntrackedPackages() {
        var tracker = ProcessMarkerTracker()
        _ = tracker.applySnapshot([10: "com.other", 11: "/system/bin/vold"], lookupStartSeq: 0, isTracked: tracked)
        #expect(tracker.applySnapshot([12: "com.other"], lookupStartSeq: 20, isTracked: tracked).isEmpty)
        #expect(tracker.applySnapshot([:], lookupStartSeq: 40, isTracked: tracked).isEmpty)
    }

    @Test func snapshotSkipsForkNames() {
        var tracker = ProcessMarkerTracker()
        _ = tracker.applySnapshot([:], lookupStartSeq: 0, isTracked: { _ in true })
        #expect(tracker.applySnapshot([12: "zygote64"], lookupStartSeq: 10, isTracked: { _ in true }).isEmpty)
        let markers = tracker.applySnapshot([12: "com.mine"], lookupStartSeq: 20, isTracked: tracked)
        #expect(markers.map(\.text) == ["PROCESS STARTED (12) for package com.mine"])
    }

    @Test func snapshotDoesNotEndAProcessThatShowsAsForkName() {
        var tracker = ProcessMarkerTracker()
        _ = tracker.started(pid: 12, process: "com.mine", uid: nil, seq: 1)
        #expect(tracker.applySnapshot([12: "zygote64"], lookupStartSeq: 10, isTracked: tracked).isEmpty)
    }

    @Test func snapshotDoesNotOverrideNewerEvents() {
        var tracker = ProcessMarkerTracker()
        _ = tracker.applySnapshot([:], lookupStartSeq: 0, isTracked: tracked)
        // A start after the lookup began is not in the snapshot, but the process is alive.
        _ = tracker.started(pid: 13, process: "com.mine", uid: nil, seq: 30)
        #expect(tracker.applySnapshot([:], lookupStartSeq: 20, isTracked: tracked).isEmpty)
        #expect(tracker.liveCount == 1)

        // An end after the lookup began: the snapshot still lists the process, which does not restart it.
        _ = tracker.started(pid: 14, process: "com.mine", uid: nil, seq: 35)
        _ = tracker.ended(pid: 14, process: "com.mine", reason: nil, seq: 40)
        let markers = tracker.applySnapshot([13: "com.mine", 14: "com.mine"], lookupStartSeq: 38, isTracked: tracked)
        #expect(markers.isEmpty)
    }

    @Test func eventAfterSnapshotDoesNotDuplicate() {
        var tracker = ProcessMarkerTracker()
        _ = tracker.applySnapshot([:], lookupStartSeq: 0, isTracked: tracked)
        let snapshot = tracker.applySnapshot([15: "com.mine"], lookupStartSeq: 10, isTracked: tracked)
        #expect(snapshot.map(\.text) == ["PROCESS STARTED (15) for package com.mine"])
        #expect(tracker.started(pid: 15, process: "com.mine", uid: 10001, seq: 12).isEmpty)
        #expect(tracker.ended(pid: 15, process: "com.mine", reason: .forceStopped, seq: 20) != nil)
        #expect(tracker.ended(pid: 15, process: "com.mine", reason: nil, seq: 21) == nil)
    }

    @Test func snapshotDoesNotRestartAnEndedProcessStillListed() {
        var tracker = ProcessMarkerTracker()
        _ = tracker.started(pid: 17, process: "com.mine", uid: nil, seq: 1)
        _ = tracker.ended(pid: 17, process: "com.mine", reason: .forceStopped, seq: 5)
        // ps can still list a pid for a moment after Killing was logged.
        #expect(tracker.applySnapshot([17: "com.mine"], lookupStartSeq: 10, isTracked: tracked).isEmpty)
    }

    @Test func snapshotEndUsesCrashFlag() {
        var tracker = ProcessMarkerTracker()
        _ = tracker.started(pid: 16, process: "com.mine", uid: nil, seq: 1)
        tracker.note(fatalException(pid: 16))
        let markers = tracker.applySnapshot([:], lookupStartSeq: 10, isTracked: tracked)
        #expect(markers.map(\.marker) == [.ended(.crashed)])
    }

    @Test func deadRecordsArePruned() {
        var tracker = ProcessMarkerTracker()
        for pid in 1...3000 {
            _ = tracker.started(pid: Int32(pid), process: "com.a", uid: nil, seq: pid * 2)
            _ = tracker.ended(pid: Int32(pid), process: "com.a", reason: nil, seq: pid * 2 + 1)
        }
        _ = tracker.started(pid: 5000, process: "com.a", uid: nil, seq: 7000)
        #expect(tracker.liveCount == 1)
        #expect(tracker.recordCount <= 2048 + tracker.liveCount)
        // The newest dead records survive, so a late duplicate report is still ignored.
        #expect(tracker.ended(pid: 3000, process: "com.a", reason: nil, seq: 7001) == nil)
    }

    // MARK: Hoisting

    /// The order seen on a real API 37 run: the child logs before system_server writes `Start proc`.
    @Test func hoistsStartAboveChildLinesInBatch() {
        let batch = [
            LogEntry(timestamp: 1, uid: "root", pid: 12747, tid: 12747, level: .info, tag: "libprocessgroup",
                     message: "Created cgroup /sys/fs/cgroup/apps/uid_10233/pid_12747"),
            activityManager("Start proc 12747:\(lane2)/u0a233 for next-top-activity {\(lane2)/\(lane2).Main}"),
            logLine(pid: 12747, tag: "Zygote", message: "Process 12747 created for \(lane2)", uid: "10233"),
        ]
        let events = eventMap(batch)
        #expect(ProcessMarkerTracker.hoistedStarts(in: batch, events: events) == [0: 1])
    }

    /// The other order seen on a real run (pid 25015): `Start proc` first.
    @Test func doesNotHoistWhenStartComesFirst() {
        let batch = [
            activityManager("Start proc 25015:\(lane2crash)/u0a234 for broadcast {\(lane2crash)/X}"),
            fatalException(pid: 25015),
        ]
        #expect(ProcessMarkerTracker.hoistedStarts(in: batch, events: eventMap(batch)).isEmpty)
    }

    @Test func doesNotHoistAcrossEarlierEventForPid() {
        let batch = [
            logLine(pid: 9, tag: "Old", message: "from the previous run"),
            activityManager("Killing 9:com.a/u0a1 (adj 0): stop com.a"),
            logLine(pid: 9, tag: "New", message: "from the next run"),
            activityManager("Start proc 9:com.a/u0a1 for broadcast {com.a/X}"),
        ]
        #expect(ProcessMarkerTracker.hoistedStarts(in: batch, events: eventMap(batch)) == [2: 3])
    }

    @Test func doesNotHoistBeyondWindow() {
        var batch = [logLine(pid: 9, tag: "Early", message: "x")]
        for _ in 0..<299 { batch.append(logLine(pid: 1, tag: "Other", message: "y")) }
        batch.append(activityManager("Start proc 9:com.a/u0a1 for broadcast {com.a/X}"))
        #expect(ProcessMarkerTracker.hoistedStarts(in: batch, events: eventMap(batch)).isEmpty)
        #expect(ProcessMarkerTracker.hoistedStarts(in: batch, events: eventMap(batch), window: 400) == [0: 300])
    }

    // MARK: Streams

    @Test func liveStreamFixtureProducesMarkersInOrder() throws {
        let text = """
        [          1794311752.441  1000:  608:  638 I/ActivityManager ]
        Start proc 25015:\(lane2crash)/u0a234 for broadcast {\(lane2crash)/\(lane2crash).CrashReceiver}

        [          1794311752.481 10234:25015:25015 E/AndroidRuntime ]
        FATAL EXCEPTION: main
        Process: \(lane2crash), PID: 25015
        java.lang.RuntimeException: Unable to create application \(lane2crash).App
        \tat android.app.ActivityThread.handleBindApplication(ActivityThread.java:8313)

        [          1794311752.490  1000:  608: 1275 I/ActivityManager ]
        Process \(lane2crash) (pid 25015) has died: fg  CEM 

        [          1794309544.730  1000:  608: 1632 I/ActivityManager ]
        Killing 4758:\(lane2)/u0a233 (adj 900): stop \(lane2) due to from pid 4795

        [          1794309545.801  1000:  608:  638 I/ActivityManager ]
        Start proc 4803:\(lane2)/u0a233 for next-top-activity {\(lane2)/\(lane2).Main}


        """
        var parser = LogcatLongParser()
        let entries = parser.feed(Data(text.utf8)) + parser.finish()
        #expect(entries.count == 5)

        var tracker = ProcessMarkerTracker()
        var emitted: [(after: Int, marker: ProcessMarkerTracker.Marker)] = []
        for (index, entry) in entries.enumerated() {
            tracker.note(entry)
            if let event = ProcessEvent(entry) {
                emitted += tracker.apply(event, seq: index).map { (index, $0) }
            }
        }
        #expect(emitted.map(\.marker.text) == [
            "PROCESS STARTED (25015) for package \(lane2crash)",
            "PROCESS ENDED (25015) for package \(lane2crash) (crashed)",
            "PROCESS ENDED (4758) for package \(lane2) (force stopped)",
            "PROCESS STARTED (4803) for package \(lane2)",
        ])
        // Each marker follows the ActivityManager line that reported it, so ENDED (crashed) comes after the
        // FATAL EXCEPTION entry (index 1).
        #expect(emitted.map(\.after) == [0, 2, 3, 4])
        let fatalIndex = try #require(entries.firstIndex { $0.tag == "AndroidRuntime" })
        #expect(emitted[1].after > fatalIndex)
    }

    private func parse(_ text: String) -> [LogEntry] {
        var parser = LogcatLongParser()
        return parser.feed(Data(text.utf8)) + parser.finish()
    }

    /// Runs entries through the tracker the way the session does, with the entry index as sequence number.
    private func markerTexts(_ entries: [LogEntry]) -> [String] {
        var tracker = ProcessMarkerTracker()
        var texts: [String] = []
        for (index, entry) in entries.enumerated() {
            tracker.note(entry)
            if let event = ProcessEvent(entry) {
                texts += tracker.apply(event, seq: index).map(\.text)
            }
        }
        return texts
    }

    /// Real API 37 events entries (`logcat -b events`) for a crash on start and a force stop. There is no
    /// AndroidRuntime entry: the crash buffer is not streamed, so `am_crash` has to carry the crash.
    @Test func eventsBufferStreamProducesMarkers() {
        let text = """
        [          1794311752.441  1000:  608:  638 I/am_proc_start ]
        [0,25015,10234,\(lane2crash),broadcast,{\(lane2crash)/\(lane2crash).CrashReceiver}]

        [          1794311752.463  1000:  608: 1925 I/am_proc_bound ]
        [0,25015,\(lane2crash)]

        [          1794311752.482  1000:  608: 1925 I/am_crash ]
        [25015,0,\(lane2crash),816430662,java.lang.RuntimeException,Lane2Crash boom at +12ms,App.java,17,0]

        [          1794311752.490  1000:  608: 1275 I/am_proc_died ]
        [0,25015,\(lane2crash),0,19]

        [          1794314816.954  1000:  608: 1703 I/am_kill  ]
        [0,29854,\(lane2),900,stop \(lane2) due to from pid 29887,136384]


        """
        #expect(markerTexts(parse(text)) == [
            "PROCESS STARTED (25015) for package \(lane2crash)",
            "PROCESS ENDED (25015) for package \(lane2crash) (crashed)",
            "PROCESS ENDED (29854) for package \(lane2) (force stopped)",
        ])
    }

    /// Both buffers streamed (`-b main,system,crash,events`): real API 37 order for pid 30320, where
    /// `am_proc_start` and `Start proc` carry the same timestamp. Times after the start are approximate, the
    /// order is real. Each transition gets one marker, whichever source comes first.
    @Test func systemAndEventsReportsGiveOneMarkerEach() {
        let text = """
        [          1794315050.039  1000:  608:  638 I/am_proc_start ]
        [0,30320,10233,\(lane2),next-top-activity,{\(lane2)/\(lane2).Main}]

        [          1794315050.039  1000:  608:  638 I/ActivityManager ]
        Start proc 30320:\(lane2)/u0a233 for next-top-activity {\(lane2)/\(lane2).Main}

        [          1794315053.000 10233:30320:30320 E/AndroidRuntime ]
        FATAL EXCEPTION: main
        Process: \(lane2), PID: 30320
        android.app.RemoteServiceException$CrashedByAdbException: shell-induced crash

        [          1794315053.020  1000:  608: 1925 I/am_crash ]
        [30320,0,\(lane2),816430662,android.app.RemoteServiceException$CrashedByAdbException,shell-induced crash,ActivityThread.java,2581,0]

        [          1794315053.060  1000:  608: 1275 I/ActivityManager ]
        Process \(lane2) (pid 30320) has died: cch  CRE 

        [          1794315053.060  1000:  608: 1275 I/am_proc_died ]
        [0,30320,\(lane2),900,18]


        """
        let entries = parse(text)
        #expect(entries.count == 6)
        #expect(markerTexts(entries) == [
            "PROCESS STARTED (30320) for package \(lane2)",
            "PROCESS ENDED (30320) for package \(lane2) (crashed)",
        ])
    }

    @Test func amCrashMarksNamedProcessCrashed() {
        var tracker = ProcessMarkerTracker()
        _ = tracker.started(pid: 25015, process: lane2crash, uid: 10234, seq: 1)
        #expect(tracker.apply(.crashed(pid: 25015, process: lane2crash), seq: 2).isEmpty)
        let ended = tracker.apply(.ended(pid: 25015, process: lane2crash, reason: nil), seq: 3)
        #expect(ended.map(\.marker) == [.ended(.crashed)])
    }

    /// A native crash reaches `handleApplicationCrashInner` from system_server's NativeCrashListener, so the
    /// first field of `am_crash` is system_server's pid. It must not flag system_server as crashed.
    @Test func amCrashFromSystemServerIsIgnored() {
        var tracker = ProcessMarkerTracker()
        _ = tracker.started(pid: 608, process: "system_server", uid: 1000, seq: 1)
        tracker.noteCrash(pid: 608, process: "com.example.native")
        #expect(tracker.ended(pid: 608, process: "system_server", reason: nil, seq: 2)?.marker == .ended(nil))
    }

    @Test func amCrashForUnknownPidStillCounts() {
        var tracker = ProcessMarkerTracker()
        tracker.noteCrash(pid: 77, process: "com.a")
        #expect(tracker.ended(pid: 77, process: "com.a", reason: nil, seq: 2)?.marker == .ended(.crashed))
    }

    // MARK: jdwp

    /// `adb track-jdwp` knows only pids, and reports them after a grace period, so `observedAt` carries the
    /// sequence number at which the pid disappeared.
    @Test func jdwpEndEndsKnownProcess() {
        var tracker = ProcessMarkerTracker()
        _ = tracker.started(pid: 50, process: "com.mine", uid: nil, seq: 10)
        let ended = tracker.ended(pid: 50, process: nil, reason: nil, seq: 30, observedAt: 20)
        #expect(ended?.text == "PROCESS ENDED (50) for package com.mine")
    }

    @Test func jdwpEndSkipsProcessStartedAfterObservation() {
        var tracker = ProcessMarkerTracker()
        _ = tracker.started(pid: 51, process: "com.mine", uid: nil, seq: 25)
        #expect(tracker.ended(pid: 51, process: nil, reason: nil, seq: 30, observedAt: 20) == nil)
        #expect(tracker.ended(pid: 51, process: "com.mine", reason: nil, seq: 40) != nil)
    }

    @Test func jdwpEndAfterActivityManagerEndIsDeduped() {
        var tracker = ProcessMarkerTracker()
        _ = tracker.started(pid: 52, process: "com.mine", uid: nil, seq: 10)
        #expect(tracker.ended(pid: 52, process: "com.mine", reason: .forceStopped, seq: 12) != nil)
        #expect(tracker.ended(pid: 52, process: nil, reason: nil, seq: 20, observedAt: 11) == nil)
    }

    @Test func jdwpEndKeepsCrashFlag() {
        var tracker = ProcessMarkerTracker()
        _ = tracker.started(pid: 53, process: "com.mine", uid: nil, seq: 10)
        tracker.note(fatalException(pid: 53))
        let ended = tracker.ended(pid: 53, process: nil, reason: nil, seq: 30, observedAt: 20)
        #expect(ended?.marker == .ended(.crashed))
    }

    @Test func jdwpEndOfUnknownPidIsIgnored() {
        var tracker = ProcessMarkerTracker()
        #expect(tracker.ended(pid: 54, process: nil, reason: nil, seq: 5, observedAt: 4) == nil)
    }

    private func eventMap(_ batch: [LogEntry]) -> [Int: ProcessEvent] {
        var events: [Int: ProcessEvent] = [:]
        for (index, entry) in batch.enumerated() {
            if let event = ProcessEvent(entry) { events[index] = event }
        }
        return events
    }
}

@Suite struct ProcessMarkerFilterTests {
    private func marker(pid: Int32, process: String, started: Bool = true) -> LogEntry {
        ProcessMarkerTracker.Marker(pid: pid, process: process, uid: nil, marker: started ? .started : .ended(nil))
            .entry(at: 1_000_000)
    }

    private func matches(
        _ query: String,
        _ entry: LogEntry,
        mine: Set<String> = [],
        scope: ProcessMarkerScope = .all
    ) throws -> Bool {
        let context = FilterContext(myPackages: mine, now: 1_000_100, processMarkers: scope)
        return try LogFilter(query).matches(entry, context: context)
    }

    @Test func plainMarkersStillPassEverything() throws {
        let device = LogEntry.marker("Device disconnected")
        for query in ["tag:x", "-tag:x", "package:other", "pid:1"] {
            #expect(try matches(query, device), "\(query)")
        }
        #expect(try matches("package:other", device, scope: .mine))
    }

    @Test func processMarkerMatchesPackageProcessAndPid() throws {
        let entry = marker(pid: 4758, process: lane2)
        for query in ["package:lane2", "package=:\(lane2)", "process~:lane2$", "pid:4758", "package:lane2 & pid:4758"] {
            #expect(try matches(query, entry), "\(query)")
        }
        for query in ["package:other", "pid:1", "process=:x", "package:lane2 & pid:1"] {
            #expect(try !matches(query, entry), "\(query)")
        }
    }

    @Test func emptyQueryShowsMarker() throws {
        #expect(try matches("", marker(pid: 1, process: "com.a")))
    }

    @Test func otherTermsAreNeutral() throws {
        let entry = marker(pid: 4758, process: lane2)
        for query in [
            "tag:Foo", "-tag:Foo", "level:ERROR", "\"some text\"", "-noise", "is:crash", "age:1s", "tid:5",
            "message:x", "line:x", "name:\"My filter\"", "tag:Foo level:E",
        ] {
            #expect(try matches(query, entry), "\(query)")
        }
        #expect(try !matches("tag:Foo & package:other", entry))
        #expect(try !matches("tag:Foo | package:other", entry))
        #expect(try matches("(tag:Foo | level:E) & pid:4758", entry))
        #expect(try matches("tag:Foo | package:lane2", entry))
        #expect(try !matches("-tag:Foo & -package:lane2", entry))
    }

    @Test func negatedPackageHidesMarker() throws {
        let query = "-package:\(lane2)"
        #expect(try !matches(query, marker(pid: 1, process: lane2)))
        #expect(try matches(query, marker(pid: 2, process: "com.other")))
    }

    @Test func packageMineShowsOwnMarkers() throws {
        #expect(try matches("package:mine", marker(pid: 1, process: lane2), mine: [lane2]))
        #expect(try matches("package:mine", marker(pid: 2, process: "\(lane2):remote"), mine: [lane2]))
    }

    @Test func packageMineHidesOtherAppsMarkers() throws {
        #expect(try !matches("package:mine", marker(pid: 3, process: "com.other"), mine: [lane2]))
        #expect(try !matches("package:mine tag:Foo", marker(pid: 3, process: "com.other"), mine: [lane2]))
    }

    @Test func mineScopeHidesOtherAppsMarkersWithoutFilter() throws {
        let own = marker(pid: 1, process: lane2)
        let other = marker(pid: 2, process: "com.other")
        #expect(try matches("", own, mine: [lane2], scope: .mine))
        #expect(try !matches("", other, mine: [lane2], scope: .mine))
        #expect(try !matches("", own, mine: [], scope: .mine))
        #expect(try !matches("pid:1", own, mine: [], scope: .mine))
    }

    @Test func allScopeShowsEveryMarker() throws {
        #expect(try matches("", marker(pid: 2, process: "com.other"), mine: [], scope: .all))
        #expect(try matches("", marker(pid: 2, process: "com.other"), mine: [lane2], scope: .all))
    }

    @Test func logLinesIgnoreScope() throws {
        let line = LogEntry(
            timestamp: 1_000_000, pid: 5, tid: 5, level: .info, tag: "T", message: "m", processName: "com.other")
        #expect(try matches("", line, mine: [lane2], scope: .mine))
    }
}
