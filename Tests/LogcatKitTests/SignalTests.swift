import Foundation
import Testing
@testable import LogcatKit

private func fixture(_ name: String) throws -> [LogEntry] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "logcat", subdirectory: "Fixtures"))
    let entries = LogcatLongParser.parse(try String(contentsOf: url, encoding: .utf8))
    // The app process name, as the resolver would fill it in, for entries logged by the app's uid.
    return entries.map { entry in
        var entry = entry
        if entry.uid == "10234" { entry.processName = "com.example.app" }
        return entry
    }
}

private func entry(_ tag: String, _ level: LogLevel, _ message: String, pid: Int32 = 100, process: String? = "com.example.app") -> LogEntry {
    LogEntry(timestamp: 1_000_000, uid: "10234", pid: pid, tid: pid, level: level, tag: tag, message: message, processName: process)
}

/// The anchor signals in `entries`, as (rule, entry).
private func anchors(_ entries: [LogEntry]) -> [(SignalMatch, LogEntry)] {
    entries.compactMap { entry in
        LogClassifier.signal(for: entry).flatMap { $0.isAnchor ? ($0, entry) : nil }
    }
}

@Suite struct SignalRuleTests {
    @Test func javaCrashFixture() throws {
        let entries = try fixture("java-crash")
        let found = anchors(entries)
        #expect(found.map(\.0.rule) == Array(repeating: SignalRules.ID.fatalException, count: 3))
        #expect(found.allSatisfy { $0.0.kind == .crash && $0.0.kind.isFatal })
        // The non-FATAL AndroidRuntime error and the "Shutting down VM" lines aren't signals.
        #expect(entries.filter { $0.tag == "AndroidRuntime" }.count == 6)
        #expect(entries.filter { LogClassifier.signal(for: $0) != nil }.count == 3)
    }

    @Test func nativeCrashFixture() throws {
        let entries = try fixture("native-crash")
        let found = anchors(entries)
        #expect(found.map(\.0.rule) == [SignalRules.ID.fatalSignal, SignalRules.ID.tombstone])
        let details = entries.compactMap { LogClassifier.signal(for: $0) }.filter { !$0.isAnchor }
        #expect(details.allSatisfy { $0.kind == .nativeCrash && $0.rule == SignalRules.ID.tombstoneDetail })
        // Cmdline, pid, signal and seven frames; not the registers, fingerprint or "backtrace:".
        #expect(details.count == 10)
        // tombstoned and Zygote follow-ups aren't signals.
        #expect(entries.filter { ["tombstoned", "Zygote", "ActivityManager"].contains($0.tag) }.allSatisfy { LogClassifier.signal(for: $0) == nil })
    }

