import Foundation

/// A parsed logcat filter query, using the Android Studio Logcat query syntax.
///
/// Supported terms:
///
/// | Term | Matches |
/// | --- | --- |
/// | `tag:foo` | tag contains `foo` |
/// | `tag=:foo` | tag equals `foo` |
/// | `tag~:fo+` | tag matches the regular expression |
/// | `-tag:foo`, `-tag=:foo`, `-tag~:foo` | negations of the above |
/// | `package:`, `process:`, `message:`, `line:` | same operators, on the package, process name, message, or whole line |
/// | `package:mine` | the packages configured as "my packages" |
/// | `level:WARN` | level is WARN or higher (`V D I W E A` or the full names) |
/// | `age:5m` | logged in the last 5 minutes (`s`, `m`, `h`, `d`) |
/// | `is:crash`, `is:stacktrace` | crash records, records containing a stack trace |
/// | `pid:123`, `tid:123` | process or thread id |
/// | `name:"My filter"` | names the filter; matches everything |
/// | `foo`, `"foo bar"`, `-foo` | free text: contained (or not) anywhere in the line |
///
/// Terms combine with `&`, `|` and parentheses (`&` binds tighter). Without operators, non-negated terms with
/// the same key are ORed and everything else is ANDed, as in Android Studio: `tag:a tag:b level:W` means
/// `(tag:a | tag:b) & level:W`. Adjacent free-text words join into one phrase: `foo bar` matches `foo bar`.
/// Unquoted values end at whitespace, `&` or `|` (regex values only at whitespace, since `|` is alternation).
public struct LogFilter: Sendable {
    public let query: String
    public let caseSensitive: Bool
    /// The value of a `name:` term, if any.
    public let name: String?
    let root: FilterNode?

    /// Whether any term reads the process or package name, so results can change when names resolve.
    public var dependsOnProcessNames: Bool { root?.dependsOnProcessNames ?? false }
    /// Whether an `age:` term is present, so results change over time.
    public var dependsOnTime: Bool { root?.dependsOnTime ?? false }
    /// True for an empty query.
    public var matchesEverything: Bool { root == nil }

    public init(_ query: String, caseSensitive: Bool = false) throws(FilterError) {
        self.query = query
        self.caseSensitive = caseSensitive
        var parser = FilterParser(tokens: try FilterLexer.tokenize(query), caseSensitive: caseSensitive)
        let parsed = try parser.parse()
        self.root = parsed.root
        self.name = parsed.name
    }

    public static let everything = try! LogFilter("")

    public func matches(_ entry: LogEntry, context: FilterContext) -> Bool {
        switch entry.kind {
        case .log: break
        case .marker: return true
        case .process: return matchesProcessMarker(entry, context: context)
        }
        guard let root else { return true }
        var subject = FilterSubject(entry: entry, context: context)
        return root.evaluate(&subject)
    }

    /// A process marker answers only to `package:`, `process:` and `pid:` terms, so `-tag:Noisy` or `level:E`
    /// never hides one. The scope setting decides first whether other apps' markers show at all.
    private func matchesProcessMarker(_ entry: LogEntry, context: FilterContext) -> Bool {
        if context.processMarkers == .mine,
           !context.myPackages.contains(LogEntry.packageName(forProcess: entry.processName ?? "")) {
            return false
        }
        guard let root else { return true }
        var subject = FilterSubject(entry: entry, context: context)
        return root.evaluateForProcessMarker(&subject) ?? true
    }
}

/// Information a filter needs beyond the entry itself.
public struct FilterContext: Sendable {
    /// pid -> full process name, for entries whose process was not known at ingestion.
    public var processNames: [Int32: String]
    /// Packages that `package:mine` matches. Empty means `package:mine` matches everything.
    public var myPackages: Set<String>
    /// Reference time for `age:`, seconds since 1970.
    public var now: Double
    /// Owners of app uids, for entries whose process was never named.
    public var packages: PackageUIDMap
    /// Which apps' process markers pass. `.mine` with no packages hides them all.
    public var processMarkers: ProcessMarkerScope

    public init(
        processNames: [Int32: String] = [:],
        myPackages: Set<String> = [],
        now: Double = Date().timeIntervalSince1970,
        packages: PackageUIDMap = PackageUIDMap(),
        processMarkers: ProcessMarkerScope = .all
    ) {
        self.processNames = processNames
        self.myPackages = myPackages
        self.now = now
        self.packages = packages
        self.processMarkers = processMarkers
    }
}

