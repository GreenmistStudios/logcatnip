import Foundation
import Testing
@testable import LogcatKit

// Tests for opening saved logs: format detection, Android Studio `.logcat` JSON, bug reports and Firebase logs.
//
// There are no real Android Studio exports to test against, so the fixtures below are derived from Android
// Studio's source (platform/tools/adt/idea, refs/heads/mirror-goog-studio-main, read 2026-11-10). This is the
// format version they pin:
//
// - logcat/src/com/android/tools/idea/logcat/files/LogcatFileIo.kt: Gson with setPrettyPrinting() and a
//   DeviceSerializer; the THREADTIME, BUGREPORT, FIREBASE and BUGREPORT_FILE (56 `=`) detection; zips by extension.
// - files/LogcatFileData.kt: LogcatFileData(metadata, logcatMessages), Metadata(device, filter,
//   projectApplicationIds) and safeGetFilter.
// - files/LogcatFileParser.kt: bug reports read only `------ SYSTEM LOG ` sections and use `pid-N` process names.
// - message/LogcatHeader.kt, LogcatMessage.kt: header fields logLevel, pid, tid, applicationId, processName, tag
//   and timestamp (an Instant, which Gson writes as {"seconds","nanos"}).
// - devices/Device.kt: the current `physicalDevice` / `emulatorDevice` wrapper; releases up to studio-2024.3.1 wrote
//   a flat Device with `name` and `sdk` instead.
// - testResources/logcatFiles/logcat-firebase.txt and logcat-firebase-expected.txt: Firebase lines and the
//   messages Android Studio makes from them.
//
// The bug report fixture is trimmed from a real `adb bugreport` of an API 37 emulator (uid column, the second
// `SYSTEM LOG ... -T` section, the properties and dumpsys process lines).

// MARK: Fixtures

enum LogFileFixtures {
    /// What Android Studio writes today: a physical device, a `package:mine` filter, a placeholder message, a
    /// `pid-N` process, a message with Gson's `\u003d` escapes, and an ASSERT from a Google package.
    static let studioCurrent = #"""
    {
      "metadata": {
        "device": {
          "physicalDevice": {
            "deviceId": {
              "pluginId": "PhysicalDevice",
              "isTemplate": false,
              "identifier": "serial=35930112X"
            },
            "serialNumber": "35930112X",
            "isOnline": true,
            "release": "14",
            "apiLevel": {
              "majorVersion": 34,
              "minorVersion": 0
            },
            "featureLevel": 34,
            "manufacturer": "Google",
            "model": "Pixel 8",
            "type": "HANDHELD"
          }
        },
        "filter": "package:mine level:WARN",
        "projectApplicationIds": [
          "com.example.app"
        ]
      },
      "logcatMessages": [
        {
          "header": {
            "logLevel": "INFO",
            "pid": 0,
            "tid": 0,
            "applicationId": "",
            "processName": "",
            "tag": "",
            "timestamp": {
              "seconds": 0,
              "nanos": 0
            }
          },
          "message": "--------- beginning of main"
        },
        {
          "header": {
            "logLevel": "INFO",
            "pid": 1303,
            "tid": 1303,
            "applicationId": "pid-1303",
            "processName": "pid-1303",
            "tag": "vold",
            "timestamp": {
              "seconds": 1684301217,
              "nanos": 485000000
            }
          },
          "message": "Vold 3.0 (the awakening) firing up"
        },
        {
          "header": {
            "logLevel": "WARN",
            "pid": 4321,
            "tid": 4330,
            "applicationId": "com.example.app",
            "processName": "com.example.app:remote",
            "tag": "Net",
            "timestamp": {
              "seconds": 1794248132,
              "nanos": 663000000
            }
          },
          "message": "timeout\u003d30s \u003cretrying\u003e\n\tat com.example.Net.call(Net.kt:12)"
        },
        {
          "header": {
            "logLevel": "ASSERT",
            "pid": 5000,
            "tid": 5000,
            "applicationId": "com.google.android.gms",
            "processName": "com.google.android.gms.persistent",
            "tag": "libc",
            "timestamp": {
              "seconds": 1794248133,
              "nanos": 1000000
            }
          },
          "message": "Fatal signal 6 (SIGABRT)"
        }
      ]
    }
    """#

    /// A bug report trimmed from a real API 37 emulator: header, dumpsys process lines, SYSTEM, EVENT and RADIO
    /// logs with a uid column, an empty STATS LOG, a failed LAST LOGCAT, properties and the second SYSTEM LOG
    /// (`-T`) whose first lines repeat the end of the first.
    static let bugreport = #"""
    ========================================================
    == dumpstate: 2026-11-10 08:01:48
    ========================================================

