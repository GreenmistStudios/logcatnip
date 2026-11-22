import Foundation

/// Heuristics for recognising crashes, stack traces and other signals, used by the `is:` filters.
public enum LogClassifier {
    private static let nativeCrashTags: Set<String> = ["DEBUG", "libc", "crash_dump", "crash_dump64", "crash_dump32", "tombstoned"]

    /// The signal an entry reports, if any, using the built-in rules.
    public static func signal(for entry: LogEntry) -> SignalMatch? {
        SignalRuleSet.default.match(entry)
    }

    /// The signal an entry reports under `rules`: the first matching anchor rule, else the first matching
    /// enrichment rule. Build a ``SignalRuleSet`` instead when classifying many entries with custom rules.
    public static func signal(for entry: LogEntry, rules: [SignalRule]) -> SignalMatch? {
        guard entry.kind == .log else { return nil }
        for rule in rules where rule.isAnchor && rule.evaluate(entry) {
            return rule.match
        }
        for rule in rules where !rule.isAnchor && rule.evaluate(entry) {
            return rule.match
        }
        return nil
    }

    /// A Java/Kotlin crash (`FATAL EXCEPTION` from AndroidRuntime), a native crash (fatal-level records from
    /// the crash reporters), or an ANR report.
    ///
    /// This keeps Android Studio's broader meaning (every fatal record from the crash reporters, not just the
    /// first one) so saved `is:crash` filters keep showing whole tombstones, and adds the fatal signal rules,
    /// so an ANR shows up from its first `Input dispatching timed out` line rather than the `ANR in` report
    /// that follows seconds later.
    public static func isCrash(_ entry: LogEntry) -> Bool {
        switch entry.level {
        case .error:
            if entry.tag == "AndroidRuntime" {
                return entry.message.hasPrefix("FATAL EXCEPTION") || entry.message.contains("\nFATAL EXCEPTION")
            }
            if entry.tag == "ActivityManager", entry.message.hasPrefix("ANR in ") {
                return true
            }
        case .assert:
            if nativeCrashTags.contains(entry.tag) || entry.tag == "AndroidRuntime" {
                return true
            }
        default:
            break
        }
        guard let match = signal(for: entry) else { return false }
        return match.isAnchor && match.kind.isFatal
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

    /// A cheap form of ``JavaFrame/parse(_:)`` and ``NativeFrame/parse(_:)`` that doesn't allocate: every
    /// line those parse passes this check.
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

/// A Java or Kotlin stack frame: `at com.example.Foo$Bar.baz(Foo.kt:12)`.
public struct JavaFrame: Sendable, Hashable {
    /// Fully qualified, with `$` for nested and synthetic classes.
    public var className: String
    public var method: String
    /// `nil` for `Native Method` and `Unknown Source`.
    public var file: String?
    public var line: Int?

    public init(className: String, method: String, file: String?, line: Int?) {
        self.className = className
        self.method = method
        self.file = file
        self.line = line
    }

    public static func parse<S: StringProtocol>(_ line: S) -> JavaFrame? {
        var text = Substring(line).drop { $0 == " " || $0 == "\t" }
        guard text.hasPrefix("at "), text.hasSuffix(")") else { return nil }
        text = text.dropFirst(3).dropLast()
        guard let open = text.firstIndex(of: "(") else { return nil }
        let qualified = text[..<open]
        guard let dot = qualified.lastIndex(of: "."), dot > qualified.startIndex,
              qualified.index(after: dot) < qualified.endIndex,
              !qualified.contains(" ")
        else { return nil }
        var className = qualified[..<dot]
        // Java 9+ module prefixes (`java.base/java.lang.Thread`) never appear on Android, but desktop JVM
        // traces pasted into a log do.
        if let slash = className.lastIndex(of: "/") {
            className = className[className.index(after: slash)...]
        }
        let method = String(qualified[qualified.index(after: dot)...])

        let location = text[text.index(after: open)...]
        var file: String?
        var lineNumber: Int?
        if let colon = location.lastIndex(of: ":"), let number = Int(location[location.index(after: colon)...]) {
            file = String(location[..<colon])
            lineNumber = number
        } else {
            file = String(location)
        }
        if file == "Unknown Source" || file == "Native Method" || file?.isEmpty == true {
            file = nil
        }
        return JavaFrame(className: String(className), method: method, file: file, line: lineNumber)
    }

    /// The class name without its package: `MainActivity$onCreate$1`.
    public var simpleClassName: String {
        className.lastIndex(of: ".").map { String(className[className.index(after: $0)...]) } ?? className
    }

    /// `MainActivity.onCreate (MainActivity.kt:42)`, as crash signatures show it.
    public var displayText: String {
        let location = switch (file, line) {
        case let (file?, line?): "\(file):\(line)"
        case let (file?, nil): file
        case (nil, _): "Unknown Source"
        }
        return "\(simpleClassName).\(method) (\(location))"
    }
}

/// A native backtrace frame from a tombstone:
/// `#00 pc 000000000004f0c8  /apex/com.android.runtime/lib64/bionic/libc.so (abort+164) (BuildId: …)`.
public struct NativeFrame: Sendable, Hashable {
    public var index: Int
    /// The program counter, relative to the library, as printed (hex digits without `0x`).
    public var pc: String
    /// The mapped file (`/data/app/…/libnative.so`, `base.apk!libnative.so`) or a name like
    /// `[anon:dalvik-jit-code-cache]`.
    public var library: String
    /// The function and offset (`crashMe+20`), when the frame was symbolized.
    public var symbol: String?

    public init(index: Int, pc: String, library: String, symbol: String?) {
        self.index = index
        self.pc = pc
        self.library = library
        self.symbol = symbol
    }

    public static func parse<S: StringProtocol>(_ line: S) -> NativeFrame? {
        var text = Substring(line).drop { $0 == " " || $0 == "\t" }
        guard text.hasPrefix("#") else { return nil }
        text = text.dropFirst()
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        guard let index = Int(digits) else { return nil }
        text = text.dropFirst(digits.count)
        guard text.hasPrefix(" pc ") else { return nil }
        text = text.dropFirst(4).drop { $0 == " " }
        let pc = text.prefix { $0.isHexDigit }
        guard !pc.isEmpty else { return nil }
        text = text.dropFirst(pc.count)
        guard text.first == " " else { return nil }
        text = text.drop { $0 == " " }

        // The library runs to the first " (" group; the groups after it are the symbol, `offset 0x…` and
        // `BuildId: …`. Symbols can hold parentheses themselves (`foo(int)+12`), so groups are matched by depth.
        let libraryEnd = text.range(of: " (")?.lowerBound ?? text.endIndex
        let library = text[..<libraryEnd].trimmingTrailingSpaces()
        guard !library.isEmpty else { return nil }
        var symbol: String?
        for group in parenthesizedGroups(text[libraryEnd...]) {
            if group.hasPrefix("offset 0x") || group.hasPrefix("BuildId: ") { continue }
            symbol = String(group)
            break
        }
        return NativeFrame(index: index, pc: String(pc), library: String(library), symbol: symbol)
    }

    /// Whether the library ships with the app (`/data/app/…`) rather than the OS.
    public var isAppLibrary: Bool {
        library.hasPrefix("/data/")
    }

    /// The library's file name: `libnative.so`, also for `base.apk!libnative.so`.
    public var libraryName: String {
        var name = Substring(library)
        if let slash = name.lastIndex(of: "/") { name = name[name.index(after: slash)...] }
        if let bang = name.lastIndex(of: "!") { name = name[name.index(after: bang)...] }
        return String(name)
    }

    /// `libnative.so (crashMe+20)`, as crash signatures show it.
    public var displayText: String {
        symbol.map { "\(libraryName) (\($0))" } ?? libraryName
    }

    private static func parenthesizedGroups(_ text: Substring) -> [Substring] {
        var groups: [Substring] = []
        var depth = 0
        var start = text.startIndex
        for index in text.indices {
            switch text[index] {
            case "(":
                if depth == 0 { start = text.index(after: index) }
                depth += 1
            case ")" where depth > 0:
                depth -= 1
                if depth == 0 { groups.append(text[start..<index]) }
            default:
                break
            }
        }
        return groups
    }
}
