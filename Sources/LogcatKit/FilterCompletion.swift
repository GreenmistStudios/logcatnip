import Foundation

/// What the cursor is completing, found from the lenient token stream so it works on half-typed queries.
public struct FilterCompletionContext: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Nothing to complete: inside quoted free text, after a closing quote, or right after `)`.
        case none
        /// A key or a whole term such as `is:crash`. `inTerm` means the cursor is in the key of an existing
        /// `key:value` term, so only bare keys fit: no whole terms and no history.
        case key(inTerm: Bool)
        /// A value for `key`.
        case value(key: FilterKey, op: FilterOperator, negated: Bool)
    }

    public let kind: Kind
    /// What the user typed that a suggestion must start with: unescaped, without quotes.
    public let prefix: String
    /// The characters an accepted key or value replaces, as character offsets.
    public let replacement: Range<Int>
    /// Length of the query in characters, so suggestions know whether the replacement reaches the end.
    public let queryLength: Int
}

public struct FilterSuggestion: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A bare key such as `tag:`; accepting it leaves the cursor ready for a value.
        case key
        /// A whole term such as `level:warn` or `package:mine`.
        case term
        /// A value for the key at the cursor.
        case value
        /// A saved filter that replaces the whole query.
        case history
    }

    public let kind: Kind
    /// Shown in the list: `tag:`, `com.example.app`, `1234`, a whole history query.
    public let label: String
    /// Shown dimmed after the label: what the key does, an entry count, a pid's process name.
    public let detail: String?
    /// Replaces `replacement`. Values are quoted when needed. A value or term that reaches the end of the query
    /// ends with a space, so the next word can start straight away.
    public let insertion: String
    public let replacement: Range<Int>

    /// The query with the suggestion applied and the cursor after the insertion. The field edits through
    /// `NSTextView` instead so the change is undoable; this is for tests and debug output.
    public func applied(to query: String) -> (query: String, cursor: Int) {
        var chars = Array(query)
        let lower = min(replacement.lowerBound, chars.count)
        let upper = min(replacement.upperBound, chars.count)
        chars.replaceSubrange(lower..<upper, with: Array(insertion))
        return (String(chars), lower + insertion.count)
    }
}

public struct FilterPidInfo: Sendable, Equatable {
    public let pid: Int32
    public let count: Int
    public let processName: String?

    public init(pid: Int32, count: Int, processName: String?) {
        self.pid = pid
        self.count = count
        self.processName = processName
    }
}

/// What a session knows that suggestions draw on, gathered once per keystroke.
public struct FilterCompletionSource: Sendable {
    /// Entries seen per tag.
    public var tagCounts: [String: Int]
    /// Entries seen per full process name.
    public var processCounts: [String: Int]
    /// Process names from the latest `ps`.
    public var runningProcesses: [String]
    public var pids: [FilterPidInfo]
    /// The packages `package:mine` stands for, for its description.
    public var myPackages: [String]
    /// Favorites, then recent filters. Empty unless the history setting is on.
    public var history: [String]

    public init(
        tagCounts: [String: Int] = [:],
        processCounts: [String: Int] = [:],
        runningProcesses: [String] = [],
        pids: [FilterPidInfo] = [],
        myPackages: [String] = [],
        history: [String] = []
    ) {
        self.tagCounts = tagCounts
        self.processCounts = processCounts
        self.runningProcesses = runningProcesses
        self.pids = pids
        self.myPackages = myPackages
        self.history = history
    }
}