    @Test func anrFixture() throws {
        let entries = try fixture("anr")
        let found = anchors(entries)
        #expect(found.map(\.0.rule) == [
            SignalRules.ID.inputDispatchTimeout, SignalRules.ID.inputDispatchTimeout, SignalRules.ID.anrReport,
        ])
        #expect(found.map(\.1.tag) == ["InputDispatcher", "WindowManager", "ActivityManager"])
        #expect(found.allSatisfy { $0.0.kind == .anr })
        // "Canceling events … because it is unresponsive" and the kill that follows aren't signals.
        #expect(entries.filter { LogClassifier.signal(for: $0) != nil }.count == 3)
    }

    @Test func leaksFixture() throws {
        let entries = try fixture("leaks")
        let found = anchors(entries)
        #expect(found.map(\.0.rule) == [
            SignalRules.ID.leakCanary, SignalRules.ID.strictModeLeak,
            SignalRules.ID.leakedRegistration, SignalRules.ID.leakedRegistration,
        ])
        #expect(found.allSatisfy { $0.0.kind == .leak && !$0.0.kind.isFatal })
        // LeakCanary's progress lines aren't leaks.
        #expect(entries.filter { $0.tag == "LeakCanary" }.count == 3)
    }

    @Test func performanceFixture() throws {
        let entries = try fixture("performance")
        let found = anchors(entries)
        #expect(found.map(\.0.rule) == [
            SignalRules.ID.skippedFrames, SignalRules.ID.davey, SignalRules.ID.strictModeViolation,
            SignalRules.ID.monitorContention, SignalRules.ID.throwingOutOfMemory, SignalRules.ID.lowMemoryKill,
        ])
        #expect(found.map(\.0.kind) == [.performance, .performance, .performance, .performance, .outOfMemory, .outOfMemory])
    }

    @Test func crashRuleNegatives() {
        #expect(LogClassifier.signal(for: entry("AndroidRuntime", .error, "Unable to report crash: no default app")) == nil)
        #expect(LogClassifier.signal(for: entry("AndroidRuntime", .debug, "FATAL EXCEPTION: main")) == nil)
        #expect(LogClassifier.signal(for: entry("MyTag", .error, "FATAL EXCEPTION: main")) == nil)
        let nested = entry("AndroidRuntime", .error, "Uncaught handler\nFATAL EXCEPTION: main")
        #expect(LogClassifier.signal(for: nested)?.kind == .crash)
        // Markers never classify, whatever they say.
        #expect(LogClassifier.signal(for: .marker("FATAL EXCEPTION")) == nil)
    }

    @Test func nativeRuleNegatives() {
        #expect(LogClassifier.signal(for: entry("libc", .error, "Fatal signal 11 (SIGSEGV)")) == nil)
        #expect(LogClassifier.signal(for: entry("libc", .assert, "FORTIFY: pthread_mutex_lock called on a destroyed mutex")) == nil)
        #expect(LogClassifier.signal(for: entry("DEBUG", .assert, "    x0  0000000000000000  x1  0000007a4c3f2e10")) == nil)
        #expect(LogClassifier.signal(for: entry("crash_dump64", .assert, "*** *** *** *** *** ***"))?.rule == SignalRules.ID.tombstone)
        #expect(LogClassifier.signal(for: entry("DEBUG", .assert, "Abort message: 'bad state'"))?.isAnchor == false)
    }

    @Test func anrRules() {
        let legacy = entry("InputDispatcher", .info, "Application is not responding: AppWindowToken{1 token=Token{2 ActivityRecord{3 u0 com.example.app/.MainActivity t9}}}.  It has been 5006.2ms since event, 5005.4ms since wait started.  Reason: Waiting because the touched window's input channel is not registered with the input dispatcher.")
        #expect(LogClassifier.signal(for: legacy)?.rule == SignalRules.ID.inputDispatchTimeout)
        let legacyWM = entry("WindowManager", .info, "Input event dispatching timed out sending to com.example.app/com.example.app.MainActivity.  Reason: Waiting to send non-key event")
        #expect(LogClassifier.signal(for: legacyWM) == nil)
        #expect(LogClassifier.signal(for: entry("ActivityManager", .info, "ANR in com.example.app")) == nil)
        #expect(LogClassifier.signal(for: entry("ActivityManager", .error, "Reason: Input dispatching timed out"))
                == SignalMatch(kind: .anr, rule: SignalRules.ID.anrReason, isAnchor: false))
        #expect(LogClassifier.signal(for: entry("InputDispatcher", .warn, "Canceling events for 1 com.example.app/com.example.app.MainActivity (server) because it is unresponsive")) == nil)
    }

    @Test func outOfMemoryRules() {
        // ART logs as `art` before Android 9 and with the process name after.
        #expect(LogClassifier.signal(for: entry("art", .warn, "Throwing OutOfMemoryError \"Failed to allocate a 12 byte allocation with 0 free bytes\""))?.kind == .outOfMemory)
        #expect(LogClassifier.signal(for: entry("com.example.app", .info, "Throwing OutOfMemoryError \"x\"")) == nil)
        #expect(LogClassifier.signal(for: entry("lmkd", .info, "Kill 'com.other' (1), uid 1, oom_score_adj 900 to free 1kB rss"))?.rule == SignalRules.ID.lowMemoryKill)
        #expect(LogClassifier.signal(for: entry("lowmemorykiller", .info, "Killing 'com.other' (1)")) == nil)
    }

    @Test func leakRules() {
        let noLeaks = entry("LeakCanary", .debug, "====================================\nHEAP ANALYSIS RESULT\n====================================\n0 APPLICATION LEAKS\n\nReferences underlined with \"~~~\" are likely causes.\n====================================\n2 LIBRARY LEAKS\n┬───")
        #expect(LogClassifier.signal(for: noLeaks) == nil)
        let twelve = entry("LeakCanary", .debug, "====================================\nHEAP ANALYSIS RESULT\n====================================\n12 APPLICATION LEAKS\n")
        #expect(LogClassifier.signal(for: twelve)?.kind == .leak)
        // LeakCanary logs one line per record when a result is longer than 4,000 characters.
        #expect(LogClassifier.signal(for: entry("LeakCanary", .debug, "┬───"))?.kind == .leak)
        #expect(LogClassifier.signal(for: entry("LeakCanary", .debug, "HEAP ANALYSIS RESULT")) == nil)
        for violation in ["InstanceCountViolation", "IntentReceiverLeakedViolation", "ServiceConnectionLeakedViolation", "SqliteObjectLeakedViolation"] {
            let message = "StrictMode policy violation: android.os.strictmode.\(violation): leaked"
            #expect(LogClassifier.signal(for: entry("StrictMode", .debug, message))?.rule == SignalRules.ID.strictModeLeak, "\(violation)")
        }
        let service = entry("ActivityThread", .error, "Activity com.example.app.MainActivity has leaked ServiceConnection com.example.app.MainActivity$1@1 that was originally bound here")
        #expect(LogClassifier.signal(for: service)?.rule == SignalRules.ID.leakedRegistration)
        #expect(LogClassifier.signal(for: entry("WindowManager", .warn, "Activity com.example.app.MainActivity has leaked window")) == nil)
    }

    @Test func performanceRules() {
        let skipped = { (n: Int) in entry("Choreographer", .info, "Skipped \(n) frames!  The application may be doing too much work on its main thread.") }
        #expect(LogClassifier.signal(for: skipped(29)) == nil)
        #expect(LogClassifier.signal(for: skipped(30))?.rule == SignalRules.ID.skippedFrames)
        #expect(LogClassifier.signal(for: skipped(1200))?.rule == SignalRules.ID.skippedFrames)
        #expect(LogClassifier.signal(for: entry("Choreographer", .info, "Skipped frames: 45")) == nil)
        // A StrictMode line that isn't a violation report.
        #expect(LogClassifier.signal(for: entry("StrictMode", .debug, "onThreadPolicyViolation; penalty=4325377")) == nil)
        #expect(LogClassifier.signal(for: entry("StrictMode", .debug, "StrictMode policy violation; ~duration=4 ms: android.os.strictmode.NetworkViolation"))?.rule == SignalRules.ID.strictModeViolation)
        #expect(LogClassifier.signal(for: entry("OpenGLRenderer", .info, "Davey! duration=700ms; Flags=0, "))?.rule == SignalRules.ID.davey)
        #expect(LogClassifier.signal(for: entry("HWUI", .info, "Davey! duration=700ms; "))?.rule == SignalRules.ID.davey)
    }

    @Test func customRulesAndOrdering() {
        let enrich = SignalRule(id: "test.enrich", kind: .leak, tags: ["T"], minLevel: .debug, isAnchor: false) { _ in true }
        let anchor = SignalRule(id: "test.anchor", kind: .performance, tags: nil, minLevel: .warn) { $0.message.hasPrefix("slow") }
        let rules = [enrich, anchor]
        // Anchors win over enrichment rules listed before them.
        #expect(LogClassifier.signal(for: entry("T", .warn, "slow"), rules: rules)?.rule == "test.anchor")
        #expect(LogClassifier.signal(for: entry("T", .debug, "slow"), rules: rules)?.rule == "test.enrich")
        #expect(LogClassifier.signal(for: entry("U", .debug, "slow"), rules: rules) == nil)
        #expect(SignalRuleSet(rules).match(entry("T", .warn, "slow"))?.rule == "test.anchor")
        #expect(SignalRuleSet(rules).match(entry("U", .warn, "slow"))?.rule == "test.anchor")
        #expect(SignalRuleSet(rules).match(entry("U", .info, "slow")) == nil)
        #expect(SignalRuleSet([]).match(entry("T", .assert, "slow")) == nil)
    }

    @Test func ruleSetAgreesWithArrayForFixtures() throws {
        for name in ["java-crash", "native-crash", "anr", "leaks", "performance"] {
            for entry in try fixture(name) {
                #expect(LogClassifier.signal(for: entry) == LogClassifier.signal(for: entry, rules: SignalRules.default))
            }
        }
    }

    @Test func kindTitles() {
        #expect(SignalKind.allCases.filter(\.isFatal) == [.crash, .nativeCrash, .anr])
        #expect(SignalKind.performance.title == "Jank")
        #expect(SignalKind.nativeCrash.title == "Native crash")
    }
}