    Build: CE2A.260420.051.A2
    Build fingerprint: 'google/sdk_gphone64_arm64/emu64a:17/CE2A.260420.051.A2/16418371:user/release-keys'
    Bootloader: unknown
    Radio: 1.0.0.0
    Network: T-Mobile
    Module Metadata version: 370518000
    Android SDK version: 37
    ------ DUMPSYS CRITICAL (/system/bin/dumpsys -t 100 -T 10000 --priority CRITICAL --proto) ------
            app=ProcessRecord{4ffbd8a 1038:com.google.android.apps.nexuslauncher/u0a196}
      VisibleActivityProcess:[ ProcessRecord{4ffbd8a 1038:com.google.android.apps.nexuslauncher/u0a196}]
    --------- 0.128s was the duration of dumpsys activity, ending at: 2026-11-10 08:01:50
    ------ SYSTEM LOG (logcat -v threadtime -v printable -v uid -d *:v) ------
    --------- beginning of system
    11-10 06:03:21.874  root   254   254 I vold    : Vold 3.0 (the awakening) firing up
    11-10 06:03:21.874  root   254   254 D vold    : Detected support for: ext4 f2fs vfat
    --------- beginning of main
    11-10 08:01:51.178 10196  1038  1038 D Launcher: first line
    11-10 08:01:51.178 10196  1038  1038 D Launcher: second line
    11-10 08:01:51.186 10163 26351 26367 D WM-GreedyScheduler: Cancelling work ID ad32dabf
    ------ 0.606s was the duration of 'SYSTEM LOG' ------
    ------ EVENT LOG (logcat -b events -v threadtime -v printable -v uid -d *:v) ------
    --------- beginning of events
    11-10 06:03:21.851  1000   244   244 I auditd  : SELinux: Loaded service context from:
    11-10 06:03:22.002  1000   612   612 I am_proc_start: [0,1038,10196,com.google.android.apps.nexuslauncher,top-activity]
    ------ 0.016s was the duration of 'EVENT LOG' ------
    ------ STATS LOG (logcat -b stats -v threadtime -v printable -v uid -d *:v) ------
    ------ 0.002s was the duration of 'STATS LOG' ------
    ------ RADIO LOG (logcat -b radio -v threadtime -v printable -v uid -d *:v) ------
    --------- beginning of radio
    11-10 06:03:34.594  1000   608   608 D TelephonyRegistry: listen oscl: no callback
    11-10 08:01:31.591 radio  1029  1029 D DN-101-C: ConnectedState: Capabilities not changed.
    ------ 0.018s was the duration of 'RADIO LOG' ------
    ------ LAST LOGCAT (logcat -L -b all -v threadtime -v printable -v uid -d *:v) ------
    *** command 'logcat -L -b all -v threadtime -v printable -v uid -d *:v' failed: exit code 1
    ------ 0.003s was the duration of 'LAST LOGCAT' ------
    ------ SYSTEM PROPERTIES (getprop) ------
    [ro.boot.qemu.avd_name]: [Medium_Phone_API_37.0]
    [ro.build.version.release]: [17]
    [ro.build.version.sdk]: [37]
    [ro.product.manufacturer]: [Google]
    [ro.product.model]: [sdk_gphone64_arm64]
    [ro.serialno]: [EMULATOR37X2X12X0]
    ------ 0.005s was the duration of 'SYSTEM PROPERTIES' ------
    ------ SYSTEM LOG (logcat -v threadtime -v printable -v uid -d *:v -T 2026-11-10 08:01:51.000) ------
    --------- beginning of main
    11-10 08:01:51.178 10196  1038  1038 D Launcher: first line
    11-10 08:01:51.178 10196  1038  1038 D Launcher: second line
    11-10 08:01:51.186 10163 26351 26367 D WM-GreedyScheduler: Cancelling work ID ad32dabf
    11-10 08:02:07.409 shell 32542 32542 D dumpstate: Duration of 'DUMPSTATE': 13.67s
    ------ 0.021s was the duration of 'SYSTEM LOG' ------
    """#

    /// The first five lines of Android Studio's `logcat-firebase.txt`, the first two of its expected messages.
    static let firebase = #"""
    05-16 07:39:26.519: D/AOC(1054): A3:MSG: window_orientation.c, 697: [WO] Proposed rotation: 1, flat angle threshold: 40
    05-16 07:39:26.519: D/AOC(1054): A3:MSG: window_orientation.c, 1105: [WO] orientation angle 89, orientation 1
    05-16 07:39:26.519: D/AOC(1054): A3:MSG: window_orientation.c, 430: [WO] Gyro angle integrated: 0.070911
    05-16 07:39:26.519: D/AOC(1054): A3:MSG: window_orientation.c, 430: [WO] Gyro angle integrated: 0.070911
    05-16 07:39:26.792: W/sh(16446): type=1400 audit(0.0:308): avc: denied { read } for name="cache" dev="dm-7" ino=16 scontext=u:r:shell:s0 tcontext=u:object_r:cache_file:s0 tclass=lnk_file permissive=0
    """#
}

// MARK: Format detection

@Suite struct LogFileFormatTests {
    private func detect(_ text: String, ext: String = "txt") -> LogFileFormat? {
        LogFileFormat.detect(prefix: Data(text.utf8), pathExtension: ext)
    }

    @Test func detectsStudioJSON() {
        #expect(detect("{\n  \"metadata\": {") == .logcatJSON)
        #expect(detect("\u{FEFF}  {") == .logcatJSON)
    }

    @Test func detectsThreadtimeAfterBufferBanner() {
        #expect(detect("--------- beginning of main\n11-09 13:11:17.123  1234  5678 I Tag: m\n") == .threadtime)
        #expect(detect("11-10 06:03:21.874  root   254   254 I vold    : x") == .threadtime)
        #expect(detect("2026-11-10 06:03:21.874  1234  5678 I Tag: x") == .threadtime)
        #expect(detect("1794248132.663  1234  5678 I Tag: x") == .threadtime)
    }

    @Test func detectsBugreportText() {
        let banner = String(repeating: "=", count: 56)
        #expect(detect("\(banner)\n== dumpstate: 2026-11-10 08:01:48\n") == .bugreport)
    }

    @Test func detectsLongFormat() {
        #expect(detect("[ 1794248132.663  1046: 2093: 1697 W/qdgralloc ]\nmsg\n") == .long)
    }

    @Test func detectsFirebaseTimeAndBrief() {
        #expect(detect("11-10 08:01:51.178 D/WM-Processor(26351): okd") == .brief)
        #expect(detect("05-16 07:39:26.519: D/AOC(1054): x") == .brief)
        #expect(detect("W/Tag    ( 1234): hello") == .brief)
    }

    @Test func detectsZipByExtensionOrMagic() {
        #expect(LogFileFormat.detect(prefix: Data("x".utf8), pathExtension: "ZIP") == .bugreportZip)
        #expect(LogFileFormat.detect(prefix: Data([0x50, 0x4B, 3, 4, 0]), pathExtension: "bin") == .bugreportZip)
    }

    @Test func looksPastBlankAndJunkLines() {
        #expect(detect("\n\nsome header\n11-09 13:11:17.123  1  2 I Tag: m") == .threadtime)
    }

    @Test func rejectsTextThatIsNotALog() {
        #expect(detect("hello\nworld\n") == nil)
        let junk = String(repeating: "junk\n", count: 11)
        #expect(detect(junk + "11-09 13:11:17.123  1  2 I Tag: m") == nil)
    }

    @Test func detectsTextInMemory() {
        #expect(LogFileFormat.detect(text: "[ 1794248132.663  1046: 2093: 1697 W/qdgralloc ]\nmsg\n") == .long)
        #expect(LogFileFormat.detect(text: "hello") == nil)
    }
}

// MARK: -v brief, -v time and Firebase

@Suite struct BriefFormatTests {
    let reference = Date(timeIntervalSince1970: LogcatTime.parse(date: "2023-06-01", time: "00:00:00.000")!)

    @Test func parsesFirebaseLine() throws {
        let line = #"05-16 07:39:26.792: W/sh(16446): type=1400 audit(0.0:308): avc: denied { read } for name="cache" dev="dm-7" ino=16 scontext=u:r:shell:s0 tcontext=u:object_r:cache_file:s0 tclass=lnk_file permissive=0"#
        let entry = try #require(LogcatBriefFormat.parseLine(line, referenceDate: reference))
        #expect(entry.level == .warn)
        #expect(entry.tag == "sh")
        #expect(entry.pid == 16446)
        #expect(entry.tid == 0)
        #expect(entry.message == #"type=1400 audit(0.0:308): avc: denied { read } for name="cache" dev="dm-7" ino=16 scontext=u:r:shell:s0 tcontext=u:object_r:cache_file:s0 tclass=lnk_file permissive=0"#)
        #expect(entry.timestamp == LogcatTime.parse(date: "2023-05-16", time: "07:39:26.792"))
    }

    @Test func mergesFirebaseRecordsLikeStudio() throws {
        let entries = LogcatBriefFormat.parse(LogFileFixtures.firebase, referenceDate: reference)
        #expect(entries.count == 2)
        let first = try #require(entries.first)
        #expect(first.tag == "AOC")
        #expect(first.pid == 1054)
        #expect(first.level == .debug)
        #expect(first.message == "A3:MSG: window_orientation.c, 697: [WO] Proposed rotation: 1, flat angle threshold: 40\nA3:MSG: window_orientation.c, 1105: [WO] orientation angle 89, orientation 1\nA3:MSG: window_orientation.c, 430: [WO] Gyro angle integrated: 0.070911\nA3:MSG: window_orientation.c, 430: [WO] Gyro angle integrated: 0.070911")
        #expect(entries[1].tag == "sh")
        #expect(entries[1].pid == 16446)
    }

    @Test func parsesTimeFormatWithPaddedPid() throws {
        let entry = try #require(LogcatBriefFormat.parseLine(
            "11-10 08:01:51.178 I/ActivityManager(  612): Start proc 4321:com.example/u0a123", referenceDate: reference
        ))
        #expect(entry.tag == "ActivityManager")
        #expect(entry.pid == 612)
        #expect(entry.message == "Start proc 4321:com.example/u0a123")
    }

    @Test func tagMayContainParentheses() throws {
        let entry = try #require(LogcatBriefFormat.parseLine("05-16 07:39:26.519: D/Foo(bar)(1054): x", referenceDate: reference))
        #expect(entry.tag == "Foo(bar)")
        #expect(entry.pid == 1054)
        #expect(entry.message == "x")
    }

    @Test func briefWithoutTimeUsesReferenceDate() throws {
        let entry = try #require(LogcatBriefFormat.parseLine("W/Tag    ( 1234): hello", referenceDate: reference))
        #expect(entry.tag == "Tag")
        #expect(entry.pid == 1234)
        #expect(entry.message == "hello")
        #expect(entry.timestamp == reference.timeIntervalSince1970)
    }

    @Test func emptyMessage() throws {
        let entry = try #require(LogcatBriefFormat.parseLine("D/Tag( 12):", referenceDate: reference))
        #expect(entry.tag == "Tag")
        #expect(entry.pid == 12)
        #expect(entry.message.isEmpty)
    }

    @Test func rejectsOtherFormats() {
        #expect(LogcatBriefFormat.parseLine("11-09 13:11:17.123  1234  5678 I Tag: m", referenceDate: reference) == nil)
        #expect(LogcatBriefFormat.parseLine("[ 1.000  1: 2 I/Tag ]", referenceDate: reference) == nil)
        #expect(LogcatBriefFormat.parseLine("hello", referenceDate: reference) == nil)
    }
}

@Suite struct BriefImportTests {
    let reference = Date(timeIntervalSince1970: LogcatTime.parse(date: "2023-06-01", time: "00:00:00.000")!)

    @Test func linesWithoutATimeStayApart() {
        let entries = LogcatBriefFormat.parse("D/Tag( 12): a\nD/Tag( 12): b\nW/Other( 12): c\n", referenceDate: reference)
        #expect(entries.map(\.message) == ["a", "b", "c"])
    }

    @Test func importerReadsBriefAndTime() {
        let text = "11-10 08:01:51.178 D/Tag(  12): a\n11-10 08:01:51.178 D/Tag(  12): b\n"
        let entries = LogFileImporter.parse(text, referenceDate: reference)
        #expect(entries.count == 1)
        #expect(entries.first?.message == "a\nb")
    }
}

@Suite struct LineSplitterTests {
    @Test func joinsLinesAndCharactersCutByChunks() {
        var splitter = LineSplitter()
        var lines: [String] = []
        let bytes = Array("héllo\r\nwörld\nlast".utf8)
        for chunk in stride(from: 0, to: bytes.count, by: 3) {
            splitter.feed(Data(bytes[chunk..<min(bytes.count, chunk + 3)])) { lines.append($0) }
        }
        splitter.finish { lines.append($0) }
        #expect(lines == ["héllo", "wörld", "last"])
    }

    @Test func recordMergerJoinsSameHeader() {
        var merger = RecordMerger()
        let a = LogEntry(timestamp: 1, pid: 1, tid: 1, level: .info, tag: "T", message: "a")
        var b = a
        b.message = "b"
        var c = a
        c.timestamp = 2
        #expect(merger.add(a) == nil)
        #expect(merger.add(b) == nil)
        #expect(merger.add(c)?.message == "a\nb")
        #expect(merger.flush()?.timestamp == 2)
        #expect(merger.flush() == nil)
    }
}

// MARK: Android Studio .logcat files

@Suite struct LogcatFileReadTests {
    private func decode(_ json: String) throws -> (metadata: LogcatFileMetadata?, entries: [LogEntry]) {
        try LogcatFile.decode(Data(json.utf8))
    }

    private func message(
        level: String = "INFO", pid: Int = 42, applicationId: String, processName: String, seconds: Int = 1_794_248_132
    ) -> String {
        """
        {"logcatMessages":[{"header":{"logLevel":"\(level)","pid":\(pid),"tid":\(pid),"applicationId":"\(applicationId)",\
        "processName":"\(processName)","tag":"T","timestamp":{"seconds":\(seconds),"nanos":0}},"message":"m"}]}
        """
    }

    @Test func readsCurrentStudioFormat() throws {
        let (metadata, entries) = try decode(LogFileFixtures.studioCurrent)
        #expect(entries.count == 3)
        #expect(entries.map(\.level) == [.info, .warn, .assert])
        #expect(entries.map(\.processName) == [nil, "com.example.app:remote", "com.google.android.gms.persistent"])
        #expect(LogEntry.packageName(forProcess: try #require(entries[1].processName)) == "com.example.app")
        #expect(entries[1].message == "timeout=30s <retrying>\n\tat com.example.Net.call(Net.kt:12)")
        #expect(LogcatTime.milliseconds(entries[1].timestamp) == 1_794_248_132_663)
        #expect(LogcatTime.milliseconds(entries[2].timestamp) == 1_794_248_133_001)
        #expect(entries[1].pid == 4321)
        #expect(entries[1].tid == 4330)
        #expect(entries[1].uid == nil)
        #expect(entries[1].tag == "Net")

        let meta = try #require(metadata)
        #expect(meta.filter == "package:mine level:WARN")
        #expect(meta.projectApplicationIds == ["com.example.app"])
        let device = try #require(meta.device)
        #expect(device.kind == .physical)
        #expect(device.serialNumber == "35930112X")
        #expect(device.release == "14")
        #expect(device.apiLevel == 34)
        #expect(device.displayName == "Google Pixel 8")
        #expect(LogFileInfo(device: device).summary == "Google Pixel 8 · Android 14, API 34")
    }

    @Test func readsEmulatorDevice() throws {
        let json = #"{"metadata":{"device":{"emulatorDevice":{"deviceId":{"pluginId":"LocalEmulator","isTemplate":false,"identifier":"path=/Users/me/.android/avd/Medium_Phone_API_37.0.avd"},"serialNumber":"emulator-5554","isOnline":true,"release":"17","apiLevel":{"majorVersion":37,"minorVersion":0},"featureLevel":37,"avdName":"Medium_Phone_API_37.0","avdPath":"/Users/me/.android/avd/Medium_Phone_API_37.0.avd","type":"HANDHELD"}},"filter":"","projectApplicationIds":[]},"logcatMessages":[]}"#
        let device = try #require(try decode(json).metadata?.device)
        #expect(device.kind == .emulator)
        #expect(device.displayName == "Medium_Phone_API_37.0")
        #expect(device.avdName == "Medium_Phone_API_37.0")
        #expect(device.apiLevel == 37)
        #expect(LogFileInfo(device: device).deviceName == "Medium Phone API 37.0")
    }

    @Test func readsFlatDeviceFromStudio2024() throws {
        let json = #"{"metadata":{"device":{"deviceId":"emulator-5554","name":"Pixel 8 API 34","serialNumber":"emulator-5554","isOnline":true,"release":"14","sdk":34,"featureLevel":34,"model":"Pixel 8","type":"HANDHELD","isEmulator":true},"filter":"tag:Foo","projectApplicationIds":["a.b"]},"logcatMessages":[]}"#
        let meta = try #require(try decode(json).metadata)
        let device = try #require(meta.device)
        #expect(device.kind == .emulator)
        #expect(device.displayName == "Pixel 8 API 34")
        #expect(device.apiLevel == 34)
        #expect(meta.filter == "tag:Foo")

        let numericRelease = json.replacingOccurrences(of: #""release":"14""#, with: #""release":13"#)
        #expect(try decode(numericRelease).metadata?.device?.release == "13")
    }

    @Test func readsFileWithoutMetadata() throws {
        let (metadata, entries) = try decode(message(applicationId: "a.b", processName: "a.b"))
        #expect(metadata == nil)
        #expect(entries.count == 1)
        #expect(entries.first?.processName == "a.b")
    }

    @Test func placeholderProcessFallsBackToApplicationId() throws {
        #expect(try decode(message(applicationId: "com.foo", processName: "pid-42")).entries.first?.processName == "com.foo")
        #expect(try decode(message(applicationId: "pid-42", processName: "pid-42")).entries.first?.processName == nil)
        #expect(try decode(message(applicationId: "", processName: "")).entries.first?.processName == nil)
        #expect(try decode(message(pid: 0, applicationId: "kernel", processName: "kernel")).entries.first?.processName == "kernel")
        #expect(try decode(message(applicationId: "com.foo", processName: "kernel")).entries.first?.processName == "kernel")
    }

    @Test func ignoresUnknownKeys() throws {
        let json = #"{"metadata":{"filter":"","projectApplicationIds":[],"ignoredTags":["x"]},"logcatMessages":[{"header":{"logLevel":"DEBUG","pid":1,"tid":2,"applicationId":"a","processName":"a","tag":"T","uid":"10123","timestamp":{"seconds":5,"nanos":6}},"message":"hi"}]}"#
        let (metadata, entries) = try decode(json)
        #expect(metadata?.filter == "")
        #expect(entries.count == 1)
        #expect(entries.first?.level == .debug)
    }

    @Test func importerReadsStudioJSON() {
        let entries = LogFileImporter.parse(LogFileFixtures.studioCurrent)
        #expect(entries.count == 3)
        #expect(entries[1].processName == "com.example.app:remote")
    }

    @Test func rejectsMalformedJSON() {
        #expect(throws: (any Error).self) { try LogcatFile.decode(Data("{".utf8)) }
    }
}

/// A port of Android Studio's LogcatFileDataTest for `safeGetFilter`, with its exact expected strings.
@Suite struct StudioFilterTests {
    private func filter(_ filter: String, _ ids: [String], my: Set<String>) -> String {
        LogcatFileMetadata(device: nil, filter: filter, projectApplicationIds: ids).filter(forMyPackages: my)
    }

    @Test func noMine() {
        #expect(filter("package:foo tag:Foo", ["package1"], my: []) == "package:foo tag:Foo")
    }

    @Test func mineWithSingleProjectPackage() {
        #expect(filter("package:mine", ["package1"], my: []) == "package:package1")
    }

    @Test func mineWithSinglePackageAndMoreTerms() {
        #expect(filter("foo package:mine tag:Bar", ["package1"], my: []) == "foo package:package1 tag:Bar")
    }

    @Test func mineWithMultiplePackages() {
        #expect(filter("package:mine", ["package1", "package2"], my: []) == "package:package1 package:package2")
    }

    @Test func mineWithMultiplePackagesAndMoreTerms() {
        #expect(filter("foo package:mine tag:Bar", ["package1", "package2"], my: [])
            == "foo (package:package1 | package:package2) tag:Bar")
    }

    @Test func mineWithoutProjectPackages() {
        #expect(filter("foo package:mine tag:Bar", [], my: []) == "foo  tag:Bar")
    }

    @Test func mineMatchingMyPackages() {
        #expect(filter("foo package:mine tag:Bar", ["package1", "package2"], my: ["package2", "package1"])
            == "foo package:mine tag:Bar")
    }
}

// MARK: Bug reports

@Suite struct BugreportParserTests {
    let fallback = Date(timeIntervalSince1970: LogcatTime.parse(date: "2030-01-01", time: "00:00:00.000")!)

    private func parse(_ text: String = LogFileFixtures.bugreport) -> (
        entries: [LogFileSection: [LogEntry]], info: LogFileInfo, processNames: [Int32: String]
    ) {
        BugreportParser.parse(text, fallbackReference: fallback)
    }

    @Test func splitsLogSections() {
        let result = parse()
        let main = result.entries[.main] ?? []
        #expect(main.map(\.tag) == ["vold", "vold", "Launcher", "WM-GreedyScheduler", "dumpstate"])
        #expect(main[2].message == "first line\nsecond line")
        let events = result.entries[.events] ?? []
        #expect(events.map(\.tag) == ["auditd", "am_proc_start"])
        let radio = result.entries[.radio] ?? []
        #expect(radio.map(\.tag) == ["TelephonyRegistry", "DN-101-C"])
    }

    @Test func readsUidColumn() throws {
        let main = try #require(parse().entries[.main])
        #expect(main[0].uid == "root")
        #expect(main[0].pid == 254)
        #expect(main[0].tid == 254)
        #expect(main[0].level == .info)
        #expect(main[4].uid == "shell")
        #expect(main[3].uid == "10163")
    }

    @Test func readsHeaderAndProperties() {
        let info = parse().info
        #expect(info.fingerprint == "google/sdk_gphone64_arm64/emu64a:17/CE2A.260420.051.A2/16418371:user/release-keys")
        #expect(info.build == "CE2A.260420.051.A2")
        #expect(info.deviceName == "Medium Phone API 37.0")
        #expect(info.release == "17")
        #expect(info.apiLevel == 37)
        #expect(info.serial == "EMULATOR37X2X12X0")
        #expect(info.capturedAt?.timeIntervalSince1970 == LogcatTime.parse(date: "2026-11-10", time: "08:01:48.000"))
        #expect(info.summary.hasPrefix("Medium Phone API 37.0 · Android 17, API 37 · google/"))
    }

    @Test func takesYearFromDumpstateTime() throws {
        let main = try #require(parse().entries[.main])
        #expect(LogcatTime.milliseconds(main[0].timestamp)
            == LogcatTime.milliseconds(LogcatTime.parse(date: "2026-11-10", time: "06:03:21.874")!))

        let newYear = """
        ========================================================
        == dumpstate: 2027-01-02 00:10:00
        ========================================================
        ------ SYSTEM LOG (logcat -v threadtime -d *:v) ------
        12-31 23:59:00.000  1000  1  1 I Tag: x
        ------ 0.1s was the duration of 'SYSTEM LOG' ------
        """
        let entry = try #require(parse(newYear).entries[.main]?.first)
        #expect(entry.timestamp == LogcatTime.parse(date: "2026-12-31", time: "23:59:00.000"))
    }

    @Test func collectsProcessNamesFromDumpsys() {
        #expect(parse().processNames == [1038: "com.google.android.apps.nexuslauncher"])
    }

    @Test func readsOldBugreportWithoutUidOrEndLines() {
        let text = """
        ------ SYSTEM LOG (logcat -v threadtime -d *:v) ------
        11-09 13:11:17.123  1234  5678 I Tag: one
        11-09 13:11:17.124  1234  5678 I Tag: two
        ------ EVENT LOG (logcat -b events -v threadtime -d *:v) ------
        11-09 13:11:17.125  1234  5678 I am_x: [1]
        """
        let result = parse(text)
        #expect(result.entries[.main]?.count == 2)
        #expect(result.entries[.events]?.count == 1)
    }

    @Test func doesNotMergeAcrossSections() {
        let text = """
        ------ SYSTEM LOG (logcat -v threadtime -d *:v) ------
        11-09 13:11:17.123  1234  5678 I Tag: same
        ------ 0.1s was the duration of 'SYSTEM LOG' ------
        ------ RADIO LOG (logcat -b radio -v threadtime -d *:v) ------
        11-09 13:11:17.123  1234  5678 I Tag: same
        ------ 0.1s was the duration of 'RADIO LOG' ------
        """
        let result = parse(text)
        #expect(result.entries[.main]?.map(\.message) == ["same"])
        #expect(result.entries[.radio]?.map(\.message) == ["same"])
    }

    @Test func importerReadsTheSystemLogOfABugreport() {
        let entries = LogFileImporter.parse(LogFileFixtures.bugreport)
        #expect(entries.map(\.tag) == ["vold", "vold", "Launcher", "WM-GreedyScheduler", "dumpstate"])
    }

    @Test func dropsTheRepeatedSystemLogButKeepsLaterEntries() throws {
        // The fixture's second SYSTEM LOG repeats three entries and adds the dumpstate line.
        let main = try #require(parse().entries[.main])
        #expect(main.filter { $0.tag == "Launcher" }.count == 1)
        #expect(main.filter { $0.tag == "WM-GreedyScheduler" }.count == 1)
    }
}

// MARK: Chunked reading

/// Collects what a read hands over. An actor, because the handler is `@Sendable` and may run on any thread.
private actor EventBox {
    private(set) var events: [LogFileEvent] = []

    func append(_ event: LogFileEvent) { events.append(event) }

    var entryCount: Int {
        events.reduce(0) { total, event in
            if case let .entries(batch, _) = event { total + batch.count } else { total }
        }
    }
}

private func entries(in events: [LogFileEvent], section: LogFileSection = .main) -> [LogEntry] {
    events.flatMap { event -> [LogEntry] in
        if case let .entries(batch, eventSection) = event, eventSection == section { batch } else { [] }
    }
}

private func progressFractions(in events: [LogFileEvent]) -> [Double?] {
    events.compactMap { event in
        if case let .progress(progress) = event, progress.phase == .reading { progress.fraction } else { nil }
    }
}

@Suite(.serialized) struct LogFileReaderTests {
    /// A scratch directory that goes away with the test.
    private final class Scratch {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("logcatnip-tests-\(UUID().uuidString)")

        init() throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: url) }

        func write(_ name: String, _ text: String) throws -> URL {
            let file = url.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
            return file
        }
    }

    private func collect(_ url: URL, reader: LogFileReader = LogFileReader()) async throws -> [LogFileEvent] {
        let box = EventBox()
        try await reader.read(url) { await box.append($0) }
        return await box.events
    }

    /// One distinct pid per line, so that no two lines merge into one record.
    private func threadtimeLines(_ count: Int) -> String {
        (0..<count).map { index in
            String(
                format: "11-09 13:%02ld:%02ld.%03ld  %5ld  %5ld I Tag: line %ld",
                (index / 60_000) % 60, (index / 1000) % 60, index % 1000, index + 1000, index + 1000, index
            )
        }.joined(separator: "\n") + "\n"
    }

    @Test func streamsInBatchesWithProgress() async throws {
        let scratch = try Scratch()
        let file = try scratch.write("big.txt", threadtimeLines(30_000))
        let modified = Date(timeIntervalSince1970: LogcatTime.parse(date: "2027-01-05", time: "12:00:00.000")!)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)

        var reader = LogFileReader()
        reader.chunkSize = 64 * 1024
        reader.batchSize = 1_000
        let events = try await collect(file, reader: reader)

        guard case .format(.threadtime) = try #require(events.first) else {
            Issue.record("the first event should be the format")
            return
        }
        let batches = events.compactMap { event -> Int? in
            if case let .entries(batch, _) = event { batch.count } else { nil }
        }
        #expect(batches.reduce(0, +) == 30_000)
        #expect(batches.count >= 30)
        #expect(batches.allSatisfy { $0 <= 1_000 })

        let fractions = progressFractions(in: events).compactMap { $0 }
        #expect(fractions == fractions.sorted())
        #expect(try #require(fractions.first) < 0.1)
        #expect(fractions.last == 1.0)

        let first = try #require(entries(in: events).first)
        #expect(first.timestamp == LogcatTime.parse(date: "2026-11-09", time: "13:00:00.000"))
    }

    @Test func joinsLinesSplitAcrossChunks() async throws {
        let scratch = try Scratch()
        let text = "11-09 13:11:17.123  1234  1234 E AndroidRuntime: FATAL é 日本\r\n"
            + "11-09 13:11:17.123  1234  1234 E AndroidRuntime: \tat a.B.c(B.kt:1)\r\n"
            + "11-09 13:11:17.124  1  1 I Other: next"
        let file = try scratch.write("crash.txt", text)
        var reader = LogFileReader()
        reader.chunkSize = 7
        let found = entries(in: try await collect(file, reader: reader))
        #expect(found.count == 2)
        #expect(found.first?.message == "FATAL é 日本\n\tat a.B.c(B.kt:1)")
        #expect(found.last?.message == "next")
    }

    @Test func cancellationStopsReading() async throws {
        let scratch = try Scratch()
        let file = try scratch.write("huge.txt", threadtimeLines(200_000))
        var reader = LogFileReader()
        reader.chunkSize = 4096
        reader.batchSize = 100
        let box = EventBox()
        let task = Task {
            try await reader.read(file) { event in
                await box.append(event)
                if case .entries = event { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(await box.entryCount < 200_000)
    }

    @Test func readsStudioJSONFile() async throws {
        let scratch = try Scratch()
        let file = try scratch.write("x.logcat", LogFileFixtures.studioCurrent)
        let events = try await collect(file)
        guard case .format(.logcatJSON) = try #require(events.first) else {
            Issue.record("the first event should be the format")
            return
        }
        let metadataIndex = try #require(events.firstIndex { if case .metadata = $0 { true } else { false } })
        let firstEntries = try #require(events.firstIndex { if case .entries = $0 { true } else { false } })
        #expect(metadataIndex < firstEntries)
        #expect(entries(in: events).count == 3)
        #expect(progressFractions(in: events).last == 1.0)
    }

    @Test func readsBugreportText() async throws {
        let scratch = try Scratch()
        let file = try scratch.write("bugreport-x.txt", LogFileFixtures.bugreport)
        let events = try await collect(file)
        expectBugreport(events)
    }

    private func expectBugreport(_ events: [LogFileEvent]) {
        #expect(entries(in: events, section: .main).count == 5)
        #expect(entries(in: events, section: .events).count == 2)
        #expect(entries(in: events, section: .radio).count == 2)
        let lastEntries = events.lastIndex { if case .entries = $0 { true } else { false } }
        let info = events.firstIndex { if case .info = $0 { true } else { false } }
        let names = events.firstIndex { if case .processNames = $0 { true } else { false } }
        #expect((info ?? -1) > (lastEntries ?? .max))
        #expect((names ?? -1) > (lastEntries ?? .max))
        if let info, case let .info(value) = events[info] {
            #expect(value.deviceName == "Medium Phone API 37.0")
        }
    }

    private func makeZip(_ scratch: Scratch, report: String? = LogFileFixtures.bugreport, mainEntry: String? = "bugreport-sdk-2026-11-10.txt") throws -> URL {
        var names = ["version.txt", "FS"]
        _ = try scratch.write("version.txt", "2.0")
        _ = try scratch.write("FS/proc/1/mountinfo", "x")
        if let report {
            _ = try scratch.write("bugreport-sdk-2026-11-10.txt", report)
            names.append("bugreport-sdk-2026-11-10.txt")
        }
        if let mainEntry {
            _ = try scratch.write("main_entry.txt", mainEntry)
            names.append("main_entry.txt")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", "report.zip"] + names
        process.currentDirectoryURL = scratch.url
        try process.run()
        process.waitUntilExit()
        return scratch.url.appendingPathComponent("report.zip")
    }

    private func extractionDirectories() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return names.filter { $0.hasPrefix("Logcatnip-") }.count
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/zip")))
    func readsBugreportZip() async throws {
        let scratch = try Scratch()
        let archive = try makeZip(scratch)
        let before = extractionDirectories()
        let events = try await collect(archive)
        guard case .format(.bugreportZip) = try #require(events.first) else {
            Issue.record("the first event should be the format")
            return
        }
        #expect(events.contains { if case let .progress(p) = $0 { p.phase == .extracting } else { false } })
        expectBugreport(events)
        #expect(extractionDirectories() == before)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/zip")))
    func zipWithoutMainEntryUsesBugreportName() async throws {
        let scratch = try Scratch()
        let archive = try makeZip(scratch, mainEntry: nil)
        expectBugreport(try await collect(archive))
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/zip")))
    func zipWithoutBugreportThrows() async throws {
        let scratch = try Scratch()
        let archive = try makeZip(scratch, report: nil, mainEntry: nil)
        await #expect(throws: LogFileError.noBugreport("report.zip")) { try await collect(archive) }
    }

    @Test func unrecognizedFileThrows() async throws {
        let scratch = try Scratch()
        let file = try scratch.write("x.txt", "hello\nworld\n")
        await #expect(throws: LogFileError.unrecognized("x.txt")) { try await collect(file) }
    }
}