public enum FilterCompletion {
    /// What `cursor` (a character offset, clamped to the query) is completing.
    public static func completionContext(query: String, cursor: Int) -> FilterCompletionContext {
        let chars = Array(query)
        let cursor = min(max(cursor, 0), chars.count)
        func make(_ kind: FilterCompletionContext.Kind, _ prefix: String, _ replacement: Range<Int>) -> FilterCompletionContext {
            // Android Studio does not offer keys right after `)` or a quote (its NON_KEY_MARKER).
            if case .key = kind, replacement.lowerBound > 0, ")\"'".contains(chars[replacement.lowerBound - 1]) {
                return FilterCompletionContext(kind: .none, prefix: "", replacement: cursor..<cursor, queryLength: chars.count)
            }
            return FilterCompletionContext(kind: kind, prefix: prefix, replacement: replacement, queryLength: chars.count)
        }

        // The token the cursor is in or just after. Whitespace, the start of the query and a token's first
        // character leave no token, which is a fresh key position.
        let tokens = FilterLexer.scan(query).tokens
        guard let located = tokens.first(where: { $0.range.lowerBound < cursor && cursor <= $0.range.upperBound }) else {
            return make(.key(inTerm: false), "", cursor..<cursor)
        }

        switch located.token {
        case .leftParen, .and, .or:
            return make(.key(inTerm: false), "", cursor..<cursor)
        case .rightParen:
            return make(.none, "", cursor..<cursor)
        case let .text(_, _, quoted, _):
            if quoted { return make(.none, "", cursor..<cursor) }
            // A key never eats the text after the cursor, so `ta|xyz` inserts before `xyz`.
            let start = located.range.lowerBound
            return make(.key(inTerm: false), String(chars[start..<cursor]), start..<cursor)
        case let .term(key, op, _, negated, _):
            let value = located.valueRange ?? located.range.upperBound..<located.range.upperBound
            if cursor < value.lowerBound {
                // The whole key goes, with its operator: `ta|g:foo` -> `tag=:foo`.
                let start = located.range.lowerBound
                return make(.key(inTerm: true), String(chars[start..<cursor]), start..<value.lowerBound)
            }
            let quoted = !value.isEmpty && (chars[value.lowerBound] == "\"" || chars[value.lowerBound] == "'")
            if quoted {
                if located.terminated, cursor == value.upperBound {
                    return make(.none, "", cursor..<cursor)
                }
                let typedFrom = min(value.lowerBound + 1, cursor)
                return make(.value(key: key, op: op, negated: negated), unescaped(chars[typedFrom..<cursor]), value)
            }
            return make(.value(key: key, op: op, negated: negated), unescaped(chars[value.lowerBound..<cursor]), value)
        }
    }

    /// Suggestions for a context, best first, at most `limit`.
    public static func suggestions(
        for context: FilterCompletionContext,
        query: String,
        source: FilterCompletionSource,
        limit: Int = 100
    ) -> [FilterSuggestion] {
        let reachesEnd = context.replacement.upperBound == context.queryLength
        switch context.kind {
        case .none:
            return []
        case let .key(inTerm):
            var result = keySuggestions(context, inTerm: inTerm, reachesEnd: reachesEnd, source: source)
            if !inTerm { result += historySuggestions(context, query: query, source: source) }
            return Array(result.prefix(limit))
        case let .value(key, op, _):
            let matcher = PrefixMatcher(context.prefix)
            let values = values(for: key, op: op, matcher: matcher, source: source, limit: limit)
            return values.map { value in
                FilterSuggestion(
                    kind: .value,
                    label: value.label,
                    detail: value.detail,
                    insertion: FilterQueryEditor.quoted(value.label) + (reachesEnd ? " " : ""),
                    replacement: context.replacement
                )
            }
        }
    }

    /// Both steps, which is what the field runs on every keystroke.
    public static func suggestions(
        query: String,
        cursor: Int,
        source: FilterCompletionSource,
        limit: Int = 100
    ) -> [FilterSuggestion] {
        let context = completionContext(query: query, cursor: cursor)
        return suggestions(for: context, query: query, source: source, limit: limit)
    }

    // MARK: Keys

    private static func keySuggestions(
        _ context: FilterCompletionContext,
        inTerm: Bool,
        reachesEnd: Bool,
        source: FilterCompletionSource
    ) -> [FilterSuggestion] {
        let entries: [KeyEntry]
        if inTerm {
            entries = KeyCatalog.bareKeys
        } else if context.prefix.isEmpty {
            entries = KeyCatalog.baseKeys
        } else {
            entries = KeyCatalog.allKeys
        }
        let matcher = PrefixMatcher(context.prefix)
        var result: [FilterSuggestion] = []
        for entry in entries where matcher.matches(entry.text) {
            result.append(FilterSuggestion(
                kind: entry.isTerm ? .term : .key,
                label: entry.text,
                detail: entry.isMine ? mineDescription(source.myPackages) : entry.detail,
                // A key waits for its value, so it never gets a space; a whole term is finished.
                insertion: entry.isTerm && reachesEnd ? entry.text + " " : entry.text,
                replacement: context.replacement
            ))
        }
        return result
    }

