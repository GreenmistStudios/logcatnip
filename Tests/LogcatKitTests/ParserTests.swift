import Foundation
import Testing
@testable import LogcatKit

@Suite struct LongFormatParserTests {
    @Test func parsesHeaderWithEpochAndUid() throws {
        let header = try #require(LogcatLongFormat.parseHeader("[          1794248132.663  1046: 2093: 1697 W/qdgralloc ]"))
        #expect(header.timestamp == 1794248132.663)
        #expect(header.uid == "1046")
        #expect(header.pid == 2093)
        #expect(header.tid == 1697)
        #expect(header.level == .warn)
        #expect(header.tag == "qdgralloc")
    }

    @Test func parsesHeaderWithNamedUidAndNoSpaces() throws {
        let shell = try #require(LogcatLongFormat.parseHeader("[          1794248132.665 shell: 1640: 1684 D/PipelineWatcher ]"))
        #expect(shell.uid == "shell")
        #expect(shell.pid == 1640)

        let packed = try #require(LogcatLongFormat.parseHeader("[          1794248132.665 10388:32202:32202 I/View     ]"))
        #expect(packed.uid == "10388")
        #expect(packed.pid == 32202)
        #expect(packed.tid == 32202)
        #expect(packed.tag == "View")
    }

    @Test func parsesHeaderWithoutUid() throws {
        let header = try #require(LogcatLongFormat.parseHeader("[ 1794248132.665  2093: 1697 E/Some Tag With Spaces ]"))
        #expect(header.uid == nil)
        #expect(header.pid == 2093)
        #expect(header.level == .error)
        #expect(header.tag == "Some Tag With Spaces")
    }

    @Test func parsesHeaderWithDate() throws {
        let header = try #require(LogcatLongFormat.parseHeader("[ 2026-11-09 13:11:17.123  2093: 1697 F/libc ]"))
        #expect(header.level == .assert)
        let expected = LogcatTime.parse(date: "2026-11-09", time: "13:11:17.123")
        #expect(header.timestamp == expected)
    }

    @Test func rejectsNonHeaders() {
        #expect(LogcatLongFormat.parseHeader("[not a header]") == nil)
        #expect(LogcatLongFormat.parseHeader("plain message") == nil)
        #expect(LogcatLongFormat.parseHeader("[ 123.4 abc: def I/Tag ]") == nil)
    }

    @Test func streamsMultiLineRecordsAcrossChunks() {
        let text = """
        --------- beginning of main
        [ 1794248132.663  1046: 2093: 1697 W/qdgralloc ]
        first

        [ 1794248132.664  1046: 2093: 1700 E/AndroidRuntime ]
        FATAL EXCEPTION: main
        Process: com.example, PID: 2093
        \tat com.example.Main.run(Main.kt:12)


        """
        var parser = LogcatLongParser()
        var entries: [LogEntry] = []
        // Feed in small, awkward chunks.
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count {
            let end = min(index + 7, bytes.count)
            entries += parser.feed(Data(bytes[index..<end]))
            index = end
        }
        entries += parser.finish()

        #expect(entries.count == 2)
        #expect(entries[0].message == "first")
        #expect(entries[1].tag == "AndroidRuntime")
        #expect(entries[1].message == "FATAL EXCEPTION: main\nProcess: com.example, PID: 2093\n\tat com.example.Main.run(Main.kt:12)")
    }

    @Test func emitsRecordAtEndOfChunkWithoutWaitingForNextHeader() {
        var parser = LogcatLongParser()
        let entries = parser.feed(Data("[ 1.000  1: 2 I/Tag ]\nhello\n\n".utf8))
        #expect(entries.map(\.message) == ["hello"])
        #expect(parser.finish().isEmpty)
    }

    @Test func keepsBlankLinesInsideMessages() {
        let entries = LogcatLongParser.parse("[ 1.000  1: 2 I/Tag ]\nline one\n\nline three\n\n[ 2.000  1: 2 I/Tag ]\nnext\n\n")
        #expect(entries.count == 2)
        #expect(entries[0].message == "line one\n\nline three")
    }