@Suite struct FrameParsingTests {
    @Test func javaFrames() throws {
        let kotlin = try #require(JavaFrame.parse("\tat com.example.app.MainActivity.onCreate(MainActivity.kt:42)"))
        #expect(kotlin == JavaFrame(className: "com.example.app.MainActivity", method: "onCreate", file: "MainActivity.kt", line: 42))
        #expect(kotlin.displayText == "MainActivity.onCreate (MainActivity.kt:42)")

        let unknown = try #require(JavaFrame.parse("        at a.b.C$Inner.m(Unknown Source:4)"))
        #expect(unknown == JavaFrame(className: "a.b.C$Inner", method: "m", file: nil, line: 4))
        #expect(unknown.simpleClassName == "C$Inner")

        let native = try #require(JavaFrame.parse("at java.lang.reflect.Method.invoke(Native Method)"))
        #expect(native.file == nil && native.line == nil)
        #expect(native.displayText == "Method.invoke (Unknown Source)")

        #expect(JavaFrame.parse("at java.io.FileInputStream.<init>(FileInputStream.java:185)")?.method == "<init>")
        #expect(JavaFrame.parse("at com.example.Foo$$ExternalSyntheticLambda0.run(D8$$SyntheticClass:0)")?.file == "D8$$SyntheticClass")
        #expect(JavaFrame.parse("at java.base/java.lang.Thread.run(Thread.java:840)")?.className == "java.lang.Thread")
        #expect(JavaFrame.parse("at com.example.Foo.bar(Foo.kt)")?.line == nil)
    }