    /// Saved filters that start with what has been typed. Accepting one replaces the whole field: Android Studio
    /// inserts it at the current word, which can leave a broken query.
    private static func historySuggestions(
        _ context: FilterCompletionContext,
        query: String,
        source: FilterCompletionSource
    ) -> [FilterSuggestion] {
        guard !source.history.isEmpty else { return [] }
        let chars = Array(query)
        // Key contexts outside a term always end at the cursor.
        let cursor = min(context.replacement.upperBound, chars.count)
        let typed = String(chars[..<cursor]).drop(while: \.isWhitespace)
        let current = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matcher = PrefixMatcher(String(typed))
        var seen: Set<String> = []
        var result: [FilterSuggestion] = []
        for item in source.history where !item.isEmpty && item != current && matcher.matches(item) {
            guard seen.insert(item).inserted else { continue }
            result.append(FilterSuggestion(
                kind: .history,
                label: item,
                detail: "Saved filter",
                insertion: item,
                replacement: 0..<context.queryLength
            ))
            if result.count == 10 { break }
        }
        return result
    }

    private static func mineDescription(_ packages: [String]) -> String {
        guard !packages.isEmpty else { return "My packages (none set; matches everything)" }
        let sorted = packages.sorted()
        let shown = sorted.prefix(3).joined(separator: ", ")
        return "My packages: " + shown + (sorted.count > 3 ? ", …" : "")
    }

    // MARK: Values

    private typealias Value = (label: String, detail: String?)

    private static func values(
        for key: FilterKey,
        op: FilterOperator,
        matcher: PrefixMatcher,
        source: FilterCompletionSource,
        limit: Int
    ) -> [Value] {
        let result: [Value]
        switch key {
        case .tag: result = tagValues(matcher, source)
        case .package: result = packageValues(matcher, op: op, source)
        case .process: result = processValues(matcher, source)
        case .level: result = levelValues(matcher)
        case .is: result = isValues(matcher)
        case .age: result = ageValues(matcher)
        case .pid: result = pidValues(matcher, source)
        case .message, .line, .name, .tid: result = []
        }
        return Array(result.prefix(limit))
    }

    private static func entryCount(_ count: Int) -> String {
        count == 1 ? "1 entry" : "\(count) entries"
    }

