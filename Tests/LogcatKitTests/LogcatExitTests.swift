import Foundation
import Testing
@testable import LogcatKit

/// Android 6.0 over adb's legacy shell: logcat's stderr arrives on stdout and adb exits 0 (AOSP
/// marshmallow-release logcat.cpp: logcat_panic(true, "Invalid parameter %s to -v\n") then show_help()).
private let marshmallowEpochRejection = """
Invalid parameter epoch to -v
Usage: logcat [options] [filterspecs]
options include:
  -s              Set default filter to silent.
                  Like specifying filterspec '*:S'
  -f <filename>   Log to file. Default is stdout
  -r <kbytes>     Rotate log every kbytes. Requires -f
  -n <count>      Sets max number of rotated logs to <count>, default 4
  -v <format>     Sets the log print format, where <format> is:

                      brief color long printable process raw tag thread
                      threadtime time usec

  -D              print dividers between each log buffer
  -c              clear (flush) the entire log and exit
  -d              dump the log and then exit (don't block)
  -t <count>      print only the most recent <count> lines (implies -d)
  -t '<time>'     print most recent lines since specified time (implies -d)
  -T <count>      print only the most recent <count> lines (does not imply -d)
  -T '<time>'     print most recent lines since specified time (not imply -d)
                  count is pure numerical, time is 'MM-DD hh:mm:ss.mmm'
  -g              get the size of the log's ring buffer and exit
  -L              dump logs from prior to last reboot
  -b <buffer>     Request alternate ring buffer, 'main', 'system', 'radio',
                  'events', 'crash' or 'all'. Multiple -b parameters are
                  allowed and results are interleaved. The default is
                  -b main -b system -b crash.

"""

private let unknownBufferAPI37 = "logcat: Unknown -b buffer 'bogus'.\n"

@Suite("logcat exit classification")
struct LogcatExitTests {
    @Test func marshmallowFormatErrorOnStdoutIsFormatUnsupported() {
        let exit = LogcatExit(status: 0, leadingOutput: marshmallowEpochRejection)
        #expect(exit.failure == .formatUnsupported)
        #expect(exit.detail == "Invalid parameter epoch to -v")
        #expect(exit.recovery(restartAttempts: 0, deviceOnline: true) == .useLegacyFormat)
    }

    @Test func formatErrorOnStderrIsFormatUnsupported() {
        let exit = LogcatExit(status: 1, stderr: marshmallowEpochRejection)
        #expect(exit.failure == .formatUnsupported)
    }

    @Test(arguments: ["logcat: Invalid -v 'uid'.\n", "logcat: Invalid parameter 'epoch' to -v.\n"])
    func newerFormatErrorWordingsAreRecognised(stderr: String) {
        let exit = LogcatExit(status: 1, stderr: stderr)
        #expect(exit.failure == .formatUnsupported)
    }

    @Test func formatErrorInLegacyRunIsAnInvalidOption() {
        // A legacy run passes only -v long. If that is rejected, switching format again would loop.
        let exit = LogcatExit(status: 0, leadingOutput: marshmallowEpochRejection, modernFormat: false)
        #expect(exit.failure == .invalidOption("Invalid parameter epoch to -v"))
    }

    @Test func formatErrorAfterEntriesIsTransient() {
        let exit = LogcatExit(status: 1, stderr: marshmallowEpochRejection, receivedEntries: true)
        #expect(exit.failure == .transient)
    }

    @Test(arguments: [
        ("error: closed\n", "error: closed"),
        ("error: device offline\n", "error: device offline"),
        ("adb: device 'emulator-5556' not found\n", "adb: device 'emulator-5556' not found"),
        (
            "- waiting for device -\nerror: protocol fault (couldn't read status): Connection reset by peer\n",
            "error: protocol fault (couldn't read status): Connection reset by peer"
        ),
    ])
    func transientFailureAfterReconnectKeepsModernFormat(stderr: String, detail: String) {
        let exit = LogcatExit(status: 1, stderr: stderr, modernFormat: true)
        #expect(exit.failure == .transient)
        #expect(exit.detail == detail)
        #expect(exit.recovery(restartAttempts: 0, deviceOnline: true) == .restart)
        #expect(exit.recovery(restartAttempts: 0, deviceOnline: true) != .useLegacyFormat)
    }

    @Test func nonZeroExitWithoutOutputIsTransient() {
        let exit = LogcatExit(status: 255)
        #expect(exit.failure == .transient)
        #expect(exit.detail == nil)
        #expect(exit.message == "logcat exited (255)")
    }

    @Test func bufferDividersAreNotADetail() {
        let exit = LogcatExit(status: 0, leadingOutput: "--------- beginning of main\n")
        #expect(exit.failure == .transient)
        #expect(exit.detail == nil)
    }

    @Test(arguments: [
        LogcatExit(status: 1, stderr: unknownBufferAPI37),
        LogcatExit(status: 1, stderr: "logcat: Unknown buffer 'bogus' listed for -b.\n"),
        LogcatExit(status: 0, leadingOutput: "Unable to open log device 'bogus'\n", modernFormat: false),
    ])
    func unknownBufferIsAnInvalidOption(exit: LogcatExit) {
        guard case let .invalidOption(line) = exit.failure else {
            Issue.record("expected an invalid option, got \(exit.failure)")
            return
        }
        #expect(line.contains("bogus"))
        #expect(exit.detail == line)
        #expect(exit.recovery(restartAttempts: 0, deviceOnline: true) == .fail(line))
    }