    @Test func javaFrameNegatives() {
        #expect(JavaFrame.parse("at the moment (really)") == nil)
        #expect(JavaFrame.parse("at Foo(Foo.kt:1)") == nil)
        #expect(JavaFrame.parse("... 12 more") == nil)
        #expect(JavaFrame.parse("Caused by: java.lang.Throwable") == nil)
        #expect(JavaFrame.parse("at com.example.Foo.bar(Foo.kt:1") == nil)
    }

    @Test func nativeFrames() throws {
        let libc = try #require(NativeFrame.parse("      #00 pc 000000000004f0c8  /apex/com.android.runtime/lib64/bionic/libc.so (abort+164) (BuildId: a87908b48b368e6282bcc9f34bcfc28c)"))
        #expect(libc == NativeFrame(index: 0, pc: "000000000004f0c8", library: "/apex/com.android.runtime/lib64/bionic/libc.so", symbol: "abort+164"))
        #expect(!libc.isAppLibrary)
        #expect(libc.displayText == "libc.so (abort+164)")

        let cpp = try #require(NativeFrame.parse("#04 pc 00000000002c1f1c  /system/lib64/libhwui.so (android::uirenderer::renderthread::RenderThread::threadLoop()+220) (BuildId: 9c8b)"))
        #expect(cpp.index == 4)
        #expect(cpp.symbol == "android::uirenderer::renderthread::RenderThread::threadLoop()+220")

        let apk = try #require(NativeFrame.parse("  #12 pc 0000000000001a2c  /data/app/~~Qm==/com.example.app-7h==/base.apk!libnative.so (offset 0x4000) (crashMe+20) (BuildId: 3e9f)"))
        #expect(apk.isAppLibrary)
        #expect(apk.symbol == "crashMe+20")
        #expect(apk.libraryName == "libnative.so")

        let bare = try #require(NativeFrame.parse("#01 pc 00000000000c4e44  [anon:dalvik-jit-code-cache] (offset 0x2000000)"))
        #expect(bare.library == "[anon:dalvik-jit-code-cache]")
        #expect(bare.symbol == nil)

        let unsymbolized = try #require(NativeFrame.parse("#02 pc 0000000000012345  /data/app/x/lib/arm64/libfoo.so"))
        #expect(unsymbolized.symbol == nil)
        #expect(unsymbolized.displayText == "libfoo.so")
    }

