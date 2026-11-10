import Foundation
import Testing
@testable import LogcatKit

// Tests for saving logs: Android Studio's `.logcat` JSON, the device it describes, and the text formats.
//
// The `.logcat` goldens below were written by Android Studio itself: Android Studio 2026.2
// (AI-262.10968.63.2622.16730706), `LogcatFileIo().writeLogcat(path, messages, device, filter, projectApplicationIds)`
// called from a small Java program on the IDE's own class path. They pin Gson's exact output: pretty printing,
// HTML-safe escapes (\u003d, \u003c, \u0027 …), lowercase \u00XX for control characters, raw DEL and non-ASCII,
// field order, and no trailing newline.

private let utc = TimeZone(identifier: "UTC")!

/// Milliseconds since 1970 as the seconds a `LogEntry` stores.
private func at(_ milliseconds: Int64) -> Double { Double(milliseconds) / 1000 }

/// A scratch directory that goes away with the test.
private final class SaveScratch {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("logcatnip-tests-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func folder(_ path: String) throws -> URL {
        let folder = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @discardableResult
    func write(_ path: String, _ text: String) throws -> URL {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: url.appendingPathComponent(path), encoding: .utf8)
    }

    var contents: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }
}

// MARK: Goldens

/// A physical device with six messages: a kernel line, an unknown process, escapes of every kind, HTML-sensitive
/// characters, non-ASCII, and a Google package. `<DEL>` stands for the raw 0x7F byte, which doesn't survive
/// being pasted into a source file.
private let goldenPhone = #"""
{
  "metadata": {
    "device": {
      "physicalDevice": {
        "deviceId": {
          "pluginId": "PhysicalDevice",
          "isTemplate": false,
          "identifier": "serial\u003d35930112X"
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
      "com.example.app",
      "com.example.lib"
    ]
  },
  "logcatMessages": [
    {
      "header": {
        "logLevel": "VERBOSE",
        "pid": 0,
        "tid": 0,
        "applicationId": "kernel",
        "processName": "kernel",
        "tag": "init",
        "timestamp": {
          "seconds": 1794248130,
          "nanos": 0
        }
      },
      "message": "v"
    },
    {
      "header": {
        "logLevel": "DEBUG",
        "pid": 1303,
        "tid": 1303,
        "applicationId": "pid-1303",
        "processName": "pid-1303",
        "tag": "vold",
        "timestamp": {
          "seconds": 1794248131,
          "nanos": 5000000
        }
      },
      "message": ""
    },
    {
      "header": {
        "logLevel": "INFO",
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
      "message": "quote \" backslash \\ tab \t cr \r nl \n esc \u001b del <DEL> bell \u0007 ff \f bs \b"
    },
    {
      "header": {
        "logLevel": "WARN",
        "pid": 4321,
        "tid": 4321,
        "applicationId": "com.example.app",
        "processName": "com.example.app",
        "tag": "Html",
        "timestamp": {
          "seconds": 1794248133,
          "nanos": 1000000
        }
      },
      "message": "\u003ca href\u003d\u0027x\u0027\u003e\u0026amp;\u003c/a\u003e \u003d / \u2028 \u2029"
    },
    {
      "header": {
        "logLevel": "ERROR",
        "pid": 4321,
        "tid": 4321,
        "applicationId": "com.example.app",
        "processName": "com.example.app",
        "tag": "Uni",
        "timestamp": {
          "seconds": 1794248134,
          "nanos": 999000000
        }
      },
      "message": "é 日本 😀 \u0000 \u001f"
    },
    {
      "header": {
        "logLevel": "ASSERT",
        "pid": 5000,
        "tid": 5000,
        "applicationId": "com.google.android.gms.persistent",
        "processName": "com.google.android.gms.persistent",
        "tag": "libc",
        "timestamp": {
          "seconds": 1794248135,
          "nanos": 0
        }
      },
      "message": "Fatal"
    }
  ]
}
"""#.replacingOccurrences(of: "<DEL>", with: "\u{7F}")

/// An emulator with no messages: `[]` is written without a line break.
private let goldenEmulator = #"""
{
  "metadata": {
    "device": {
      "emulatorDevice": {
        "deviceId": {
          "pluginId": "LocalEmulator",
          "isTemplate": false,
          "identifier": "path\u003d/Users/me/.android/avd/Medium_Phone_API_37.0.avd"
        },
        "serialNumber": "emulator-5554",
        "isOnline": false,
        "release": "17",
        "apiLevel": {
          "majorVersion": 37,
          "minorVersion": 0
        },
        "featureLevel": 37,
        "avdName": "Medium_Phone_API_37.0",
        "avdPath": "/Users/me/.android/avd/Medium_Phone_API_37.0.avd",
        "type": "HANDHELD"
      }
    },
    "filter": "",
    "projectApplicationIds": []
  },
  "logcatMessages": []
}
"""#

private let phoneDevice = LogcatFileDevice(
    kind: .physical, serialNumber: "35930112X", isOnline: true, release: "14", apiLevel: 34, apiMinorLevel: 0,
    featureLevel: 34, manufacturer: "Google", model: "Pixel 8", deviceId: "serial=35930112X", type: "HANDHELD"
)

private let emulatorDevice = LogcatFileDevice(
    kind: .emulator, serialNumber: "emulator-5554", isOnline: false, release: "17", apiLevel: 37, apiMinorLevel: 0,
    featureLevel: 37, avdName: "Medium_Phone_API_37.0", avdPath: "/Users/me/.android/avd/Medium_Phone_API_37.0.avd",
    deviceId: "path=/Users/me/.android/avd/Medium_Phone_API_37.0.avd", type: "HANDHELD"
)

/// Mirrors `Golden.java`: the six messages Android Studio wrote into `goldenPhone`.
private func goldenEntries() -> [LogEntry] {
    func make(
        _ pid: Int32, _ tid: Int32, _ level: LogLevel, _ tag: String, _ milliseconds: Int64, _ message: String,
        _ process: String?
    ) -> LogEntry {
        LogEntry(timestamp: at(milliseconds), pid: pid, tid: tid, level: level, tag: tag, message: message, processName: process)
    }
    return [
        make(0, 0, .verbose, "init", 1_794_248_130_000, "v", nil),
        make(1303, 1303, .debug, "vold", 1_794_248_131_005, "", nil),
        make(4321, 4330, .info, "Net", 1_794_248_132_663,
             "quote \" backslash \\ tab \t cr \r nl \n esc \u{1B} del \u{7F} bell \u{07} ff \u{0C} bs \u{08}",
             "com.example.app:remote"),
        make(4321, 4321, .warn, "Html", 1_794_248_133_001, "<a href='x'>&amp;</a> = / \u{2028} \u{2029}", nil),
        make(4321, 4321, .error, "Uni", 1_794_248_134_999, "é 日本 😀 \u{0} \u{1F}", "com.example.app"),
        make(5000, 5000, .assert, "libc", 1_794_248_135_000, "Fatal", "com.google.android.gms.persistent"),
    ]
}

/// Where two texts first differ, so that a failing golden comparison says more than "not equal".
private func firstDifference(_ actual: String, _ expected: String) -> String {
    let a = Array(actual.unicodeScalars)
    let e = Array(expected.unicodeScalars)
    guard let index = (0..<min(a.count, e.count)).first(where: { a[$0] != e[$0] }) else {
        return "one is a prefix of the other (\(a.count) vs \(e.count) scalars)"
    }
    func excerpt(_ scalars: [Unicode.Scalar]) -> String {
        String(String.UnicodeScalarView(scalars[max(0, index - 20)..<min(scalars.count, index + 20)]))
    }
    return "scalar \(index): actual …\(excerpt(a))… expected …\(excerpt(e))…"
}

// MARK: .logcat writer

@Suite struct LogcatFileWriterTests {
    @Test func matchesStudioGsonOutputForPhone() {
        let metadata = LogcatFileMetadata(
            device: phoneDevice, filter: "package:mine level:WARN",
            projectApplicationIds: ["com.example.app", "com.example.lib"]
        )
        let actual = LogcatFileWriter.encode(
            metadata: metadata, entries: goldenEntries(), processNames: [4321: "com.example.app"]
        )
        #expect(actual == goldenPhone, "\(firstDifference(actual, goldenPhone))")
    }

    @Test func matchesStudioGsonOutputForEmulator() {
        let metadata = LogcatFileMetadata(device: emulatorDevice, filter: "", projectApplicationIds: [])
        let actual = LogcatFileWriter.encode(metadata: metadata, entries: [])
        #expect(actual == goldenEmulator, "\(firstDifference(actual, goldenEmulator))")
    }

    @Test func readsStudioGoldenFile() throws {
        let (metadata, entries) = try LogcatFile.decode(Data(goldenPhone.utf8))
        #expect(try #require(metadata).device == phoneDevice)
        #expect(entries.count == 6)
        #expect(entries.map(\.level) == [.verbose, .debug, .info, .warn, .error, .assert])
        #expect(entries.map(\.processName) == [
            "kernel", nil, "com.example.app:remote", "com.example.app", "com.example.app",
            "com.google.android.gms.persistent",
        ])
        #expect(entries[2].message == goldenEntries()[2].message)
        #expect(entries[3].message == goldenEntries()[3].message)
        #expect(entries[4].message == goldenEntries()[4].message)
    }

    @Test func omitsAnUnknownDevice() {
        let metadata = LogcatFileMetadata(device: nil, filter: "tag:Foo", projectApplicationIds: [])
        #expect(
            LogcatFileWriter.encode(metadata: metadata, entries: [])
                == "{\n  \"metadata\": {\n    \"filter\": \"tag:Foo\",\n    \"projectApplicationIds\": []\n  },\n  \"logcatMessages\": []\n}"
        )
    }

    @Test func writesIgnoreListsOnlyWhenPresent() throws {
        let with = LogcatFileMetadata(
            device: nil, filter: "", projectApplicationIds: [], ignoredTags: ["chatty"], ignoredPackages: ["com.noisy"]
        )
        let text = LogcatFileWriter.encode(metadata: with, entries: [])
        #expect(text.contains(
            "\"projectApplicationIds\": [],\n    \"ignoredTags\": [\n      \"chatty\"\n    ],\n"
                + "    \"ignoredPackages\": [\n      \"com.noisy\"\n    ]\n  },"
        ))
        let (decoded, _) = try LogcatFile.decode(Data(text.utf8))
        #expect(try #require(decoded).ignoredTags == ["chatty"])
        #expect(try #require(decoded).ignoredPackages == ["com.noisy"])

        let without = LogcatFileWriter.encode(
            metadata: LogcatFileMetadata(device: nil, filter: "", projectApplicationIds: []), entries: []
        )
        #expect(!without.contains("ignoredTags"))
        #expect(!without.contains("ignoredPackages"))
    }

    @Test func escapesLikeGson() {
        let cases: [(String, String)] = [
            ("plain", "\"plain\""),
            ("a\"b\\c", #""a\"b\\c""#),
            ("\u{0}\u{1F}\u{1B}", #""\u0000\u001f\u001b""#),
            ("\t\n\r\u{8}\u{C}", #""\t\n\r\b\f""#),
            ("<>&='", #""\u003c\u003e\u0026\u003d\u0027""#),
            ("\u{2028}\u{2029}", #""\u2028\u2029""#),
            ("\u{7F}/é😀", "\"\u{7F}/é😀\""),
        ]
        for (text, expected) in cases {
            #expect(LogcatFileWriter.quoted(text) == expected)
        }
    }

    @Test func reencodesStudioFixtureLosslessly() throws {
        let (metadata, entries) = try LogcatFile.decode(Data(LogFileFixtures.studioCurrent.utf8))
        let first = try #require(metadata)
        let again = try LogcatFile.decode(Data(LogcatFileWriter.encode(metadata: first, entries: entries).utf8))
        #expect(again.metadata == first)
        #expect(again.entries.count == entries.count)
        for (before, after) in zip(entries, again.entries) {
            #expect(LogcatTime.milliseconds(after.timestamp) == LogcatTime.milliseconds(before.timestamp))
            #expect(after.pid == before.pid)
            #expect(after.tid == before.tid)
            #expect(after.level == before.level)
            #expect(after.tag == before.tag)
            #expect(after.message == before.message)
            // The gms entry's `applicationId` is `com.google.android.gms` in the fixture and becomes the process name
            // here, because Logcatnip derives the package from the process name; keeping `applicationId` needs a
            // LogEntry field (a follow-up). Process names, which the Package column and filters use, survive.
            #expect(after.processName == before.processName)
        }
    }
}

// MARK: Device description

@Suite struct LogcatFileDeviceTests {
    private func phoneProperties() -> DeviceProperties {
        DeviceProperties(values: [
            "ro.product.manufacturer": "Google", "ro.product.model": "Pixel 8", "ro.build.version.release": "14",
            "ro.build.version.sdk": "34", "ro.build.version.codename": "REL",
        ])
    }

    @Test func describesAPhone() {
        let device = LogcatFileDevice(properties: phoneProperties(), serial: "35930112X", isOnline: true, avdPath: nil)
        #expect(device == phoneDevice)
        #expect(device.displayName == "Google Pixel 8")

        let metadata = LogcatFileMetadata(
            device: device, filter: "package:mine level:WARN", projectApplicationIds: ["com.example.app", "com.example.lib"]
        )
        let text = LogcatFileWriter.encode(metadata: metadata, entries: [])
        func deviceBlock(_ text: String) -> Substring {
            let start = text.range(of: "\"device\": {")!.lowerBound
            let end = text.range(of: "\"filter\"")!.lowerBound
            return text[start..<end]
        }
        #expect(deviceBlock(text) == deviceBlock(goldenPhone))
    }

    @Test func describesAnEmulator() throws {
        let properties = DeviceProperties(values: [
            "ro.boot.qemu.avd_name": "Medium_Phone_API_37.0", "ro.build.version.release": "17",
            "ro.build.version.sdk": "37", "ro.build.version.sdk_full": "37.0", "ro.product.model": "sdk_gphone64_arm64",
            "ro.product.manufacturer": "Google",
        ])
        let device = LogcatFileDevice(properties: properties, serial: "emulator-5554", isOnline: true, avdPath: "/a/Medium_Phone.avd")
        #expect(device.kind == .emulator)
        #expect(device.avdName == "Medium_Phone_API_37.0")
        #expect(device.avdPath == "/a/Medium_Phone.avd")
        #expect(device.deviceId == "path=/a/Medium_Phone.avd")
        #expect(device.apiLevel == 37)
        #expect(device.apiMinorLevel == 0)
        #expect(device.manufacturer == nil)
        #expect(device.model == nil)
        #expect(device.displayName == "Medium_Phone_API_37.0")
    }

    @Test func normalizesVersionsAndTypes() {
        #expect(LogcatFileDevice.normalizedRelease("14.0") == "14")
        #expect(LogcatFileDevice.normalizedRelease("8.1.0") == "8.1")
        #expect(LogcatFileDevice.normalizedRelease("16") == "16")
        #expect(LogcatFileDevice.normalizedRelease("10.0.0") == "10")

        func device(_ extra: [String: String]) -> LogcatFileDevice {
            var values = ["ro.build.version.sdk": "35"]
            values.merge(extra) { _, new in new }
            return LogcatFileDevice(properties: DeviceProperties(values: values), serial: "s", isOnline: true, avdPath: nil)
        }
        #expect(device(["ro.build.version.codename": "Baklava"]).featureLevel == 36)
        #expect(device(["ro.build.version.codename": "REL"]).featureLevel == 35)
        #expect(device([:]).featureLevel == 35)
        #expect(device(["ro.build.version.sdk_full": "36.1"]).apiMinorLevel == 1)
        #expect(device(["ro.build.characteristics": "nosdcard,watch"]).type == "WEAR")
        #expect(device(["ro.build.characteristics": "tv"]).type == "TV")
        #expect(device(["ro.build.characteristics": "automotive"]).type == "AUTOMOTIVE")
        #expect(device(["ro.build.characteristics": "default"]).type == "HANDHELD")
        #expect(device([:]).type == "HANDHELD")
    }

    @Test func describesABugreportDevice() throws {
        let info = LogFileInfo(deviceName: "Medium Phone API 37.0", release: "17", apiLevel: 37, serial: "EMULATOR37X2X12X0")
        let device = try #require(LogcatFileDevice(info: info))
        #expect(device.kind == .physical)
        #expect(device.model == "Medium Phone API 37.0")
        #expect(device.manufacturer == "")
        #expect(device.serialNumber == "EMULATOR37X2X12X0")
        #expect(device.release == "17")
        #expect(device.apiLevel == 37)
        #expect(device.isOnline == false)
        #expect(LogcatFileDevice(info: LogFileInfo()) == nil)
    }

    @Test func locatesAvdFolders() throws {
        let scratch = try SaveScratch()
        let home = scratch.url.appendingPathComponent("home")
        let avdFolder = try scratch.folder("home/.android/avd/Medium_Phone.avd")
        try scratch.write(
            "home/.android/avd/Medium_Phone_API_37.0.ini",
            "avd.ini.encoding=UTF-8\npath=\(avdFolder.path)\npath.rel=avd/Medium_Phone.avd\n"
        )
        #expect(AvdLocator.path(forAvdName: "Medium_Phone_API_37.0", environment: [:], home: home) == avdFolder.path)

        // `path=` points nowhere, so `path.rel` (relative to the Android user home) is used.
        try scratch.write(
            "home/.android/avd/Pixel_8.ini", "path=\(scratch.url.path)/gone/Pixel_8.avd\npath.rel=avd/Pixel_8.avd\n"
        )
        let relative = try scratch.folder("home/.android/avd/Pixel_8.avd")
        #expect(AvdLocator.path(forAvdName: "Pixel_8", environment: [:], home: home) == relative.path)

        // `ANDROID_AVD_HOME` wins over the default location.
        let elsewhere = try scratch.folder("elsewhere")
        let elsewhereFolder = try scratch.folder("elsewhere/X.avd")
        try scratch.write("elsewhere/X.ini", "path=\(elsewhereFolder.path)\n")
        #expect(AvdLocator.path(forAvdName: "X", environment: ["ANDROID_AVD_HOME": elsewhere.path], home: home) == elsewhereFolder.path)

        #expect(AvdLocator.path(forAvdName: "Unknown", environment: [:], home: home) == nil)
    }
}

// MARK: Text formats

@Suite struct LogTextFormatTests {
    private let time = LogcatTime.parse(date: "2026-11-09", time: "13:11:17.123", timeZone: utc)!

    private func entry(
        pid: Int32 = 1234, tid: Int32 = 5678, tag: String = "Tag", message: String = "m", process: String? = nil
    ) -> LogEntry {
        LogEntry(timestamp: time, pid: pid, tid: tid, level: .info, tag: tag, message: message, processName: process)
    }

    @Test func threadtimeLineLikeLogcat() {
        func format(_ entry: LogEntry) -> String { LogcatThreadtimeFormat.format(entry, timeZone: utc) }
        #expect(format(entry()) == "11-09 13:11:17.123  1234  5678 I Tag     : m\n")
        #expect(format(entry(tag: "ActivityManager")) == "11-09 13:11:17.123  1234  5678 I ActivityManager: m\n")
        #expect(format(entry(pid: 7, tid: 123_456)).contains(" I Tag") && format(entry(pid: 7, tid: 123_456)).contains("    7 123456 I"))
        #expect(
            format(entry(message: "a\n\tb"))
                == "11-09 13:11:17.123  1234  5678 I Tag     : a\n11-09 13:11:17.123  1234  5678 I Tag     : \tb\n"
        )
        #expect(format(entry(message: "")) == "11-09 13:11:17.123  1234  5678 I Tag     : \n")
    }

    @Test func threadtimeReadsBack() throws {
        // A fixed July day, so the test can't straddle a time zone change; the reference date is the next day.
        let base = try #require(LogcatTime.parse(date: "2026-07-15", time: "12:00:00.000"))
        let reference = Date(timeIntervalSince1970: base + 86_400)
        let made = [
            LogEntry(timestamp: base + 1.001, pid: 100, tid: 101, level: .warn, tag: "Net", message: "one\n\ttwo"),
            LogEntry(timestamp: base + 2.5, pid: 200, tid: 201, level: .error, tag: "Quiet", message: ""),
            LogEntry(timestamp: base + 3.999, pid: 300, tid: 300, level: .debug, tag: "My Tag", message: "spaced"),
            LogEntry(timestamp: base + 4, pid: 40_000, tid: 123_456, level: .assert, tag: "ActivityManager", message: "last"),
        ]
        let text = made.map { LogcatThreadtimeFormat.format($0) }.joined()
        let read = LogcatThreadtimeFormat.parse(text, referenceDate: reference)
        #expect(read.count == made.count)
        for (before, after) in zip(made, read) {
            #expect(after.pid == before.pid)
            #expect(after.tid == before.tid)
            #expect(after.level == before.level)
            #expect(after.tag == before.tag)
            #expect(after.message == before.message)
            #expect(LogcatTime.milliseconds(after.timestamp) == LogcatTime.milliseconds(before.timestamp))
            #expect(after.uid == nil)
        }
    }

    @Test func plainTextLikeTheTable() {
        func line(_ entry: LogEntry, process: String? = nil) -> String {
            LogPlainTextFormat.line(for: entry, processName: process, timeZone: utc)
        }
        #expect(
            line(entry(process: "com.example.app:remote"), process: "com.example.app:remote")
                == "2026-11-09 13:11:17.123 1234-5678 Tag com.example.app:remote I m"
        )
        #expect(line(entry()) == "2026-11-09 13:11:17.123 1234-5678 Tag pid-1234 I m")
        #expect(line(entry(pid: 0, tid: 0)) == "2026-11-09 13:11:17.123 0-0 Tag I m")
        #expect(line(LogEntry.marker("Device disconnected")) == "--------- Device disconnected")
        #expect(line(entry(message: "a\nb")) == "2026-11-09 13:11:17.123 1234-5678 Tag pid-1234 I a\nb")
    }
}

// MARK: Formats and file names

@Suite struct LogSaveFormatTests {
    @Test func defaultIsLogcat() {
        #expect(LogSaveFormat.allCases == [.logcat, .long, .threadtime, .plainText])
        #expect(LogSaveFormat.allCases.map(\.title) == [
            "Logcat (.logcat, Android Studio compatible)", "logcat -v long", "Threadtime", "Plain text as displayed",
        ])
        #expect(LogSaveFormat.allCases.map(\.fileExtension) == ["logcat", "txt", "txt", "txt"])
        #expect(LogSaveFormat.allCases.filter(\.includesMarkers) == [.plainText])
    }

    @Test func suggestsAndroidStudioLikeNames() throws {
        let date = Date(timeIntervalSince1970: try #require(LogcatTime.parse(date: "2026-11-10", time: "08:44:00.000", timeZone: utc)))
        #expect(
            LogSaveFormat.logcat.suggestedFileName(base: "Medium Phone API 37.0", date: date, timeZone: utc)
                == "Medium Phone API 37.0_2026-11-10_084400.logcat"
        )
        #expect(
            LogSaveFormat.threadtime.suggestedFileName(base: "Medium Phone API 37.0", date: date, timeZone: utc)
                == "Medium Phone API 37.0_2026-11-10_084400.txt"
        )
        #expect(LogSaveFormat.logcat.suggestedFileName(base: "a/b:c", date: date, timeZone: utc) == "a-b-c_2026-11-10_084400.logcat")
    }

    @Test func switchesTheExtension() {
        #expect(LogSaveFormat.threadtime.fileName(switching: "x_1.logcat") == "x_1.txt")
        #expect(
            LogSaveFormat.logcat.fileName(switching: "bugreport.zip · Events_2026-11-10_084400.txt")
                == "bugreport.zip · Events_2026-11-10_084400.logcat"
        )
        #expect(LogSaveFormat.logcat.fileName(switching: "notes") == "notes.logcat")
        #expect(LogSaveFormat.logcat.fileName(switching: "bugreport.zip") == "bugreport.zip.logcat")
        #expect(LogSaveFormat.long.fileName(switching: "Medium Phone API 37.0") == "Medium Phone API 37.0.txt")
    }
}

// MARK: Streaming write

private actor SaveEventBox {
    private(set) var events: [LogSaveEvent] = []
    func append(_ event: LogSaveEvent) { events.append(event) }
}

private actor ReadEventBox {
    private(set) var events: [LogFileEvent] = []
    func append(_ event: LogFileEvent) { events.append(event) }
}

@Suite(.serialized) struct LogFileWriterTests {
    private let phoneProperties = DeviceProperties(values: [
        "ro.product.manufacturer": "Google", "ro.product.model": "Pixel 8", "ro.build.version.release": "14",
        "ro.build.version.sdk": "34",
    ])

    private func make(
        _ id: Int, pid: Int32 = 100, tid: Int32? = nil, level: LogLevel = .info, tag: String = "Tag",
        message: String? = nil, process: String? = nil, uid: String? = nil, milliseconds: Int64? = nil
    ) -> LogEntry {
        LogEntry(
            id: id, timestamp: at(milliseconds ?? 1_794_248_000_000 + Int64(id) * 37), uid: uid, pid: pid, tid: tid ?? pid,
            level: level, tag: tag, message: message ?? "m\(id)", processName: process
        )
    }

    private func read(_ url: URL) async throws -> [LogFileEvent] {
        let box = ReadEventBox()
        try await LogFileReader().read(url) { await box.append($0) }
        return await box.events
    }

    private func readEntries(_ events: [LogFileEvent]) -> [LogEntry] {
        events.flatMap { event -> [LogEntry] in
            if case let .entries(batch, _) = event { batch } else { [] }
        }
    }

    private func readMetadata(_ events: [LogFileEvent]) -> LogcatFileMetadata? {
        for event in events {
            if case let .metadata(metadata) = event { return metadata }
        }
        return nil
    }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init)
    }

    // The round trip the issue asks for: save as .logcat, open it again, and the Package column and package:
    // filters behave as before.
    @Test func roundTripKeepsPackagesAndFilters() async throws {
        let scratch = try SaveScratch()
        let entries = [
            make(0, pid: 4321, tid: 4330, level: .warn, tag: "Net", message: "timeout\n\tat x", process: "com.example.app:remote"),
            make(1, pid: 4400, level: .info, tag: "Ui"),
            make(2, pid: 5000, level: .error, tag: "libc", process: "com.google.android.gms.persistent"),
            make(3, pid: 1303, level: .debug, tag: "vold"),
            make(4, pid: 0, level: .info, tag: "kernel"),
        ]
        let names: [Int32: String] = [4400: "com.example.app"]
        let device = LogcatFileDevice(properties: phoneProperties, serial: "35930112X", isOnline: true, avdPath: nil)
        let metadata = LogcatFileMetadata(device: device, filter: "package:mine level:INFO", projectApplicationIds: ["com.example.app"])
        let url = scratch.url.appendingPathComponent("x.logcat")
        try await LogFileWriter().write(
            LogSaveRequest(format: .logcat, entries: entries, processNames: names, metadata: metadata), to: url
        )

        let events = try await read(url)
        guard case .format(.logcatJSON) = try #require(events.first) else {
            Issue.record("the saved file should be detected as a .logcat")
            return
        }
        let readMetadata = try #require(readMetadata(events))
        #expect(readMetadata == metadata)
        let back = readEntries(events)
        #expect(back.count == 5)
        #expect(back.map(\.processName) == ["com.example.app:remote", "com.example.app", "com.google.android.gms.persistent", nil, "kernel"])
        for (before, after) in zip(entries, back) {
            #expect(after.pid == before.pid)
            #expect(after.tid == before.tid)
            #expect(after.level == before.level)
            #expect(after.tag == before.tag)
            #expect(after.message == before.message)
            #expect(LogcatTime.milliseconds(after.timestamp) == LogcatTime.milliseconds(before.timestamp))
        }

        func matching(_ query: String, in list: [LogEntry], context: FilterContext) throws -> [Int] {
            let filter = try LogFilter(query)
            return list.indices.filter { filter.matches(list[$0], context: context) }
        }
        let before = FilterContext(processNames: names, myPackages: ["com.example.app"])
        let after = FilterContext(myPackages: ["com.example.app"])
        #expect(try matching("package:com.example.app", in: entries, context: before) == [0, 1])
        #expect(try matching("package:com.example.app", in: back, context: after) == [0, 1])
        #expect(try matching("package:mine level:INFO", in: entries, context: before) == [0, 1])
        #expect(try matching("package:mine level:INFO", in: back, context: after) == [0, 1])
        // Opening it somewhere else spells out what `package:mine` meant here.
        #expect(readMetadata.filter(forMyPackages: ["com.other"]) == "package:com.example.app level:INFO")
    }

    @Test func roundTripLongAndThreadtime() async throws {
        let scratch = try SaveScratch()
        // A fixed July day with the files dated the day after: threadtime has no year, so the reader takes it from there.
        let base = try #require(LogcatTime.parse(date: "2026-07-15", time: "12:00:00.000"))
        let entries = [
            LogEntry(id: 0, timestamp: base + 1.001, uid: "10123", pid: 4321, tid: 4330, level: .warn, tag: "Net", message: "timeout\n\tat x"),
            LogEntry(id: 1, timestamp: base + 2.5, pid: 4400, tid: 4400, level: .info, tag: "My Tag", message: "spaced"),
            LogEntry(id: 2, timestamp: base + 3.999, pid: 5000, tid: 5001, level: .error, tag: "libc", message: ""),
            LogEntry(id: 3, timestamp: base + 5, pid: 1303, tid: 1303, level: .debug, tag: "vold", message: "last"),
        ]
        let modified = Date(timeIntervalSince1970: base + 86_400)

        for (format, name) in [(LogSaveFormat.long, "x.txt"), (LogSaveFormat.threadtime, "y.txt")] {
            let url = scratch.url.appendingPathComponent(name)
            try await LogFileWriter().write(LogSaveRequest(format: format, entries: entries), to: url)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)

            let events = try await read(url)
            switch (format, try #require(events.first)) {
            case (.long, .format(.long)), (.threadtime, .format(.threadtime)): break
            default: Issue.record("\(format) was detected as something else")
            }
            let back = readEntries(events)
            #expect(back.count == entries.count)
            #expect(back.map(\.tag) == entries.map(\.tag))
            #expect(back.map(\.message) == entries.map(\.message))
            #expect(back.map { LogcatTime.milliseconds($0.timestamp) } == entries.map { LogcatTime.milliseconds($0.timestamp) })
            #expect(back.map(\.pid) == entries.map(\.pid))
            #expect(back.map(\.uid) == (format == .long ? ["10123", nil, nil, nil] : [nil, nil, nil, nil]))
        }
    }

    @Test func writesOnlyVisibleEntries() async throws {
        let scratch = try SaveScratch()
        var marker = LogEntry.marker("Device disconnected", at: at(1_794_248_000_500))
        marker.id = 15
        var buffer = (10...19).map { make($0, pid: Int32($0)) }
        buffer[5] = marker
        let ids = [11, 11, 13, 13, 13, 15, 18, 25]

        let threadtime = LogSaveRequest(format: .threadtime, entries: buffer, onlyEntryIDs: ids)
        #expect(threadtime.selectedEntries().map(\.id) == [11, 13, 18])
        let tt = scratch.url.appendingPathComponent("a.txt")
        try await LogFileWriter().write(threadtime, to: tt)
        let ttLines = lines(try scratch.read("a.txt"))
        #expect(ttLines.count == 3)
        #expect(ttLines.map { $0.components(separatedBy: ": ").last } == ["m11", "m13", "m18"])

        let plain = LogSaveRequest(format: .plainText, entries: buffer, onlyEntryIDs: ids, timeZone: utc)
        #expect(plain.selectedEntries().map(\.id) == [11, 13, 15, 18])
        try await LogFileWriter().write(plain, to: scratch.url.appendingPathComponent("b.txt"))
        let plainLines = lines(try scratch.read("b.txt"))
        #expect(plainLines.count == 4)
        #expect(plainLines[0].hasSuffix(" I m11"))
        #expect(plainLines[1].hasSuffix(" I m13"))
        #expect(plainLines[2] == "--------- Device disconnected")
        #expect(plainLines[3].hasSuffix(" I m18"))

        // Ids that aren't consecutive (the buffer was trimmed or cleared between): found by searching.
        let gappy = [make(10), make(11), make(20), make(21)]
        #expect(LogSaveRequest(format: .long, entries: gappy, onlyEntryIDs: [20]).selectedEntries().map(\.id) == [20])
        #expect(LogSaveRequest(format: .long, entries: gappy, onlyEntryIDs: [10, 21, 12]).selectedEntries().map(\.id) == [10, 21])
        let shifted = [make(10), make(12), make(13)]
        #expect(LogSaveRequest(format: .long, entries: shifted, onlyEntryIDs: [12]).selectedEntries().map(\.id) == [12])
        #expect(LogSaveRequest(format: .long, entries: [], onlyEntryIDs: [1]).selectedEntries().isEmpty)
    }

    @Test func skipsMarkersExceptInPlainText() async throws {
        let scratch = try SaveScratch()
        let buffer = [make(0), LogEntry.marker("Device disconnected", at: at(1_794_248_000_100)), make(2)]
        for format in LogSaveFormat.allCases {
            let name = "out-\(format.rawValue).\(format.fileExtension)"
            let result = try await LogFileWriter().write(LogSaveRequest(format: format, entries: buffer), to: scratch.url.appendingPathComponent(name))
            let text = try scratch.read(name)
            #expect(text.contains("---------") == format.includesMarkers, "\(format)")
            #expect(result.entries == (format.includesMarkers ? 3 : 2), "\(format)")
        }
    }

    @Test func reportsEstimateAndProgress() async throws {
        let scratch = try SaveScratch()
        let buffer = (0..<20_000).map { make($0, pid: Int32(1000 + $0 % 50), process: "com.example.app") }
        var writer = LogFileWriter()
        writer.batchSize = 1_000
        let box = SaveEventBox()
        let url = scratch.url.appendingPathComponent("big.logcat")
        let result = try await writer.write(LogSaveRequest(format: .logcat, entries: buffer), to: url) { await box.append($0) }

        let events = await box.events
        guard case let .estimated(bytes) = try #require(events.first) else {
            Issue.record("the first event should be the estimate")
            return
        }
        #expect(bytes > 0)
        let fractions = events.compactMap { event -> Double? in
            if case let .progress(fraction) = event { fraction } else { nil }
        }
        #expect(fractions.count >= 20)
        #expect(fractions == fractions.sorted())
        #expect(fractions.last == 1.0)
        #expect(result.entries == 20_000)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)
        #expect(result.bytes == size)
    }

    @Test func estimateIsCloseToTheResult() async throws {
        let scratch = try SaveScratch()
        let buffer = (0..<1_000).map {
            make($0, pid: Int32(2000 + $0 % 20), tag: "ActivityMa", message: String(repeating: "x", count: 60), process: "com.example.app")
        }
        for format in LogSaveFormat.allCases {
            let request = LogSaveRequest(format: format, entries: buffer)
            let result = try await LogFileWriter().write(request, to: scratch.url.appendingPathComponent("e.\(format.fileExtension)"))
            let estimate = LogSaveRequest.estimatedBytes(of: buffer, format: format)
            let ratio = Double(estimate) / Double(result.bytes)
            #expect((0.5...2.0).contains(ratio), "\(format): estimated \(estimate) for \(result.bytes) bytes")
        }
    }

    @Test func cancellationKeepsTheOldFile() async throws {
        let scratch = try SaveScratch()
        let url = try scratch.write("x.logcat", "old")
        let buffer = (0..<200_000).map { make($0) }
        var writer = LogFileWriter()
        writer.batchSize = 100
        let task = Task { [writer] in
            try await writer.write(LogSaveRequest(format: .logcat, entries: buffer), to: url) { event in
                if case .progress = event { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(try scratch.read("x.logcat") == "old")
        #expect(scratch.contents == ["x.logcat"])
    }

    @Test func replacesAnExistingFile() async throws {
        let scratch = try SaveScratch()
        let url = try scratch.write("x.logcat", "old")
        let request = LogSaveRequest(format: .logcat, entries: [make(0, process: "com.example.app"), make(1)])
        let result = try await LogFileWriter().write(request, to: url)
        #expect(try scratch.read("x.logcat") == LogcatFileWriter.encode(metadata: request.metadata, entries: request.entries))
        #expect(result.entries == 2)
        #expect(scratch.contents == ["x.logcat"])
    }

    @Test func createsANewFile() async throws {
        let scratch = try SaveScratch()
        let request = LogSaveRequest(format: .logcat, entries: [make(0), make(1, process: "com.example.app")])
        try await LogFileWriter().write(request, to: scratch.url.appendingPathComponent("new.logcat"))
        #expect(try scratch.read("new.logcat") == LogcatFileWriter.encode(metadata: request.metadata, entries: request.entries))
        #expect(scratch.contents == ["new.logcat"])
    }
}
