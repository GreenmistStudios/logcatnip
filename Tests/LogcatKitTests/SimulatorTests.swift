import Foundation
import Testing
@testable import LogcatKit

@Suite struct UnifiedLogParserTests {
    /// Trimmed from real `simctl spawn <udid> log stream --style ndjson --level debug` output.
    static let infoLine = #"{"timezoneName":"","messageType":"Info","eventType":"logEvent","source":null,"formatString":"Processing invalidation queue with %d assertions","userID":502,"activityIdentifier":0,"subsystem":"com.apple.runningboard","category":"assertion","threadID":3463851,"senderImageUUID":"8E2B","backtrace":{"frames":[{"imageOffset":1,"imageUUID":"8E2B"}]},"bootUUID":"","processImagePath":"\/Library\/Developer\/CoreSimulator\/RuntimeRoot\/usr\/libexec\/runningboardd","senderImagePath":"\/Library\/Developer\/CoreSimulator\/RuntimeRoot\/System\/Library\/PrivateFrameworks\/RunningBoard.framework\/RunningBoard","timestamp":"2026-11-12 15:10:50.255192-0500","machTimestamp":2967402239345,"eventMessage":"Processing invalidation queue with 1 assertions","processImageUUID":"9B1C","traceID":2553817619497476,"processID":88327,"senderProgramCounter":126476,"parentActivityIdentifier":0}"#