    @Test func nativeFrameNegatives() {
        #expect(NativeFrame.parse("#00 pc") == nil)
        #expect(NativeFrame.parse("#xx pc 0000 /lib.so") == nil)
        #expect(NativeFrame.parse("#00 pc zzzz /lib.so") == nil)
        #expect(NativeFrame.parse("# 1 pc 0000 /lib.so") == nil)
        #expect(NativeFrame.parse("backtrace:") == nil)
    }

    @Test func isStackFrameAgreesWithParsers() throws {
        for name in ["java-crash", "native-crash", "leaks", "performance"] {
            for entry in try fixture(name) {
                for line in entry.message.split(separator: "\n") where JavaFrame.parse(line) != nil || NativeFrame.parse(line) != nil {
                    #expect(LogClassifier.isStackFrame(line), "\(line)")
                }
            }
        }
    }
}

@Suite struct CrashSignatureTests {
    private func signatures(_ entries: [LogEntry]) -> [CrashSignature] {
        anchors(entries).map { CrashSignature.make(for: $0.0, entry: $0.1) }
    }

    @Test func javaCrashesGroupAcrossRuns() throws {
        let found = signatures(try fixture("java-crash"))
        #expect(found.count == 3)
        // Same crash, different pid and time.
        #expect(found[0] == found[1])
        #expect(found[0].key == found[1].key)
        #expect(found[0] != found[2])
        #expect(found[0].title == "java.lang.IllegalStateException")
        #expect(found[0].detail == "ProfileRepository.requireProfile (ProfileRepository.kt:58)")
        #expect(found[0].package == "com.example.app")
        #expect(found[0].displayText == "IllegalStateException · ProfileRepository.requireProfile (ProfileRepository.kt:58)")
        #expect(found[2].title == "java.lang.NullPointerException")
        #expect(found[2].detail == "SyncWorker$doWork$2.invokeSuspend (SyncWorker.kt:77)")
    }

    @Test func javaCrashSignatureDetails() {
        let message = """
            FATAL EXCEPTION: main
            Process: com.example.app:remote, PID: 1
            java.lang.IllegalStateException: boom 0x1234
            \tat android.os.Handler.dispatchMessage(Handler.java:106)
            \tat com.example.app.Foo.bar(Foo.kt:1)
            """
        let signature = CrashSignature.javaCrash(message: message, package: nil)
        #expect(signature.package == "com.example.app")
        #expect(signature.title == "java.lang.IllegalStateException")
        #expect(signature.detail == "Foo.bar (Foo.kt:1)")

        // Without a frame in the package, the first frame.
        let other = CrashSignature.javaCrash(message: message, package: "com.other")
        #expect(other.detail == "Handler.dispatchMessage (Handler.java:106)")

        // A different top frame is a different crash.
        let moved = CrashSignature.javaCrash(message: message.replacingOccurrences(of: "Foo.kt:1", with: "Foo.kt:2"), package: nil)
        #expect(moved != signature)
        #expect(moved.key != signature.key)

        // An out-of-memory crash stays a crash and carries the type.
        let oom = CrashSignature.javaCrash(message: "FATAL EXCEPTION: main\njava.lang.OutOfMemoryError: Failed to allocate a 1 byte allocation", package: nil)
        #expect(oom.kind == .crash)
        #expect(oom.title == "java.lang.OutOfMemoryError")
        #expect(oom.detail == nil)
        #expect(oom.displayText == "OutOfMemoryError")
    }