    /// Most frequent first, then alphabetical. One pass over the tags and one sort of the matches, so typing
    /// stays fast with thousands of distinct tags.
    private static func tagValues(_ matcher: PrefixMatcher, _ source: FilterCompletionSource) -> [Value] {
        var matches: [(tag: String, count: Int)] = []
        for (tag, count) in source.tagCounts where matcher.matches(tag) {
            matches.append((tag, count))
        }
        matches.sort { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
        return matches.map { ($0.tag, entryCount($0.count)) }
    }

    private static func packageValues(_ matcher: PrefixMatcher, op: FilterOperator, _ source: FilterCompletionSource) -> [Value] {
        var result: [Value] = []
        // `mine` is only special for `package:`, not for `package=:` or `package~:`.
        if op == .contains, matcher.matches("mine") {
            result.append(("mine", mineDescription(source.myPackages)))
        }
        var counts: [String: Int] = [:]
        for (process, count) in source.processCounts {
            let package = LogEntry.packageName(forProcess: process)
            if isPackageName(package) { counts[package, default: 0] += count }
        }
        let seen = counts.filter { matcher.matches($0.key) }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        result += seen.map { ($0.key, entryCount($0.value)) }
        var running: Set<String> = []
        for process in source.runningProcesses {
            let package = LogEntry.packageName(forProcess: process)
            if isPackageName(package), counts[package] == nil, matcher.matches(package) { running.insert(package) }
        }
        result += running.sorted().map { ($0, "Running") }
        return result
    }

    private static func processValues(_ matcher: PrefixMatcher, _ source: FilterCompletionSource) -> [Value] {
        let seen = source.processCounts
            .filter { matcher.matches($0.key) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        var result: [Value] = seen.map { ($0.key, entryCount($0.value)) }
        var running: Set<String> = []
        for process in source.runningProcesses
        where !process.hasPrefix("[") && source.processCounts[process] == nil && matcher.matches(process) {
            running.insert(process)
        }
        result += running.sorted().map { ($0, "Running") }
        return result
    }

    private static func levelValues(_ matcher: PrefixMatcher) -> [Value] {
        // Lowercase unless the user started typing in uppercase, as Android Studio does.
        let uppercase = matcher.startsUppercase
        return LogLevel.allCases.compactMap { level in
            let name = level.name.lowercased()
            return matcher.matches(name) ? (uppercase ? level.name : name, "\(level.name) or higher") : nil
        }
    }

    private static func isValues(_ matcher: PrefixMatcher) -> [Value] {
        let special: [Value] = [
            ("crash", "Crashes and ANRs"), ("firebase", "Firebase SDK tags"), ("stacktrace", "Entries with a stack trace"),
        ]
        let levels: [Value] = LogLevel.allCases.map { ($0.name.lowercased(), "\($0.name) only") }
        return (special + levels).filter { matcher.matches($0.label) }
    }

    private static func ageValues(_ matcher: PrefixMatcher) -> [Value] {
        let ages: [Value] = [
            ("30s", "The past 30 seconds"), ("5m", "The past 5 minutes"), ("3h", "The past 3 hours"), ("1d", "The past day"),
        ]
        return ages.filter { matcher.matches($0.label) }
    }

    private static func pidValues(_ matcher: PrefixMatcher, _ source: FilterCompletionSource) -> [Value] {
        let typed = matcher.prefix
        let digits = typed.allSatisfy(\.isNumber)
        let ordered = source.pids.sorted { $0.count != $1.count ? $0.count > $1.count : $0.pid < $1.pid }
        return ordered.compactMap { info in
            let matched = digits
                ? String(info.pid).hasPrefix(typed)
                : info.processName?.localizedCaseInsensitiveContains(typed) == true
            return matched ? (String(info.pid), info.processName) : nil
        }
    }

    /// Android package-like: starts with a letter, has a dot, and holds only letters, digits, `_` and `.`. That
    /// drops binary paths, kernel threads and HAL services, which show up as process names too.
    private static func isPackageName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter, name.contains(".") else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
    }

    /// The characters with `\x` turned into `x`, which is how the lexer reads a value.
    private static func unescaped(_ chars: ArraySlice<Character>) -> String {
        var result = ""
        var index = chars.startIndex
        while index < chars.endIndex {
            if chars[index] == "\\", index + 1 < chars.endIndex {
                result.append(chars[index + 1])
                index += 2
            } else {
                result.append(chars[index])
                index += 1
            }
        }
        return result
    }
}

/// Case-insensitive prefix test that allocates nothing per candidate when the prefix is ASCII, which keeps a
/// keystroke over thousands of tags cheap.
private struct PrefixMatcher {
    let prefix: String
    private let lowered: String
    private let asciiBytes: [UInt8]?

    init(_ prefix: String) {
        self.prefix = prefix
        self.lowered = prefix.lowercased()
        let bytes = Array(prefix.utf8)
        self.asciiBytes = bytes.allSatisfy { $0 < 0x80 } ? bytes.map(Self.lowercase) : nil
    }

    var startsUppercase: Bool { prefix.first?.isUppercase == true }

    private static func lowercase(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
    }

