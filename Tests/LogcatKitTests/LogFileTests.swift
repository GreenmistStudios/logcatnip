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