    @Test func nativeCrashBuildsFromHeaderAndTombstone() throws {
        let entries = try fixture("native-crash")
        let header = try #require(entries.first { $0.tag == "libc" })
        var signature = CrashSignature.native(header: header)
        #expect(signature.title == "SIGSEGV (SEGV_MAPERR)")
        #expect(signature.package == "com.example.app")
        #expect(signature.detail == nil)
        for entry in entries where entry.tag == "DEBUG" {
            signature.enrich(with: entry)
        }
        #expect(signature.detail == "libnative.so (crashMe+20)")
        #expect(signature.displayText == "SIGSEGV (SEGV_MAPERR) · libnative.so (crashMe+20)")

        // Starting from the tombstone header (crash_dump's process, not the app's) fills in the same.
        let tombstone = try #require(entries.first { $0.message.hasPrefix("*** ***") })
        var fromTombstone = CrashSignature.native(header: tombstone)
        #expect(fromTombstone.package == nil)
        for entry in entries where entry.tag == "DEBUG" {
            fromTombstone.enrich(with: entry)
        }
        #expect(fromTombstone == signature)
    }

    @Test func nativeCrashPrefersAppFrames() {
        var signature = CrashSignature.native(header: entry("libc", .assert, "Fatal signal 6 (SIGABRT), code -1 (SI_QUEUE) in tid 2 (main), pid 2 (com.example.app)", pid: 2))
        #expect(signature.title == "SIGABRT (SI_QUEUE)")
        signature.enrich(with: entry("DEBUG", .assert, "      #00 pc 000000000005b8f0  /apex/com.android.runtime/lib64/bionic/libc.so (abort+164) (BuildId: a8)"))
        #expect(signature.detail == "libc.so (abort+164)")
        signature.enrich(with: entry("DEBUG", .assert, "      #01 pc 0000000000001000  /system/lib64/libutils.so (android::Foo()+8)"))
        #expect(signature.detail == "libc.so (abort+164)")
        signature.enrich(with: entry("DEBUG", .assert, "      #02 pc 0000000000001a2c  /data/app/x/lib/arm64/libnative.so (crashMe+20)"))
        #expect(signature.detail == "libnative.so (crashMe+20)")
        signature.enrich(with: entry("DEBUG", .assert, "      #03 pc 0000000000001b80  /data/app/x/lib/arm64/libnative.so (other+4)"))
        #expect(signature.detail == "libnative.so (crashMe+20)")

        // Same crash in another process at other addresses.
        var again = CrashSignature.native(header: entry("libc", .assert, "Fatal signal 6 (SIGABRT), code -1 (SI_QUEUE) in tid 9 (main), pid 9 (com.example.app)", pid: 9))
        again.enrich(with: entry("DEBUG", .assert, "#02 pc 0000000000009999  /data/app/y/lib/arm64/libnative.so (crashMe+20)\n#03 pc 1  /data/app/y/lib/arm64/libnative.so (other+4)"))
        #expect(again == signature)
    }