public struct FilterError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    /// Character offset into the query where the problem is, when known.
    public let offset: Int?

    public init(_ message: String, offset: Int? = nil) {
        self.message = message
        self.offset = offset
    }

    public var description: String { message }
}

/// The keys a term can filter on.
public enum FilterKey: String, Sendable, CaseIterable {
    case tag
    case package
    case process
    case message
    case line
    case level
    case age
    case `is`
    case name
    case pid
    case tid

    /// Keys that take a text value and support `:`, `=:` and `~:`.
    var isText: Bool {
        switch self {
        case .tag, .package, .process, .message, .line: true
        default: false
        }
    }
}

// MARK: - Lexer

enum FilterToken: Equatable {
    enum Operator: Equatable { case contains, exact, regex }

    case leftParen
    case rightParen
    case and
    case or
    case term(key: FilterKey, op: Operator, value: String, negated: Bool, offset: Int)
    case text(value: String, negated: Bool, quoted: Bool, offset: Int)
}

enum FilterLexer {
    static func tokenize(_ query: String) throws(FilterError) -> [FilterToken] {
        let chars = Array(query)
        var tokens: [FilterToken] = []
        var i = 0
        var openParens = 0

        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace {
                i += 1
                continue
            }
            switch c {
            case "(":
                tokens.append(.leftParen)
                openParens += 1
                i += 1
                continue
            case ")":
                tokens.append(.rightParen)
                openParens -= 1
                i += 1
                continue
            case "&":
                tokens.append(.and)
                i += (i + 1 < chars.count && chars[i + 1] == "&") ? 2 : 1
                continue
            case "|":
                tokens.append(.or)
                i += (i + 1 < chars.count && chars[i + 1] == "|") ? 2 : 1
                continue
            default:
                break
            }

            let start = i
            var negated = false
            if c == "-", i + 1 < chars.count, !chars[i + 1].isWhitespace {
                negated = true
                i += 1
            }

            if let (key, op, valueStart) = matchKey(chars, at: i) {
                i = valueStart
                let value: String
                var trailingParens = 0
                if i < chars.count, chars[i] == "\"" || chars[i] == "'" {
                    value = try readQuoted(chars, at: &i)
                } else {
                    // Regular expressions use `|` themselves, so only whitespace ends them.
                    let raw = readBare(chars, at: &i, stopAtOperators: op != .regex)
                    (value, trailingParens) = splitTrailingParens(raw, openParens: openParens)
                }
                if value.isEmpty, key != .name {
                    throw FilterError("Missing value for \(key.rawValue)", offset: start)
                }
                tokens.append(.term(key: key, op: op, value: value, negated: negated, offset: start))
                appendRightParens(trailingParens, to: &tokens, openParens: &openParens)
                continue
            }

            if i < chars.count, chars[i] == "\"" || chars[i] == "'" {
                let value = try readQuoted(chars, at: &i)
                tokens.append(.text(value: value, negated: negated, quoted: true, offset: start))
                continue
            }
            let raw = readBare(chars, at: &i, stopAtOperators: true)
            let (value, trailingParens) = splitTrailingParens(raw, openParens: openParens)
            if !value.isEmpty {
                tokens.append(.text(value: value, negated: negated, quoted: false, offset: start))
            } else if negated {
                tokens.append(.text(value: "-", negated: false, quoted: false, offset: start))
            }
            appendRightParens(trailingParens, to: &tokens, openParens: &openParens)
        }
        return tokens
    }

    /// Recognises `key:`, `key=:` and `key~:` at `index`. Returns the key, operator and where the value starts.
    private static func matchKey(_ chars: [Character], at index: Int) -> (FilterKey, FilterToken.Operator, Int)? {
        var j = index
        while j < chars.count, chars[j].isLetter {
            j += 1
        }
        guard j > index, j < chars.count,
              let key = FilterKey(rawValue: String(chars[index..<j]).lowercased())
        else { return nil }
        if chars[j] == ":" {
            return (key, .contains, j + 1)
        }
        if j + 1 < chars.count, chars[j + 1] == ":", key.isText {
            if chars[j] == "=" { return (key, .exact, j + 2) }
            if chars[j] == "~" { return (key, .regex, j + 2) }
        }
        return nil
    }

    private static func readQuoted(_ chars: [Character], at i: inout Int) throws(FilterError) -> String {
        let quote = chars[i]
        let start = i
        i += 1
        var value = ""
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                value.append(chars[i + 1])
                i += 2
                continue
            }
            if c == quote {
                i += 1
                return value
            }
            value.append(c)
            i += 1
        }
        throw FilterError("Unterminated quote", offset: start)
    }

    private static func readBare(_ chars: [Character], at i: inout Int, stopAtOperators: Bool) -> String {
        var value = ""
        while i < chars.count, !chars[i].isWhitespace {
            if stopAtOperators, chars[i] == "&" || chars[i] == "|" {
                break
            }
            if chars[i] == "\\", i + 1 < chars.count {
                value.append(chars[i + 1])
                i += 2
                continue
            }
            value.append(chars[i])
            i += 1
        }
        return value
    }

    /// An unquoted value runs to the next whitespace, so `(tag:a | tag:b)` would read `b)` as the value.
    /// Peel off trailing `)` that close a group opened earlier and are not balanced inside the value itself.
    private static func splitTrailingParens(_ raw: String, openParens: Int) -> (String, Int) {
        var value = Substring(raw)
        var count = 0
        while value.hasSuffix(")"), count < openParens {
            let opens = value.filter { $0 == "(" }.count
            let closes = value.filter { $0 == ")" }.count
            guard closes > opens else { break }
            value = value.dropLast()
            count += 1
        }
        return (String(value), count)
    }

    private static func appendRightParens(_ count: Int, to tokens: inout [FilterToken], openParens: inout Int) {
        for _ in 0..<count {
            tokens.append(.rightParen)
            openParens -= 1
        }
    }
}