    @Test func roundTripsFormattedEntries() {
        let original = LogEntry(timestamp: 1794248132.5, uid: "10388", pid: 42, tid: 43, level: .debug, tag: "Tag", message: "a\nb")
        let parsed = LogcatLongParser.parse(LogcatLongFormat.format(original))
        #expect(parsed == [original])
    }
}

@Suite struct TimeFormatTests {
    @Test func formatsMillisecondsWithoutTruncation() {
        let utc = TimeZone(identifier: "UTC")!
        #expect(LogcatTime.format(1794248132.663, includeDate: false, timeZone: utc).hasSuffix(":32.663"))
        #expect(LogcatTime.format(1794248132.9996, includeDate: false, timeZone: utc).hasSuffix(":33.000"))
        for millis in 0..<1000 {
            let text = LogcatTime.format(1_000_000 + Double(millis) / 1000, includeDate: false, timeZone: utc)
            #expect(text.hasSuffix(String(format: ".%03d", millis)))
        }
    }

    /// 1794248132 is a current epoch, where a double has about 0.2 µs of resolution: the case that exposed
    /// the truncation. `printf` rounds correctly, so it is the reference.
    @Test func everyMillisecondMatchesPrintfAtCurrentEpoch() {
        let utc = TimeZone(identifier: "UTC")!
        var mismatches: [Int] = []
        for millis in 0..<1000 {
            let timestamp = 1794248132 + Double(millis) / 1000
            let printf = String(format: "%.3f", timestamp)
            let shown = LogcatTime.format(timestamp, includeDate: false, timeZone: utc)
            let matches = printf.hasSuffix(String(format: ".%03d", millis))
                && shown.hasSuffix(String(printf.suffix(4)))
                && LogcatTime.formatEpoch(timestamp) == printf
            if !matches { mismatches.append(millis) }
        }
        #expect(mismatches.isEmpty, "milliseconds that differ from printf: \(mismatches.prefix(10))")
    }

    @Test func carriesIntoNextSecondMinuteAndYear() {
        let utc = TimeZone(identifier: "UTC")!
        #expect(LogcatTime.format(1794248132.9996, timeZone: utc) == "2026-11-09 18:15:33.000")
        #expect(LogcatTime.format(1798761599.9996, timeZone: utc) == "2027-01-01 00:00:00.000")
        #expect(LogcatTime.format(1798761599.9996, includeDate: false, timeZone: utc) == "00:00:00.000")
        #expect(LogcatTime.format(1798761599.9994, timeZone: utc) == "2026-12-31 23:59:59.999")
        #expect(LogcatTime.formatEpoch(1798761599.9996) == "1798761600.000")
    }

    @Test func exportedTimeMatchesDisplayedTime() throws {
        let timestamps = [1794248132.663, 1794248132.9996, 1794248132.0004, 1794248132.001, 1794248132.123,
                          try #require(LogcatTime.parse(date: "11-09", time: "13:11:17.999"))]
        for timestamp in timestamps {
            let entry = LogEntry(timestamp: timestamp, uid: nil, pid: 1, tid: 2, level: .info, tag: "Tag", message: "m")
            let exported = LogcatLongFormat.format(entry)
            let reparsed = try #require(LogcatLongParser.parse(exported).first)
            let shown = LogcatTime.format(timestamp)
            let epoch = LogcatTime.formatEpoch(timestamp)
            #expect(LogcatTime.format(reparsed.timestamp) == shown)
            #expect(exported.contains(" \(epoch) "))
            #expect(shown.suffix(3) == epoch.suffix(3))
        }
    }
}

@Suite struct ThreadtimeParserTests {
    @Test func parsesThreadtimeLine() throws {
        let entry = try #require(LogcatThreadtimeFormat.parseLine("11-09 13:11:17.123  1234  5678 I ActivityManager: Start proc 4321:com.example/u0a123"))
        #expect(entry.pid == 1234)
        #expect(entry.tid == 5678)
        #expect(entry.level == .info)
        #expect(entry.tag == "ActivityManager")
        #expect(entry.message == "Start proc 4321:com.example/u0a123")
    }