    func matches(_ candidate: String) -> Bool {
        if prefix.isEmpty { return true }
        guard let asciiBytes else { return candidate.lowercased().hasPrefix(lowered) }
        var index = 0
        for byte in candidate.utf8 {
            if Self.lowercase(byte) != asciiBytes[index] { return false }
            index += 1
            if index == asciiBytes.count { return true }
        }
        return false
    }
}

// MARK: - Key catalog

private struct KeyEntry {
    let text: String
    let detail: String
    let isTerm: Bool
    var isMine = false
}

private enum KeyCatalog {
    private static let textKeys: [(key: String, subject: String)] = [
        ("tag", "Log tag"), ("package", "Package name"), ("process", "Process name"),
        ("message", "Log message"), ("line", "Log line"),
    ]
    private static let operators: [(suffix: String, phrase: String)] = [
        (":", "contains string"), ("=:", "is exactly string"), ("~:", "matches regex"),
    ]
    private static let negatedOperators: [(suffix: String, phrase: String)] = [
        (":", "does not contain string"), ("=:", "is not exactly string"), ("~:", "does not match regex"),
    ]

    private static let mine = KeyEntry(text: "package:mine", detail: "", isTerm: true, isMine: true)

    private static let plainKeys: [KeyEntry] = [
        KeyEntry(text: "level:", detail: "Minimum log level", isTerm: false),
        KeyEntry(text: "age:", detail: "Maximum age, such as 5m", isTerm: false),
        KeyEntry(text: "is:", detail: "Type of log message", isTerm: false),
        KeyEntry(text: "name:", detail: "Name of this filter", isTerm: false),
        KeyEntry(text: "pid:", detail: "Process id", isTerm: false),
        KeyEntry(text: "tid:", detail: "Thread id", isTerm: false),
    ]

    private static let negatedPlainKeys: [KeyEntry] = [
        KeyEntry(text: "-level:", detail: "Below a log level", isTerm: false),
        KeyEntry(text: "-age:", detail: "Older than an age", isTerm: false),
        KeyEntry(text: "-is:", detail: "Not a type of log message", isTerm: false),
        KeyEntry(text: "-pid:", detail: "Not this process id", isTerm: false),
        KeyEntry(text: "-tid:", detail: "Not this thread id", isTerm: false),
    ]

    private static func textVariants(withMine: Bool) -> [KeyEntry] {
        var result: [KeyEntry] = []
        for (key, subject) in textKeys {
            for (suffix, phrase) in operators {
                result.append(KeyEntry(text: key + suffix, detail: "\(subject) \(phrase)", isTerm: false))
                if withMine, key == "package", suffix == "~:" { result.append(mine) }
            }
        }
        return result
    }

    private static let negatedTextVariants: [KeyEntry] = textKeys.flatMap { key, subject in
        negatedOperators.map { suffix, phrase in
            KeyEntry(text: "-" + key + suffix, detail: "\(subject) \(phrase)", isTerm: false)
        }
    }

    private static let levelTerms: [KeyEntry] = LogLevel.allCases.map {
        KeyEntry(text: "level:" + $0.name.lowercased(), detail: "\($0.name) or higher", isTerm: true)
    }

    private static let isTerms: [KeyEntry] = [
        KeyEntry(text: "is:crash", detail: "Crashes and ANRs", isTerm: true),
        KeyEntry(text: "is:firebase", detail: "Firebase SDK tags", isTerm: true),
        KeyEntry(text: "is:stacktrace", detail: "Entries with a stack trace", isTerm: true),
    ] + LogLevel.allCases.map {
        KeyEntry(text: "is:" + $0.name.lowercased(), detail: "\($0.name) only", isTerm: true)
    }

    /// With nothing typed: one entry per key, then `package:mine`.
    static let baseKeys: [KeyEntry] = {
        let keys = textKeys.map { key, subject in
            KeyEntry(text: key + ":", detail: "\(subject) contains string", isTerm: false)
        }
        return keys + plainKeys + [mine]
    }()

    /// With a prefix: every variant of every key, and the whole terms.
    static let allKeys: [KeyEntry] = textVariants(withMine: true) + plainKeys + levelTerms + isTerms
        + negatedTextVariants + negatedPlainKeys

    /// Inside an existing term: only keys, since the value is already there.
    static let bareKeys: [KeyEntry] = textVariants(withMine: false) + plainKeys + negatedTextVariants + negatedPlainKeys
}