// MARK: - AST

struct CompiledRegex: @unchecked Sendable {
    // NSRegularExpression is immutable and thread-safe.
    let regex: NSRegularExpression

    func matches(_ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

enum TextMatcher: Sendable {
    case contains(String, caseSensitive: Bool)
    case exact(String, caseSensitive: Bool)
    case regex(CompiledRegex)

    func matches(_ text: String) -> Bool {
        switch self {
        case let .contains(needle, caseSensitive):
            return caseSensitive
                ? text.contains(needle)
                : text.range(of: needle, options: [.caseInsensitive, .literal]) != nil
        case let .exact(value, caseSensitive):
            return caseSensitive
                ? text == value
                : text.compare(value, options: [.caseInsensitive, .literal]) == .orderedSame
        case let .regex(regex):
            return regex.matches(text)
        }
    }
}

enum TextField: Sendable {
    case tag, package, process, message, line
}

enum FilterPredicate: Sendable {
    case text(TextField, TextMatcher)
    case myPackages
    case minLevel(LogLevel)
    case maxAge(seconds: Double)
    case crash
    case stacktrace
    case pid(Int32)
    case tid(Int32)
    case always
}

indirect enum FilterNode: Sendable {
    case predicate(FilterPredicate)
    case not(FilterNode)
    case and([FilterNode])
    case or([FilterNode])

    var dependsOnProcessNames: Bool {
        switch self {
        case let .predicate(predicate):
            switch predicate {
            case .text(.package, _), .text(.process, _), .text(.line, _), .myPackages: true
            default: false
            }
        case let .not(node): node.dependsOnProcessNames
        case let .and(nodes), let .or(nodes): nodes.contains { $0.dependsOnProcessNames }
        }
    }

    var dependsOnTime: Bool {
        switch self {
        case let .predicate(predicate):
            if case .maxAge = predicate { true } else { false }
        case let .not(node): node.dependsOnTime
        case let .and(nodes), let .or(nodes): nodes.contains { $0.dependsOnTime }
        }
    }

    func evaluate(_ subject: inout FilterSubject) -> Bool {
        switch self {
        case let .predicate(predicate):
            return subject.matches(predicate)
        case let .not(node):
            return !node.evaluate(&subject)
        case let .and(nodes):
            for node in nodes where !node.evaluate(&subject) {
                return false
            }
            return true
        case let .or(nodes):
            for node in nodes where node.evaluate(&subject) {
                return true
            }
            return false
        }
    }
}

/// Lazily computed views of one entry, so a filter pays only for the fields it reads.
struct FilterSubject {
    let entry: LogEntry
    let context: FilterContext
    private var cachedProcess: String??
    private var cachedLine: String?

    init(entry: LogEntry, context: FilterContext) {
        self.entry = entry
        self.context = context
    }

    mutating func process() -> String? {
        if let cachedProcess { return cachedProcess }
        let value = entry.processName ?? context.processNames[entry.pid]
        cachedProcess = .some(value)
        return value
    }

    /// Whether any package the entry may belong to passes `test`: its process name's package, or, when the
    /// process was never named, each package that owns its uid.
    mutating func anyPackage(_ test: (String) -> Bool) -> Bool {
        if let process = process() { return test(LogEntry.packageName(forProcess: process)) }
        guard let owner = context.packages.owner(forUID: entry.uid) else { return false }
        return owner.packages.contains(where: test)
    }

    mutating func line() -> String {
        if let cachedLine { return cachedLine }
        let line = "\(entry.pid)-\(entry.tid) \(entry.tag) \(process() ?? "") \(entry.level.letter) \(entry.message)"
        cachedLine = line
        return line
    }

    mutating func matches(_ predicate: FilterPredicate) -> Bool {
        switch predicate {
        case let .text(field, matcher):
            switch field {
            case .tag: return matcher.matches(entry.tag)
            case .message: return matcher.matches(entry.message)
            case .line: return matcher.matches(line())
            case .process: return process().map(matcher.matches) ?? false
            case .package: return anyPackage(matcher.matches)
            }
        case .myPackages:
            let mine = context.myPackages
            if mine.isEmpty { return true }
            return anyPackage { mine.contains($0) }
        case let .minLevel(level):
            return entry.level >= level
        case let .maxAge(seconds):
            return entry.timestamp >= context.now - seconds
        case .crash:
            return LogClassifier.isCrash(entry)
        case .stacktrace:
            return LogClassifier.containsStackTrace(entry.message)
        case let .pid(pid):
            return entry.pid == pid
        case let .tid(tid):
            return entry.tid == tid
        case .always:
            return true
        }
    }
}

// MARK: - Parser

struct FilterParser {
    private let tokens: [FilterToken]
    private let caseSensitive: Bool
    private var position = 0
    private(set) var name: String?

    init(tokens: [FilterToken], caseSensitive: Bool) {
        self.tokens = tokens
        self.caseSensitive = caseSensitive
    }

    mutating func parse() throws(FilterError) -> (root: FilterNode?, name: String?) {
        guard !tokens.isEmpty else { return (nil, nil) }
        let node = try parseOr()
        if position < tokens.count {
            throw FilterError(tokens[position] == .rightParen ? "Unbalanced )" : "Unexpected input")
        }
        return (simplify(node), name)
    }

    private var current: FilterToken? { position < tokens.count ? tokens[position] : nil }

    private mutating func parseOr() throws(FilterError) -> FilterNode {
        var nodes = [try parseAnd()]
        while current == .or {
            position += 1
            nodes.append(try parseAnd())
        }
        return nodes.count == 1 ? nodes[0] : .or(nodes)
    }

    private mutating func parseAnd() throws(FilterError) -> FilterNode {
        var nodes = [try parseSequence()]
        while current == .and {
            position += 1
            nodes.append(try parseSequence())
        }
        return nodes.count == 1 ? nodes[0] : .and(nodes)
    }

    /// A run of terms with no explicit operator between them.
    private mutating func parseSequence() throws(FilterError) -> FilterNode {
        var groups: [FilterKey: [FilterNode]] = [:]
        var groupOrder: [FilterKey] = []
        var others: [FilterNode] = []
        var pendingText: [String] = []

        func flushText() {
            guard !pendingText.isEmpty else { return }
            others.append(.predicate(.text(.line, .contains(pendingText.joined(separator: " "), caseSensitive: caseSensitive))))
            pendingText.removeAll()
        }

        var sawAny = false
        loop: while let token = current {
            switch token {
            case .or, .and, .rightParen:
                break loop
            case .leftParen:
                position += 1
                let inner = try parseOr()
                guard current == .rightParen else { throw FilterError("Missing )") }
                position += 1
                flushText()
                others.append(inner)
            case let .text(value, negated, quoted, _):
                position += 1
                if negated {
                    flushText()
                    others.append(.not(.predicate(.text(.line, .contains(value, caseSensitive: caseSensitive)))))
                } else if quoted {
                    flushText()
                    others.append(.predicate(.text(.line, .contains(value, caseSensitive: caseSensitive))))
                } else {
                    pendingText.append(value)
                }
            case let .term(key, op, value, negated, offset):
                position += 1
                flushText()
                if key == .name {
                    name = value
                    sawAny = true
                    continue
                }
                let node = try predicate(key: key, op: op, value: value, offset: offset)
                if negated {
                    others.append(.not(node))
                } else {
                    if groups[key] == nil { groupOrder.append(key) }
                    groups[key, default: []].append(node)
                }
            }
            sawAny = true
        }
        flushText()

        var nodes: [FilterNode] = groupOrder.map { key in
            let group = groups[key]!
            return group.count == 1 ? group[0] : .or(group)
        }
        nodes += others
        if nodes.isEmpty {
            if sawAny { return .predicate(.always) }
            throw FilterError(current == nil ? "Expected a term at the end" : "Expected a term")
        }
        return nodes.count == 1 ? nodes[0] : .and(nodes)
    }

    private func predicate(key: FilterKey, op: FilterToken.Operator, value: String, offset: Int) throws(FilterError) -> FilterNode {
        switch key {
        case .tag, .package, .process, .message, .line:
            if key == .package, op == .contains, value == "mine" {
                return .predicate(.myPackages)
            }
            let field: TextField = switch key {
            case .tag: .tag
            case .package: .package
            case .process: .process
            case .message: .message
            default: .line
            }
            return .predicate(.text(field, try matcher(op: op, value: value, offset: offset)))
        case .level:
            guard let level = LogLevel(name: value) else {
                throw FilterError("Unknown level \"\(value)\". Use VERBOSE, DEBUG, INFO, WARN, ERROR or ASSERT.", offset: offset)
            }
            return .predicate(.minLevel(level))
        case .age:
            guard let seconds = Self.parseAge(value) else {
                throw FilterError("Invalid age \"\(value)\". Use a number followed by s, m, h or d, e.g. age:5m.", offset: offset)
            }
            return .predicate(.maxAge(seconds: seconds))
        case .is:
            switch value.lowercased() {
            case "crash": return .predicate(.crash)
            case "stacktrace": return .predicate(.stacktrace)
            default: throw FilterError("Unknown is:\(value). Use is:crash or is:stacktrace.", offset: offset)
            }
        case .pid, .tid:
            guard let number = Int32(value) else {
                throw FilterError("\(key.rawValue): needs a number", offset: offset)
            }
            return .predicate(key == .pid ? .pid(number) : .tid(number))
        case .name:
            return .predicate(.always)
        }
    }

    private func matcher(op: FilterToken.Operator, value: String, offset: Int) throws(FilterError) -> TextMatcher {
        switch op {
        case .contains:
            return .contains(value, caseSensitive: caseSensitive)
        case .exact:
            return .exact(value, caseSensitive: caseSensitive)
        case .regex:
            do {
                let regex = try NSRegularExpression(pattern: value, options: caseSensitive ? [] : [.caseInsensitive])
                return .regex(CompiledRegex(regex: regex))
            } catch {
                throw FilterError("Invalid regular expression \"\(value)\"", offset: offset)
            }
        }
    }

    static func parseAge(_ text: String) -> Double? {
        guard let unit = text.last, let amount = Double(text.dropLast()), amount >= 0 else { return nil }
        switch unit {
        case "s": return amount
        case "m": return amount * 60
        case "h": return amount * 3600
        case "d": return amount * 86400
        default: return nil
        }
    }

    private func simplify(_ node: FilterNode) -> FilterNode? {
        if case .predicate(.always) = node { return nil }
        return node
    }
}

// MARK: - Process markers

extension FilterNode {
    /// Evaluates a query against a process marker, which has no tag, message or level: only `package:`,
    /// `process:` and `pid:` terms (and `package:mine`) give an answer, and every other term is neutral (nil).
    /// `not` keeps neutral, `and` / `or` ignore neutral children, and a neutral query shows the marker.
    func evaluateForProcessMarker(_ subject: inout FilterSubject) -> Bool? {
        switch self {
        case let .predicate(predicate):
            switch predicate {
            case .text(.package, _), .text(.process, _), .myPackages, .pid:
                return subject.matches(predicate)
            default:
                return nil
            }
        case let .not(node):
            return node.evaluateForProcessMarker(&subject).map { !$0 }
        case let .and(nodes):
            let results = nodes.compactMap { $0.evaluateForProcessMarker(&subject) }
            return results.isEmpty ? nil : results.allSatisfy { $0 }
        case let .or(nodes):
            let results = nodes.compactMap { $0.evaluateForProcessMarker(&subject) }
            return results.isEmpty ? nil : results.contains(true)
        }
    }
}
