import Foundation

/// Heuristics for recognising crashes and stack traces, used by `is:crash` and `is:stacktrace`.
public enum LogClassifier {
    private static let nativeCrashTags: Set<String> = ["DEBUG", "libc", "crash_dump", "crash_dump64", "crash_dump32", "tombstoned"]

    /// A Java/Kotlin crash (`FATAL EXCEPTION` from AndroidRuntime), a native crash (fatal-level records from
    /// the crash reporters), or an ANR report.
    public static func isCrash(_ entry: LogEntry) -> Bool {
        switch entry.level {
        case .error:
            if entry.tag == "AndroidRuntime" {
                return entry.message.hasPrefix("FATAL EXCEPTION") || entry.message.contains("\nFATAL EXCEPTION")
            }
            if entry.tag == "ActivityManager" {
                return entry.message.hasPrefix("ANR in ")
            }
            return false
        case .assert:
            return nativeCrashTags.contains(entry.tag) || entry.tag == "AndroidRuntime"
        default:
            return false
        }
    }

    /// Whether a message contains Java stack frames (`at com.foo.Bar.baz(Bar.kt:12)`) or a native backtrace
    /// frame (`#00 pc 0000000000012345  /system/lib64/libc.so`).
    public static func containsStackTrace(_ message: String) -> Bool {
        var found = false
        message.enumerateLines { line, stop in
            if isStackFrame(line) {
                found = true
                stop = true
            }
        }
        return found
    }

    public static func isStackFrame<S: StringProtocol>(_ line: S) -> Bool {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        if trimmed.hasPrefix("at "), trimmed.contains("("), trimmed.hasSuffix(")") {
            return true
        }
        if trimmed.hasPrefix("#"), trimmed.contains(" pc ") {
            return true
        }
        return false
    }
}
