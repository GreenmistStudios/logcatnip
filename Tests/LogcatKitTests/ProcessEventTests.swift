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
            "Killing 123:com.a/u0a5 (adj 0): stop",
            "Process com.a (pid 1) has died",
            "Start proc ",
        ] {
            #expect(ProcessEvent(activityManager(text)) == nil, "\(text)")
        }
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
}