    @Test func parsesPaddedTagAndUid() throws {
        let entry = try #require(LogcatThreadtimeFormat.parseLine("2026-11-09 13:11:17.123 10388 32202 32202 W View    : setRequestedFrameRate"))
        #expect(entry.uid == "10388")
        #expect(entry.pid == 32202)
        #expect(entry.tag == "View")
        #expect(entry.message == "setRequestedFrameRate")
    }

    @Test func mergesContinuationLines() {
        let entries = LogcatThreadtimeFormat.parse("""
        11-09 13:11:17.123  1234  1234 E AndroidRuntime: FATAL EXCEPTION: main
        11-09 13:11:17.123  1234  1234 E AndroidRuntime: \tat com.foo.Bar.baz(Bar.kt:1)
        11-09 13:11:17.124  1234  1234 I Other: next
        """)
        #expect(entries.count == 2)
        #expect(entries[0].message == "FATAL EXCEPTION: main\n\tat com.foo.Bar.baz(Bar.kt:1)")
    }

    @Test func importerDetectsFormat() {
        #expect(LogFileImporter.parse("[ 1.000  1: 2 I/Tag ]\nhello\n\n").first?.tag == "Tag")
        #expect(LogFileImporter.parse("11-09 13:11:17.123  1  2 I Tag: hello").first?.message == "hello")
    }
}

@Suite struct DeviceParsingTests {
    @Test func decodesTrackDevicesStream() {
        var decoder = TrackDevicesDecoder()
        let payload = "RFCX600V0LF            device usb:35930112X product:e1quew model:SM_S921U1 device:e1q transport_id:1\n"
        let frame = String(format: "%04x", payload.utf8.count) + payload + "0000"
        let bytes = Array(frame.utf8)
        var snapshots = decoder.feed(Data(bytes[0..<10]))
        #expect(snapshots.isEmpty)
        snapshots = decoder.feed(Data(bytes[10...]))
        #expect(snapshots.count == 2)
        let device = snapshots[0][0]
        #expect(device.serial == "RFCX600V0LF")
        #expect(device.state == .device)
        #expect(device.model == "SM S921U1")
        #expect(device.attributes["transport_id"] == "1")
        #expect(snapshots[1].isEmpty)
    }

    @Test func parsesStatesWithSpaces() throws {
        let device = try #require(DeviceDescriptor.parse(line: "0123 no permissions (missing udev rules?) usb:1-1"))
        #expect(device.state == .other("no permissions (missing udev rules?)"))
        #expect(device.attributes["usb"] == "1-1")
    }

    @Test func parsesGetprop() {
        let props = DeviceProperties.parse("[ro.build.version.sdk]: [36]\n[ro.product.model]: [SM-S921U1]\n[empty]: []\n")
        #expect(props.apiLevel == 36)
        #expect(props.model == "SM-S921U1")
        #expect(props.values["empty"] == "")
    }

    @Test func parsesModernPs() {
        let map = ProcessListParser.parse("  PID NAME\n    1 init\n    2 [kthreadd]\n 4321 com.example:remote\n")
        #expect(map == [1: "init", 4321: "com.example:remote"])
    }

    @Test func parsesLegacyPs() {
        let map = ProcessListParser.parse("""
        USER     PID   PPID  VSIZE  RSS     WCHAN    PC         NAME
        root      1     0     1234   567   ffffffff 00000000 S /init
        u0_a12    4321  100   1234   567   ffffffff 00000000 S com.example
        """)
        #expect(map == [1: "/init", 4321: "com.example"])
    }
}
