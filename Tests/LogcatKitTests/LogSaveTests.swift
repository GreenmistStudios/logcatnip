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

    private final class Scratch {
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

        func write(_ path: String, _ text: String) throws {
            let file = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
    }

    @Test func locatesAvdFolders() throws {
        let scratch = try Scratch()
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