    @Test func unknownBufferKeepsLogcatsOwnText() {
        let exit = LogcatExit(status: 1, stderr: unknownBufferAPI37)
        #expect(exit.failure == .invalidOption("logcat: Unknown -b buffer 'bogus'."))
    }

    @Test(arguments: [
        (LogcatExit(status: 1, stderr: "logcat: -T 'garbage' not in time format.\n"), "logcat: -T 'garbage' not in time format."),
        (
            LogcatExit(
                status: 0, leadingOutput: "-T \"1794248132.663\" not in \"%m-%d %H:%M:%S.%q\" time format\n",
                modernFormat: false
            ),
            "-T \"1794248132.663\" not in \"%m-%d %H:%M:%S.%q\" time format"
        ),
        (LogcatExit(status: 1, stderr: "logcat: Option '-T' needs an argument.\n"), "logcat: Option '-T' needs an argument."),
        (LogcatExit(status: 1, stderr: "logcat: Unknown option '--bogus'.\n"), "logcat: Unknown option '--bogus'."),
    ])
    func otherRejectedOptionsAreInvalidOptions(exit: LogcatExit, line: String) {
        #expect(exit.failure == .invalidOption(line))
    }

    @Test func runtimeReadFailureIsTransient() {
        // "Invalid argument" is strerror text from a read, not a rejected option.
        let exit = LogcatExit(status: 1, stderr: "logcat: Logcat read failure: Invalid argument\n")
        #expect(exit.failure == .transient)
    }
}

@Suite("logcat recovery")
struct LogcatRecoveryTests {
    @Test func recoveryRestartsTransientFailures() {
        let exit = LogcatExit(status: 1, stderr: "error: closed\n")
        for attempts in 0..<3 {
            #expect(exit.recovery(restartAttempts: attempts, deviceOnline: true) == .restart)
        }
        #expect(exit.recovery(restartAttempts: 3, deviceOnline: true) == .fail("error: closed"))
    }

    @Test func recoveryWaitsForAnOfflineDevice() {
        let exit = LogcatExit(status: 1, stderr: "error: closed\n")
        #expect(exit.recovery(restartAttempts: 0, deviceOnline: false) == .waitForDevice)
    }

    @Test func recoveryFailsInvalidOptionsWithoutRestarting() {
        let exit = LogcatExit(status: 1, stderr: unknownBufferAPI37)
        #expect(exit.recovery(restartAttempts: 0, deviceOnline: true) == .fail("logcat: Unknown -b buffer 'bogus'."))
    }

    @Test func formatUnsupportedSwitchesEvenWhenOffline() {
        let exit = LogcatExit(status: 0, leadingOutput: marshmallowEpochRejection)
        #expect(exit.recovery(restartAttempts: 0, deviceOnline: false) == .useLegacyFormat)
    }
}

@Suite("logcat arguments")
struct LogcatArgumentsTests {
    @Test func modernFormatSupportedByApiLevel() {
        #expect(ADB.LogcatOptions.modernFormatSupported(apiLevel: nil))
        #expect(!ADB.LogcatOptions.modernFormatSupported(apiLevel: 23))
        #expect(ADB.LogcatOptions.modernFormatSupported(apiLevel: 24))
        #expect(ADB.LogcatOptions.modernFormatSupported(apiLevel: 37))
    }

    @Test func modernArgumentsUseEpochTail() {
        let arguments = ADB.logcatArguments(serial: "s", options: .init(since: 1794248132.663))
        #expect(arguments == ["-s", "s", "logcat", "-v", "long", "-v", "epoch", "-v", "uid", "-T", "1794248132.663"])
    }

    @Test func legacyTailTimeUsesMonthDayForm() throws {
        let tz = try #require(TimeZone(identifier: "America/New_York"))
        let t = try #require(LogcatTime.parse(date: "11-10", time: "14:03:07.123", timeZone: tz))
        let arguments = ADB.logcatArguments(
            serial: "s", options: .init(buffers: ["main"], since: t, modernFormat: false), timeZone: tz
        )
        #expect(arguments == ["-s", "s", "logcat", "-v", "long", "-b", "main", "-T", "11-10 14:03:07.123"])
    }

    @Test func monthDayFormatRoundTrips() throws {
        let tz = try #require(TimeZone(identifier: "America/New_York"))
        let t = try #require(LogcatTime.parse(date: "11-10", time: "14:03:07.123", timeZone: tz))
        #expect(LogcatTime.formatMonthDay(t, timeZone: tz) == "11-10 14:03:07.123")

        // Rounding: .9995 s must carry into the next second rather than print .1000.
        let late = try #require(LogcatTime.parse(date: "11-10", time: "14:03:07.999", timeZone: tz))
        #expect(LogcatTime.formatMonthDay(late, timeZone: tz) == "11-10 14:03:07.999")
        #expect(LogcatTime.formatMonthDay(late + 0.0004, timeZone: tz) == "11-10 14:03:07.999")
        #expect(LogcatTime.formatMonthDay(late + 0.0006, timeZone: tz) == "11-10 14:03:08.000")

        let utc = try #require(TimeZone(identifier: "UTC"))
        let u = try #require(LogcatTime.parse(date: "11-10", time: "14:03:07.123", timeZone: utc))
        #expect(LogcatTime.formatMonthDay(u, timeZone: utc) == "11-10 14:03:07.123")
    }
}
