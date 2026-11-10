import Foundation
import Testing
@testable import LogcatKit

private func activityManager(_ message: String, tag: String = "ActivityManager") -> LogEntry {
    LogEntry(timestamp: 0, uid: "1000", pid: 608, tid: 638, level: .info, tag: tag, message: message)
}

@Suite struct ProcessEventTests {
    @Test func parsesStartProcOnCurrentAndroid() {
        let entry = activityManager(
            "Start proc 12747:studio.greenmist.test.lane2/u0a233 for next-top-activity "
                + "{studio.greenmist.test.lane2/studio.greenmist.test.lane2.Main}")
        #expect(ProcessEvent(entry) == .started(pid: 12747, process: "studio.greenmist.test.lane2", uid: 10233))
    }

    @Test func parsesRemoteProcessName() {
        let interactor = activityManager(
            "Start proc 1382:com.google.android.googlequicksearchbox:interactor/u0a163 for bound-service "
                + "{com.google.android.googlequicksearchbox/com.google.android.voiceinteraction.GsaVoiceInteractionService}")
        #expect(ProcessEvent(interactor)
            == .started(pid: 1382, process: "com.google.android.googlequicksearchbox:interactor", uid: 10163))

        let vending = activityManager(
            "Start proc 2546:com.android.vending:background/u0a157 for bound-service "
                + "{com.android.vending/com.google.android.finsky.ipc.IpcService}")
        #expect(ProcessEvent(vending) == .started(pid: 2546, process: "com.android.vending:background", uid: 10157))
    }

    @Test func parsesFormattedUIDs() {
        #expect(ProcessEvent.uid(formatted: "1000") == 1000)
        #expect(ProcessEvent.uid(formatted: "u0a233") == 10233)
        #expect(ProcessEvent.uid(formatted: "u10a5") == 1_010_005)
        #expect(ProcessEvent.uid(formatted: "u0i5") == 99005)
        #expect(ProcessEvent.uid(formatted: "u0ai9000") == 99000)
        #expect(ProcessEvent.uid(formatted: "u0s1000") == 1000)
        #expect(ProcessEvent.uid(formatted: "u") == nil)
        #expect(ProcessEvent.uid(formatted: "x12") == nil)
        #expect(ProcessEvent.uid(formatted: "u0q1") == nil)
        #expect(ProcessEvent.uid(formatted: "") == nil)
    }

    @Test func parsesEntryPointBeforeFor() {
        let loader = activityManager(
            "Start proc 935:WebViewLoader-arm64-v8a/1037 [android.webkit.WebViewLibraryLoader$RelroFileCreator] for ")
        #expect(ProcessEvent(loader) == .started(pid: 935, process: "WebViewLoader-arm64-v8a", uid: 1037))

        let sandbox = activityManager(
            "Start proc 3674:com.google.android.webview:sandboxed_process0:org.chromium.content.app.SandboxedProcessService0:0/u0ai9000 "
                + "for bound-service {com.ford.oa/org.chromium.content.app.SandboxedProcessService0:0}")
        #expect(ProcessEvent(sandbox) == .started(
            pid: 3674,
            process: "com.google.android.webview:sandboxed_process0:org.chromium.content.app.SandboxedProcessService0:0",
            uid: 99000))
    }

    /// Derived from AOSP android-5.0.0_r1 `ActivityManagerService.startProcessLocked`, the only release
    /// that puts the pid and uid after the process name.
    @Test func parsesLollipopFormat() {
        let remote = activityManager(
            "Start proc com.example.app:remote [android.app.ActivityThread] for service com.example.app/.RemoteService: "
                + "pid=2345 uid=10057 gids={50057, 9997, 3003}")
        #expect(ProcessEvent(remote) == .started(pid: 2345, process: "com.example.app:remote", uid: 10057))

        let activity = activityManager(
            "Start proc com.example.app for activity com.example.app/.MainActivity: pid=2400 uid=10057 gids={50057, 3003}")
        #expect(ProcessEvent(activity) == .started(pid: 2400, process: "com.example.app", uid: 10057))
    }

    @Test func ignoresOtherLines() {
        let message = "Start proc 12747:studio.greenmist.test.lane2/u0a233 for next-top-activity {a/b}"
        #expect(ProcessEvent(activityManager(message, tag: "MyApp")) == nil)
        #expect(ProcessEvent(LogEntry.marker("Start proc 1:com.a/u0a1 for x")) == nil)
        for text in [
            "Start proc abc",
            "Start proc 12:/u0a1 for x",
            "Start proc 0:com.a/u0a1 for x",
            "Start proc ",
            "Process com.a (pid 1) early provider death",
            "Process ProcessRecord{1 2:com.a/u0a1} failed to attach",
            "Process com.a has crashed too many times: killing!",
            "Killing processes Low memory at adjustment 9",
            "Killing 12:/u0a1 (adj 0): x",
            "Killing abc:com.a/u0a1 (adj 0): x",
            "Force stopping com.a appid=10001 user=0: from pid 5",
            "Process com.a (pid 0) has died",
        ] {
            #expect(ProcessEvent(activityManager(text)) == nil, "\(text)")
        }
        let kill = "Killing 123:com.a/u0a5 (adj 0): stop com.a"
        #expect(ProcessEvent(activityManager(kill, tag: "MyApp")) == nil)
        #expect(ProcessEvent(LogEntry.marker(kill)) == nil)
    }

    /// Real API 37 captures from `logcat -b system`.
    @Test func parsesKillingOnCurrentAndroid() {
        let stopped = activityManager(
            "Killing 4758:studio.greenmist.test.lane2/u0a233 (adj 900): stop studio.greenmist.test.lane2 due to from pid 4795")
        #expect(ProcessEvent(stopped) == .ended(pid: 4758, process: "studio.greenmist.test.lane2", reason: .forceStopped))

        let frozen = activityManager(
            "Killing 2342:com.google.android.googlequicksearchbox:search/u0a163 (adj 935): Async binder space running out while frozen")
        #expect(ProcessEvent(frozen)
            == .ended(pid: 2342, process: "com.google.android.googlequicksearchbox:search", reason: nil))
    }

    /// Real API 37 captures. The trailing space after the process state is in the device output.
    @Test func parsesHasDiedOnCurrentAndroid() {
        let main = activityManager("Process studio.greenmist.test.lane2crash (pid 25015) has died: fg  CEM ")
        #expect(ProcessEvent(main) == .ended(pid: 25015, process: "studio.greenmist.test.lane2crash", reason: nil))

        let remote = activityManager("Process studio.greenmist.test.lane2crash:remote (pid 25768) has died: fg  RCVR")
        #expect(ProcessEvent(remote)
            == .ended(pid: 25768, process: "studio.greenmist.test.lane2crash:remote", reason: nil))

        let loader = activityManager("Process WebViewLoader-arm64-v8a (pid 935) has died: psvc PER ")
        #expect(ProcessEvent(loader) == .ended(pid: 935, process: "WebViewLoader-arm64-v8a", reason: nil))
    }

    /// Derived from AOSP android-9.0.0_r1 `ActivityManagerService.appDiedLocked`, which appends the oom adj
    /// and process state through `reportUidInfoMessageLocked`.
    @Test func parsesHasDiedOnPie() {
        let died = activityManager("Process com.example.app (pid 4321) has died: fore  TOP ")
        #expect(ProcessEvent(died) == .ended(pid: 4321, process: "com.example.app", reason: nil))

        let restarted = activityManager("Process com.example.app (pid 4321) has died and restarted (pid 4400).")
        #expect(ProcessEvent(restarted) == .ended(pid: 4321, process: "com.example.app", reason: nil))
    }

    /// Derived from AOSP android-5.0.0_r1 `appDiedLocked` and `ProcessRecord.kill`; 5.1 logs the same text.
    @Test func parsesLollipopDeathLines() {
        let died = activityManager("Process com.example.app (pid 2345) has died")
        #expect(ProcessEvent(died) == .ended(pid: 2345, process: "com.example.app", reason: nil))

        let remote = activityManager("Process com.example.app:remote (pid 2346) has died")
        #expect(ProcessEvent(remote) == .ended(pid: 2346, process: "com.example.app:remote", reason: nil))

        let stopped = activityManager("Killing 2345:com.example.app/u0a57 (adj 0): stop com.example.app")
        #expect(ProcessEvent(stopped) == .ended(pid: 2345, process: "com.example.app", reason: .forceStopped))

        let isolated = activityManager(
            "Killing 2401:com.android.chrome:sandboxed_process0/u0a57i3 (adj 0): isolated not needed")
        #expect(ProcessEvent(isolated)
            == .ended(pid: 2401, process: "com.android.chrome:sandboxed_process0", reason: nil))

        let crashed = activityManager("Killing 2345:com.example.app/u0a57 (adj 0): crash")
        #expect(ProcessEvent(crashed) == .ended(pid: 2345, process: "com.example.app", reason: .crashed))
    }

    @Test func classifiesKillReasons() {
        #expect(ProcessEndReason(killReason: "crash") == .crashed)
        #expect(ProcessEndReason(killReason: "stop com.a") == .forceStopped)
        #expect(ProcessEndReason(killReason: "stop user 10") == .forceStopped)
        #expect(ProcessEndReason(killReason: "stop com.a due to installPackageLI") == .forceStopped)
        #expect(ProcessEndReason(killReason: "empty #17") == nil)
        #expect(ProcessEndReason(killReason: "remove task") == nil)
        #expect(ProcessEndReason(killReason: "depends on provider x in dying proc y") == nil)
        #expect(ProcessEndReason(killReason: "") == nil)
    }

    @Test func parsesStartProcFromLongFormatStream() {
        let text = """
        [          1794308631.294  1000:  608:  638 I/ActivityManager ]
        Start proc 1545:android.process.acore/u0a106 for content provider {com.android.providers.contacts/com.android.providers.contacts.CallLogProvider}

        [          1794310301.384 10233:12747:12747 I/Zygote   ]
        Process 12747 created for studio.greenmist.test.lane2


        """
        var parser = LogcatLongParser()
        let entries = parser.feed(Data(text.utf8)) + parser.finish()
        #expect(entries.count == 2)
        let events = entries.compactMap { ProcessEvent($0) }
        #expect(events == [.started(pid: 1545, process: "android.process.acore", uid: 10106)])
    }

    /// A real API 37 crash: the app dies right after `Start proc`, then a force stop of an earlier run.
    @Test func parsesLifecycleFromLongFormatStream() {
        let text = """
        [          1794311752.441  1000:  608:  638 I/ActivityManager ]
        Start proc 25015:studio.greenmist.test.lane2crash/u0a234 for broadcast {studio.greenmist.test.lane2crash/studio.greenmist.test.lane2crash.CrashReceiver}

        [          1794311752.481 10234:25015:25015 E/AndroidRuntime ]
        FATAL EXCEPTION: main
        Process: studio.greenmist.test.lane2crash, PID: 25015
        java.lang.RuntimeException: Unable to create application studio.greenmist.test.lane2crash.App
        \tat android.app.ActivityThread.handleBindApplication(ActivityThread.java:8313)

        [          1794311752.490  1000:  608: 1275 I/ActivityManager ]
        Process studio.greenmist.test.lane2crash (pid 25015) has died: fg  CEM 

        [          1794309544.730  1000:  608: 1632 I/ActivityManager ]
        Killing 4758:studio.greenmist.test.lane2/u0a233 (adj 900): stop studio.greenmist.test.lane2 due to from pid 4795


        """
        var parser = LogcatLongParser()
        let entries = parser.feed(Data(text.utf8)) + parser.finish()
        #expect(entries.count == 4)
        #expect(entries.compactMap { ProcessEvent($0) } == [
            .started(pid: 25015, process: "studio.greenmist.test.lane2crash", uid: 10234),
            .ended(pid: 25015, process: "studio.greenmist.test.lane2crash", reason: nil),
            .ended(pid: 4758, process: "studio.greenmist.test.lane2", reason: .forceStopped),
        ])
    }
}