    static func line(
        messageType: String? = "Default",
        eventType: String = "logEvent",
        subsystem: String = "",
        category: String = "",
        process: String = "/Applications/MyApp.app/MyApp",
        sender: String = "/System/Library/Frameworks/Foundation.framework/Foundation",
        message: String = "hello",
        timestamp: String = "2026-11-12 15:10:50.500000-0500"
    ) -> String {
        var object: [String: Any] = [
            "eventType": eventType,
            "subsystem": subsystem,
            "category": category,
            "processImagePath": process,
            "senderImagePath": sender,
            "eventMessage": message,
            "timestamp": timestamp,
            "processID": 42,
            "threadID": 7,
            "userID": 501,
        ]
        if let messageType { object["messageType"] = messageType }
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    @Test func parsesRealLine() throws {
        let entry = try #require(UnifiedLogParser.parseLine(Self.infoLine))
        #expect(entry.level == .info)
        #expect(entry.tag == "com.apple.runningboard:assertion")
        #expect(entry.processName == "runningboardd")
        #expect(entry.pid == 88327)
        #expect(entry.tid == 3463851)
        #expect(entry.uid == "502")
        #expect(entry.message == "Processing invalidation queue with 1 assertions")
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-11-12T20:10:50Z")).timeIntervalSince1970 + 0.255192
        #expect(abs(entry.timestamp - expected) < 0.000_001)
    }

    @Test(arguments: [
        ("Debug", LogLevel.debug),
        ("Info", .info),
        ("Default", .info),
        ("Error", .error),
        ("Fault", .assert),
    ])
    func mapsMessageTypes(type: String, level: LogLevel) throws {
        let entry = try #require(UnifiedLogParser.parseLine(Self.line(messageType: type)))
        #expect(entry.level == level)
    }

    @Test func tagFallsBackToSubsystemThenSenderThenProcess() throws {
        let subsystemOnly = try #require(UnifiedLogParser.parseLine(Self.line(subsystem: "com.example.app")))
        #expect(subsystemOnly.tag == "com.example.app")

        let sender = try #require(UnifiedLogParser.parseLine(Self.line()))
        #expect(sender.tag == "Foundation")

        let process = try #require(UnifiedLogParser.parseLine(Self.line(sender: "")))
        #expect(process.tag == "MyApp")
        #expect(process.processName == "MyApp")
    }

    @Test func keepsMultiLineMessages() throws {
        let entry = try #require(UnifiedLogParser.parseLine(Self.line(message: "first\nsecond\n\tthird")))
        #expect(entry.message == "first\nsecond\n\tthird")
    }

    @Test func skipsNonLogEventsAndMalformedLines() {
        #expect(UnifiedLogParser.parseLine(Self.line(messageType: nil, eventType: "activityCreateEvent")) == nil)
        #expect(UnifiedLogParser.parseLine("Filtering the log data using \"type != 3\"") == nil)
        #expect(UnifiedLogParser.parseLine("{\"eventType\":\"logEvent\"") == nil)
        #expect(UnifiedLogParser.parseLine(Self.line(timestamp: "yesterday")) == nil)
    }

    @Test func feedBuffersPartialLines() {
        let text = [Self.line(message: "one"), "not json", Self.line(message: "two"), Self.line(message: "three")]
            .joined(separator: "\n")
        let data = Data(text.utf8)
        let split = data.count - 20
        var parser = UnifiedLogParser()
        let first = parser.feed(data.prefix(split))
        let second = parser.feed(data.suffix(from: split))
        let rest = parser.finish()
        #expect(first.map(\.message) == ["one", "two"])
        #expect(second.isEmpty)
        #expect(rest.map(\.message) == ["three"])
    }

    @Test func parsesTimestamps() throws {
        let utc = try #require(UnifiedLogParser.parseTimestamp("1970-01-02 00:00:01.5+0000"))
        #expect(utc == 86_401.5)
        let east = try #require(UnifiedLogParser.parseTimestamp("2024-02-29 05:30:00+0530"))
        let expected = try #require(ISO8601DateFormatter().date(from: "2024-02-29T00:00:00Z")).timeIntervalSince1970
        #expect(east == expected)
        #expect(UnifiedLogParser.parseTimestamp("2024-02-29 05:30:00") == nil)
        #expect(UnifiedLogParser.parseTimestamp("2024-02-29T05:30:00+0000") == nil)
    }

    @Test func entriesWorkWithFilters() throws {
        let entries = [
            Self.line(messageType: "Error", subsystem: "com.example.app", category: "network", message: "timeout"),
            Self.line(messageType: "Debug", subsystem: "com.apple.UIKit", category: "Touch", process: "/x/SpringBoard"),
        ].compactMap(UnifiedLogParser.parseLine)
        let filter = try LogFilter("tag:network process:MyApp level:ERROR")
        #expect(entries.filter { filter.matches($0, context: FilterContext()) }.map(\.message) == ["timeout"])
    }
}

@Suite struct SimulatorListTests {
    static let json = #"""
    {
      "devices" : {
        "com.apple.CoreSimulator.SimRuntime.iOS-26-5" : [
          {
            "udid" : "AF226314-2CA8-4EC2-8227-3DCEBA9C7858",
            "isAvailable" : true,
            "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
            "state" : "Booted",
            "name" : "iPhone 17 Pro"
          },
          {
            "udid" : "A60F575F-871D-452F-BC7D-367C05799EA8",
            "isAvailable" : true,
            "state" : "Shutdown",
            "name" : "iPhone 17e"
          }
        ],
        "com.apple.CoreSimulator.SimRuntime.watchOS-11-0" : [
          {
            "udid" : "11111111-0000-0000-0000-000000000000",
            "isAvailable" : false,
            "availabilityError" : "runtime profile not found",
            "state" : "Booted",
            "name" : "Apple Watch Ultra"
          }
        ],
        "com.apple.CoreSimulator.SimRuntime.xrOS-2-0" : [
          {
            "udid" : "22222222-0000-0000-0000-000000000000",
            "state" : "Booted",
            "name" : "Apple Vision Pro"
          }
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-27-0" : []
      }
    }
    """#

    @Test func decodesEveryDevice() throws {
        let devices = try SimulatorList.decode(Data(Self.json.utf8))
        #expect(devices.map(\.name) == ["Apple Vision Pro", "Apple Watch Ultra", "iPhone 17 Pro", "iPhone 17e"])
        let phone = try #require(devices.first { $0.name == "iPhone 17 Pro" })
        #expect(phone.udid == "AF226314-2CA8-4EC2-8227-3DCEBA9C7858")
        #expect(phone.runtimeName == "iOS 26.5")
        #expect(phone.platform == "iOS")
        #expect(phone.deviceTypeIdentifier == "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro")
        #expect(devices.first { $0.name == "Apple Vision Pro" }?.runtimeName == "visionOS 2.0")
    }

    @Test func bootedSkipsShutdownAndUnavailable() throws {
        let booted = try SimulatorList.booted(Data(Self.json.utf8))
        #expect(booted.map(\.name) == ["Apple Vision Pro", "iPhone 17 Pro"])
    }

    @Test func logStreamArguments() {
        #expect(Simctl.logStreamArguments(udid: "ABC") == ["spawn", "ABC", "log", "stream", "--style", "ndjson", "--level", "debug"])
    }

    @Test func dropsPasswdNoise() {
        let stderr = "getpwuid_r did not find a match for uid 502\nInvalid device: ABC"
        #expect(Simctl.meaningfulErrors(stderr) == "Invalid device: ABC")
    }

    @Test func locateReportsMissingSimctl() async {
        let result = await Simctl.locate(environment: ["DEVELOPER_DIR": "/nonexistent/Developer"])
        guard case let .unavailable(message) = result else {
            Issue.record("expected unavailable")
            return
        }
        #expect(message.contains("/nonexistent/Developer"))
    }
}

/// Talks to a booted simulator. Run with `LOGCATNIP_SIMULATOR_TESTS=1 swift test` with a simulator booted.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LOGCATNIP_SIMULATOR_TESTS"] == "1"))
struct SimulatorIntegrationTests {
    @Test func streamsLogsFromABootedSimulator() async throws {
        guard case let .found(simctl) = await Simctl.locate() else {
            Issue.record("simctl not found")
            return
        }
        let booted = try await simctl.devices().filter(\.isBooted)
        let udid = try #require(booted.first?.udid, "No booted simulator")
        var entries: [LogEntry] = []
        let deadline = Date().addingTimeInterval(10)
        for await event in simctl.logStream(udid: udid) {
            if case let .entries(batch) = event { entries += batch }
            if entries.count > 50 || Date() > deadline { break }
        }
        #expect(!entries.isEmpty)
        #expect(entries.allSatisfy { $0.processName != nil && !$0.tag.isEmpty })
    }
}