    @Test func anrSignature() throws {
        let entries = try fixture("anr")
        let found = signatures(entries)
        #expect(found.count == 3)
        for signature in found {
            #expect(signature == CrashSignature(kind: .anr, title: "Input dispatching timed out", package: "com.example.app"))
        }

        var started = CrashSignature.anr(message: entries.first { $0.tag == "InputDispatcher" }!.message)
        started.enrich(with: entry("ActivityManager", .error, "Reason: executing service com.example.app/.SyncService"))
        #expect(started.title == "executing service com.example.app/.SyncService")

        let broadcast = CrashSignature.anr(message: "ANR in com.example.app:sync\nPID: 4410\nReason: Broadcast of Intent { act=android.intent.action.BOOT_COMPLETED flg=0x9000010 cmp=com.example.app/.BootReceiver }, 10s timeout")
        let again = CrashSignature.anr(message: "ANR in com.example.app:sync\nPID: 5120\nReason: Broadcast of Intent { act=android.intent.action.BOOT_COMPLETED flg=0x9000010 cmp=com.example.app/.BootReceiver }, 20s timeout")
        #expect(broadcast == again)
        #expect(broadcast.package == "com.example.app")
        #expect(!broadcast.title.contains { $0.isNumber })

        var unknown = CrashSignature.anr(message: "ANR in com.example.app")
        #expect(unknown.title == "ANR")
        unknown.enrich(with: entry("ActivityManager", .error, "Reason: Input dispatching timed out (1a2b3c com.example.app/… is not responding. Waited 5000ms for KeyEvent)"))
        #expect(unknown.title == "Input dispatching timed out")
    }

    @Test func leakSignatures() throws {
        let found = signatures(try fixture("leaks"))
        #expect(found.map(\.title) == [
            "com.example.app.MainActivity", "LeakedClosableViolation",
            "com.example.app.MainActivity", "com.example.app.MainActivity",
        ])
        #expect(found.map(\.detail) == ["LeakCanary", "SettingsStore.load (SettingsStore.kt:31)", "leaked window", "leaked IntentReceiver"])
        #expect(found.allSatisfy { $0.package == "com.example.app" })
        #expect(found[0].displayText == "MainActivity · LeakCanary")
        #expect(Set(found).count == 4)
    }

    @Test func performanceAndMemorySignatures() throws {
        let found = signatures(try fixture("performance"))
        #expect(found.map(\.title) == [
            "Skipped frames", "Davey", "StrictMode DiskReadViolation", "Long monitor contention",
            "OutOfMemoryError", "Killed by lmkd",
        ])
        #expect(found.map(\.package) == Array(repeating: "com.example.app", count: 6))
        #expect(found.last?.detail == "low watermark is breached and swap is low")

        // Every skipped-frames warning in an app is one problem.
        let a = CrashSignature.performance(rule: SignalRules.ID.skippedFrames, message: "Skipped 45 frames!", package: "com.example.app")
        let b = CrashSignature.performance(rule: SignalRules.ID.skippedFrames, message: "Skipped 92 frames!", package: "com.example.app")
        #expect(a == b)
        #expect(a != CrashSignature.performance(rule: SignalRules.ID.skippedFrames, message: "", package: "com.other"))
    }
}

/// Classifying ordinary entries. Run with `LOGCATNIP_PERF_TESTS=1 swift test --filter SignalPerformance`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LOGCATNIP_PERF_TESTS"] == "1"))
struct SignalPerformanceTests {
    @Test func classify250kEntries() {
        let tags = ["ActivityManager", "Choreographer", "OkHttp", "com.example.app", "StrictMode", "chatty", "WindowManager", "View"]
        let levels: [LogLevel] = [.verbose, .debug, .info, .warn, .error]
        let entries = (0..<250_000).map { id in
            LogEntry(id: id, timestamp: 1_000_000, pid: 1, tid: 1, level: levels[id % levels.count], tag: tags[id % tags.count],
                     message: "request \(id) took \(id % 900) ms")
        }
        let clock = ContinuousClock()
        var count = 0
        let duration = clock.measure {
            for entry in entries where LogClassifier.signal(for: entry) != nil { count += 1 }
        }
        print("[perf] classify 250k entries: \(duration)")
        #expect(count == 0)
        #expect(duration < .milliseconds(500))

        // For scale: parsing the same entries, which ingestion does anyway.
        let text = entries.map(LogcatLongFormat.format).joined()
        let parse = clock.measure { _ = LogcatLongParser.parse(text) }
        print("[perf] parse 250k entries: \(parse)")
    }
}
