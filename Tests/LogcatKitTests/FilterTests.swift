import Foundation
import Testing
@testable import LogcatKit

private func entry(
    tag: String = "Tag",
    message: String = "hello world",
    level: LogLevel = .info,
    pid: Int32 = 100,
    tid: Int32 = 101,
    process: String? = "com.example.app",
    timestamp: Double = 1_000_000
) -> LogEntry {
    LogEntry(timestamp: timestamp, pid: pid, tid: tid, level: level, tag: tag, message: message, processName: process)
}

private func matches(_ query: String, _ entry: LogEntry, caseSensitive: Bool = false, context: FilterContext = FilterContext(now: 1_000_000)) throws -> Bool {
    try LogFilter(query, caseSensitive: caseSensitive).matches(entry, context: context)
}

/// Whether two queries parse to the same tree, after flattening and ordering `&`/`|` operands.
private func sameMeaning(_ a: String, _ b: String, caseSensitive: Bool = false) throws -> Bool {
    try LogFilter(a, caseSensitive: caseSensitive).root?.canonical == LogFilter(b, caseSensitive: caseSensitive).root?.canonical
}

@Suite struct FilterTests {
    @Test func emptyQueryMatchesEverything() throws {
        let filter = try LogFilter("   ")
        #expect(filter.matchesEverything)
        #expect(filter.matches(entry(), context: FilterContext()))
    }

    @Test func tagOperators() throws {
        let e = entry(tag: "ActivityManager")
        #expect(try matches("tag:activity", e))
        #expect(try !matches("tag:activity", e, caseSensitive: true))
        #expect(try matches("tag=:activitymanager", e))
        #expect(try !matches("tag=:Activity", e))
        #expect(try matches("tag~:^Act.*ger$", e))
        #expect(try !matches("-tag:Activity", e))
        #expect(try matches("-tag=:Activity", e))
        #expect(try !matches("-tag~:Manager$", e))
    }

    @Test func packageAndProcess() throws {
        let e = entry(process: "com.example.app:remote")
        #expect(try matches("package:com.example.app", e))
        #expect(try matches("package=:com.example.app", e))
        #expect(try !matches("package=:com.example.app:remote", e))
        #expect(try matches("process=:com.example.app:remote", e))
        #expect(try !matches("package:other", e))
    }

    @Test func packageResolvedFromContext() throws {
        let e = entry(pid: 55, process: nil)
        #expect(try !matches("package:late", e))
        #expect(try matches("package:late", e, context: FilterContext(processNames: [55: "com.late"])))
    }

    @Test func packageMine() throws {
        let e = entry(process: "com.example.app:sync")
        #expect(try matches("package:mine", e, context: FilterContext(myPackages: ["com.example.app"])))
        #expect(try !matches("package:mine", e, context: FilterContext(myPackages: ["com.other"])))
        #expect(try matches("package:mine", e, context: FilterContext(myPackages: [])))
    }

    @Test func levelIsMinimum() throws {
        #expect(try matches("level:WARN", entry(level: .error)))
        #expect(try matches("level:w", entry(level: .warn)))
        #expect(try !matches("level:warn", entry(level: .info)))
        #expect(throws: FilterError.self) { try LogFilter("level:loud") }
    }

    @Test func age() throws {
        let context = FilterContext(now: 1_000_000)
        #expect(try matches("age:5m", entry(timestamp: 1_000_000 - 299), context: context))
        #expect(try !matches("age:5m", entry(timestamp: 1_000_000 - 301), context: context))
        #expect(try matches("age:2h", entry(timestamp: 1_000_000 - 7000), context: context))
        #expect(try LogFilter("age:1d").dependsOnTime)
        #expect(throws: FilterError.self) { try LogFilter("age:soon") }
    }

    @Test func isCrashAndStacktrace() throws {
        let crash = entry(tag: "AndroidRuntime", message: "FATAL EXCEPTION: main\n\tat com.foo.Bar.run(Bar.kt:3)", level: .error)
        #expect(try matches("is:crash", crash))
        #expect(try matches("is:stacktrace", crash))
        #expect(try !matches("is:crash", entry(level: .error)))
        #expect(try matches("is:crash", entry(tag: "DEBUG", message: "pid: 1, tid: 2", level: .assert)))
        #expect(try matches("is:stacktrace", entry(message: "      #00 pc 000000000004f5b4  /apex/libc.so (abort+164)")))
        #expect(throws: FilterError.self) { try LogFilter("is:bad") }
    }

    @Test func isLevelMatchesExactlyThatLevel() throws {
        for level in LogLevel.allCases {
            let query = "is:\(level.name.lowercased())"
            for other in LogLevel.allCases {
                #expect(try matches(query, entry(level: other)) == (other == level), "\(query) vs \(other)")
            }
        }
        #expect(try matches("is:error", entry(level: .error)))
        #expect(try !matches("is:error", entry(level: .warn)))
        #expect(try !matches("is:error", entry(level: .assert)))
        // `level:` is a minimum, `is:` is exact.
        #expect(try matches("level:error", entry(level: .assert)))
        // The same spellings as `level:`.
        #expect(try matches("is:ERROR", entry(level: .error)))
        #expect(try matches("is:e", entry(level: .error)))
        #expect(try !matches("is:e", entry(level: .assert)))
    }

    @Test func isFirebaseMatchesOnlyFirebaseTags() throws {
        for caseSensitive in [false, true] {
            for tag in ["FA", "FirebaseMessaging", "PersistentConnection"] {
                #expect(try matches("is:firebase", entry(tag: tag), caseSensitive: caseSensitive), "\(tag)")
            }
            for tag in ["FAQ", "fa", "MyFirebaseMessaging", "Tag"] {
                #expect(try !matches("is:firebase", entry(tag: tag), caseSensitive: caseSensitive), "\(tag)")
            }
        }
        #expect(FilterPredicate.firebaseTags.count == 25)
    }

    @Test func freeTextMatchesWholeLine() throws {
        let e = entry(tag: "Network", message: "request finished in 20ms")
        #expect(try matches("finished", e))
        #expect(try matches("network", e))
        #expect(try matches("com.example", e))
        #expect(try !matches("-finished", e))
        // Adjacent words form one phrase.
        #expect(try matches("request finished", e))
        #expect(try !matches("finished request", e))
        #expect(try matches("\"in 20ms\"", e))
    }

    @Test func sameKeyTermsAreOredOtherwiseAnded() throws {
        let filter = "tag:Alpha tag:Beta level:WARN"
        #expect(try matches(filter, entry(tag: "Alpha", level: .warn)))
        #expect(try matches(filter, entry(tag: "Beta", level: .error)))
        #expect(try !matches(filter, entry(tag: "Beta", level: .info)))
        #expect(try !matches(filter, entry(tag: "Gamma", level: .error)))
        // Negated terms with the same key are ANDed.
        #expect(try !matches("-tag:Alpha -tag:Beta", entry(tag: "Alpha")))
        #expect(try matches("-tag:Alpha -tag:Beta", entry(tag: "Gamma")))
    }

    @Test func explicitOperatorsAndPrecedence() throws {
        // & binds tighter than |.
        let query = "tag:A & level:ERROR | tag:B"
        #expect(try matches(query, entry(tag: "B", level: .verbose)))
        #expect(try matches(query, entry(tag: "A", level: .error)))
        #expect(try !matches(query, entry(tag: "A", level: .info)))

        let grouped = "tag:A & (level:ERROR | tag:B)"
        #expect(try !matches(grouped, entry(tag: "B", level: .verbose)))
        #expect(try matches("(tag:Alpha | tag:Beta) & -message:skip", entry(tag: "Beta")))
        #expect(try matches("(tag:Alpha||tag:Gamma)&&message:hello", entry(tag: "Alpha")))
    }

    @Test func parenthesesAfterBareValues() throws {
        #expect(try matches("(tag:Zed | tag:Tag)", entry()))
        // A regex with its own balanced parentheses keeps them.
        #expect(try matches("tag~:(Ta|Zz)g", entry()))
        #expect(try matches("(tag~:(Ta|Zz)g)", entry()))
    }

    @Test func quotedValuesAndEscapes() throws {
        let e = entry(message: "hello \"quoted\" world")
        #expect(try matches("message:\"hello \\\"quoted\"", e))
        #expect(try matches("message:'world'", e))
        #expect(try matches("message:hello\\ \"quoted", e))
    }

    @Test func nameIsCapturedAndIgnored() throws {
        let filter = try LogFilter("name:\"My crashes\" is:crash")
        #expect(filter.name == "My crashes")
        #expect(try LogFilter("name:Everything").matchesEverything)
    }

    @Test func pidAndTid() throws {
        #expect(try matches("pid:100", entry()))
        #expect(try matches("tid:101", entry()))
        #expect(try !matches("pid:1", entry()))
    }

    @Test func unknownKeysAreText() throws {
        #expect(try matches("http://example", entry(message: "GET http://example.com")))
    }

    @Test func errors() {
        #expect(throws: FilterError.self) { try LogFilter("tag:") }
        #expect(throws: FilterError.self) { try LogFilter("(tag:a") }
        #expect(throws: FilterError.self) { try LogFilter("tag:a )") }
        #expect(throws: FilterError.self) { try LogFilter("tag~:[unclosed") }
        #expect(throws: FilterError.self) { try LogFilter("message:\"open") }
        #expect(throws: FilterError.self) { try LogFilter("tag:a |") }
    }

    @Test func whitespaceHasLowestPrecedence() throws {
        #expect(try sameMeaning("foo bar tag:bar1 | tag:bar2", "'foo bar' & (tag:bar1 | tag:bar2)"))
        let query = "foo bar tag:bar1 | tag:bar2"
        // The case from the issue: Android Studio does not show a bar2 entry that lacks "foo bar".
        #expect(try !matches(query, entry(tag: "bar2", message: "unrelated")))
        #expect(try matches(query, entry(tag: "bar2", message: "foo bar")))
        #expect(try matches(query, entry(tag: "bar1", message: "foo bar")))
        #expect(try !matches(query, entry(tag: "bar1", message: "unrelated")))
    }

    @Test func androidStudioDocExamples() throws {
        #expect(try sameMeaning("tag:foo tag:bar package:myapp", "(tag:foo | tag:bar) & package:myapp"))
        #expect(try matches("tag:foo tag:bar package:myapp", entry(tag: "bar", process: "myapp")))
        #expect(try !matches("tag:foo tag:bar package:myapp", entry(tag: "baz", process: "myapp")))
        #expect(try !matches("tag:foo tag:bar package:myapp", entry(tag: "foo", process: "other")))

        #expect(try sameMeaning("tag:foo -tag:bar package:myapp", "tag:foo & -tag:bar & package:myapp"))
        #expect(try matches("tag:foo -tag:bar package:myapp", entry(tag: "foo", process: "myapp")))
        #expect(try !matches("tag:foo -tag:bar package:myapp", entry(tag: "foobar", process: "myapp")))

        let mixed = "tag:foo | level:ERROR & package:mine"
        #expect(try sameMeaning(mixed, "tag:foo | (level:ERROR & package:mine)"))
        let context = FilterContext(myPackages: ["com.example.app"], now: 1_000_000)
        #expect(try matches(mixed, entry(tag: "foo", level: .verbose, process: "other"), context: context))
        #expect(try matches(mixed, entry(tag: "x", level: .error), context: context))
        #expect(try !matches(mixed, entry(tag: "x", level: .error, process: "other"), context: context))
    }

    @Test func operatorOperandsAreNotGroupedOrJoined() throws {
        #expect(try sameMeaning("tag:a tag:b & level:E", "tag:a & tag:b & level:E"))
        #expect(try sameMeaning("foo bar | baz", "foo & (bar | baz)"))
        #expect(try sameMeaning("foo bar & baz", "foo & bar & baz"))
        #expect(try sameMeaning("tag:Net | tag:Http level:WARN", "(tag:Net | tag:Http) & level:WARN"))
    }

    @Test func implicitOrGroupsFollowAndroidStudio() throws {
        // Non-negated terms with the same key are ORed.
        #expect(try sameMeaning("level:ERROR is:debug", "level:ERROR | is:debug"))
        #expect(try sameMeaning("is:firebase tag:Foo", "is:firebase | tag:Foo"))
        #expect(try sameMeaning("is:crash is:stacktrace", "is:crash | is:stacktrace"))
        #expect(try sameMeaning("tag:a tag=:b tag~:c", "tag:a | tag=:b | tag~:c"))
        #expect(try sameMeaning("line:x line:y", "line:x | line:y"))
        #expect(try sameMeaning("age:1m age:5m", "age:1m | age:5m"))
        #expect(try sameMeaning("pid:1 pid:2", "pid:1 | pid:2"))
        // Everything else is ANDed.
        #expect(try sameMeaning("is:crash is:error", "is:crash & is:error"))
        #expect(try sameMeaning("package:mine package:foo", "package:mine & package:foo"))
        #expect(try sameMeaning("-tag:a -tag:b", "-tag:a & -tag:b"))
        #expect(try sameMeaning("foo \"bar\"", "foo & \"bar\""))
        #expect(try sameMeaning("tag:a message:b", "tag:a & message:b"))
    }

    @Test func parenthesesHoldSequences() throws {
        #expect(try sameMeaning("(tag:a tag:b level:E) | tag:c", "((tag:a | tag:b) & level:E) | tag:c"))
        #expect(try LogFilter("()").matchesEverything)
        #expect(try matches("tag:Tag & ()", entry()))
        #expect(try !matches("tag:Zed & ()", entry()))
    }

    @Test func nameTermsDropOut() throws {
        #expect(try sameMeaning("tag:a name:x tag:b", "tag:a | tag:b"))
        #expect(try sameMeaning("foo name:x bar", "foo & bar"))
        #expect(try LogFilter("name:N foo bar | baz").name == "N")
        // A name inside an operator expression is an always-true operand, as in Android Studio.
        let filter = try LogFilter("tag:a | name:x")
        #expect(!filter.matchesEverything)
        #expect(filter.matches(entry(tag: "zzz"), context: FilterContext()))
    }

    @Test func errorsUnderTheNewGrammar() {
        for query in ["| tag:a", "tag:a &", "tag:a & | tag:b", "(tag:a", "tag:a )", "tag:a ) (", "is:bad"] {
            #expect(throws: FilterError.self, "\(query)") { try LogFilter(query) }
        }
    }

    private func failure(_ query: String) -> FilterError? {
        do {
            _ = try LogFilter(query)
            return nil
        } catch {
            return error
        }
    }

    @Test func errorsUnderlineTheFailingToken() {
        let cases: [(query: String, underlined: String)] = [
            ("tag:", "tag:"), ("-tag: foo", "-tag:"), ("(tag:)", "tag:"),
            ("level:loud", "loud"), ("age:soon", "soon"), ("is:bad", "bad"), ("pid:x", "x"), ("tid:1.5", "1.5"),
            ("tag~:[unclosed", "[unclosed"), ("level:\"x y\"", "\"x y\""),
            ("message:\"open", "\"open"), ("foo \"open", "\"open"),
            ("(tag:a", "("), ("tag:a (", "("), ("tag:a )", ")"), ("(tag:a | )", ")"),
            ("tag:a |", "|"), ("& tag:a", "&"), ("(tag:a | level:x)", "x"),
            ("tag:é level:ü", "ü"),
        ]
        for (query, underlined) in cases {
            do {
                _ = try LogFilter(query)
                Issue.record("\(query) should not parse")
            } catch {
                guard let range = error.range else {
                    Issue.record("\(query) has no range: \(error.message)")
                    continue
                }
                #expect(String(Array(query)[range]) == underlined, "\(query)")
                #expect(error.offset == range.lowerBound, "\(query)")
            }
        }
        // Offsets count characters, not UTF-16 code units, and point at the second of two equal tokens.
        #expect(failure("tag:é level:ü")?.range == 12..<13)
        #expect(failure("tag:a | | tag:b")?.range == 8..<9)
    }

    @Test func scanKeepsLexingPastErrors() throws {
        let query = "tag:a level: \"open"
        let result = FilterLexer.scan(query)
        let chars = Array(query)
        #expect(result.tokens.map { String(chars[$0.range]) } == ["tag:a", "level:", "\"open"])
        #expect(result.error?.message == "Missing value for level")
        #expect(result.tokens.last?.terminated == false)
        #expect(throws: FilterError.self) { try FilterLexer.locatedTokens(query) }
        do {
            _ = try FilterLexer.locatedTokens(query)
        } catch {
            #expect(error.message == result.error?.message)
        }

        let empty = FilterLexer.scan("tag:")
        #expect(empty.tokens.count == 1)
        #expect(empty.tokens.first?.valueRange == 4..<4)
        #expect(empty.error?.message == "Missing value for tag")
        if case let .term(_, _, value, _, _)? = empty.tokens.first?.token {
            #expect(value.isEmpty)
        } else {
            Issue.record("expected a term")
        }

        let valid = "(tag:a | -tag=:\"b c\") level:W"
        let scanned = FilterLexer.scan(valid)
        let validChars = Array(valid)
        let values = scanned.tokens.compactMap(\.valueRange).map { String(validChars[$0]) }
        #expect(values == ["a", "\"b c\"", "W"])
        #expect(scanned.error == nil)
        #expect(scanned.tokens == (try FilterLexer.locatedTokens(valid)))
    }

    @Test func detectsQueriesWhosePrecedenceChanged() {
        let changed = [
            "foo bar tag:bar1 | tag:bar2",
            "tag:Net | tag:Http level:WARN",
            "tag:a tag:b & level:E",
            "foo bar | baz",
            "package:mine package:foo",
        ]
        for query in changed {
            #expect(LogFilter.meaningChangedByPrecedence(query), "\(query)")
        }
        let unchanged = [
            "",
            "tag:a tag:b level:W",
            "tag:A & level:ERROR | tag:B",
            "(tag:a | tag:b) & level:E",
            "tag:a level:E & pid:1",
            "is:crash",
            "is:error",
            "tag:",
            "name:x tag:a",
        ]
        for query in unchanged {
            #expect(!LogFilter.meaningChangedByPrecedence(query), "\(query)")
        }
    }

    @Test func tokenRangesCoverTheirSourceText() throws {
        let expected: [(String, [String])] = [
            ("(tag:a | -tag=:\"b c\") && level:W", ["(", "tag:a", "|", "-tag=:\"b c\"", ")", "&&", "level:W"]),
            ("(tag:Zed | tag:Tag)", ["(", "tag:Zed", "|", "tag:Tag", ")"]),
            ("foo - bar", ["foo", "-", "bar"]),
            ("(foo bar) -baz", ["(", "foo", "bar", ")", "-baz"]),
            ("tag:a&tag:b", ["tag:a", "&", "tag:b"]),
        ]
        for (query, texts) in expected {
            let located = try FilterLexer.locatedTokens(query)
            let chars = Array(query)
            #expect(located.map { String(chars[$0.range]) } == texts, "\(query)")
            #expect(try FilterLexer.tokenize(query) == located.map(\.token), "\(query)")
        }
    }

    @Test func topLevelElementsKeepTheirSourceText() throws {
        let query = "foo tag:a | tag:b (x y) level:W & pid:1"
        let tokens = try FilterLexer.locatedTokens(query)
        var parser = FilterParser(tokens: tokens.map(\.token), caseSensitive: false)
        let elements = try parser.parseTopLevelElements()
        let chars = Array(query)
        let texts = elements.map { element in
            String(chars[tokens[element.tokens.lowerBound].range.lowerBound..<tokens[element.tokens.upperBound - 1].range.upperBound])
        }
        #expect(texts == ["foo", "tag:a | tag:b", "(x y)", "level:W & pid:1"])
    }

    @Test func markersAlwaysMatch() throws {
        #expect(try LogFilter("tag:nothing").matches(.marker("Device disconnected"), context: FilterContext()))
    }

    @Test func dependsOnProcessNames() throws {
        #expect(try LogFilter("package:foo").dependsOnProcessNames)
        #expect(try LogFilter("-process:foo").dependsOnProcessNames)
        #expect(try !LogFilter("tag:foo level:W").dependsOnProcessNames)
    }
}

@Suite struct FilterQueryEditorTests {
    private func add(_ term: String, _ query: String) -> String {
        FilterQueryEditor.adding(term, to: query)
    }

    private func level(_ level: LogLevel?, _ query: String) -> String {
        FilterQueryEditor.settingMinimumLevel(level, in: query)
    }

    @Test func hideTagAppliesToEveryOrBranch() throws {
        let result = add("-tag=:NetCache", "tag:Net | tag:Http")
        #expect(result == "(tag:Net | tag:Http) & -tag=:NetCache")
        #expect(try matches(result, entry(tag: "Net")))
        #expect(try matches(result, entry(tag: "Http")))
        #expect(try !matches(result, entry(tag: "NetCache")))
    }

    @Test func showOnlyTagReplacesTheSameKey() throws {
        let result = add("tag=:Http", "tag:Net")
        #expect(result == "tag=:Http")
        #expect(try matches(result, entry(tag: "Http")))
        #expect(try !matches(result, entry(tag: "Net")))
        #expect(try !matches(result, entry(tag: "NetHttp")))

        #expect(add("tag=:c", "tag:a tag:b level:W") == "tag=:c level:W")
        #expect(add("tag=:FA", "is:firebase") == "tag=:FA")
        #expect(add("package=:com.x", "package:mine level:W") == "package=:com.x level:W")
        #expect(add("pid:2", "pid:1") == "pid:2")
        #expect(add("tid:2", "tid:1 tag:a") == "tid:2 tag:a")
    }

    @Test func showOnlyNeverOrs() throws {
        let cases: [(query: String, term: String, expected: String, narrowed: LogEntry)] = [
            ("tag:Net | tag:Http", "tag=:NetCache", "(tag:Net | tag:Http) & tag=:NetCache", entry(tag: "Http")),
            ("tag:a & level:W", "tag=:b", "tag:a & level:W tag=:b", entry(tag: "a", level: .error)),
            ("-tag:a", "tag=:b", "-tag:a tag=:b", entry(tag: "other")),
            ("(tag:a | tag:b)", "tag=:c", "(tag:a | tag:b) tag=:c", entry(tag: "b")),
        ]
        let probes = ["a", "b", "c", "Net", "Http", "NetCache", "other"].flatMap { tag in
            [LogLevel.debug, .error].map { entry(tag: tag, level: $0) }
        }
        for (query, term, expected, narrowed) in cases {
            let result = add(term, query)
            #expect(result == expected, "\(query)")
            // The new term only narrows: nothing the original rejects shows up, and something it accepted goes.
            for probe in probes {
                #expect(try !matches(result, probe) || matches(query, probe), "\(query) vs \(probe.tag) \(probe.level)")
            }
            #expect(try matches(query, narrowed), "\(query)")
            #expect(try !matches(result, narrowed), "\(query)")
        }
    }

    @Test func minimumLevelAppliesToEveryOrBranch() throws {
        let result = level(.warn, "tag:Net | tag:Http")
        #expect(result == "(tag:Net | tag:Http) & level:WARN")
        for tag in ["Net", "Http"] {
            #expect(try !matches(result, entry(tag: tag, level: .debug)))
            #expect(try matches(result, entry(tag: tag, level: .warn)))
            #expect(try matches(result, entry(tag: tag, level: .error)))
        }
    }

    @Test func levelPickerLeavesNestedLevelTermsAlone() throws {
        #expect(try LogFilter("(level:E | tag:x)").levelSelection == .mixed)
        let warn = level(.warn, "(level:E | tag:x)")
        #expect(warn == "(level:E | tag:x) level:WARN")
        #expect(try LogFilter(warn).levelSelection == .minimum(.warn))
        // Picking again replaces the top-level term instead of adding another.
        #expect(level(.error, warn) == "(level:E | tag:x) level:ERROR")
        #expect(level(nil, warn) == "(level:E | tag:x)")
        #expect(level(nil, "(level:E | tag:x)") == "(level:E | tag:x)")
    }

    @Test func levelPickerReplacesTopLevelLevelTerms() throws {
        #expect(level(.error, "level:W tag:a") == "level:ERROR tag:a")
        #expect(level(.warn, "is:error tag:a") == "level:WARN tag:a")
        #expect(level(.info, "level:E is:debug") == "level:INFO")
        #expect(level(.warn, "is:crash") == "is:crash level:WARN")
        #expect(level(nil, "tag:a level:W") == "tag:a")
        #expect(level(.warn, "") == "level:WARN")
        #expect(level(nil, "level:W") == "")
        #expect(level(.error, "tag:Net | tag:Http level:WARN") == "tag:Net | tag:Http level:ERROR")
        // A `level:` inside an `&` chain is not edited, so a new top-level term is added. The picker keeps
        // showing the floor that is still true.
        let chained = level(.info, "level:W & tag:a")
        #expect(chained == "level:W & tag:a level:INFO")
        #expect(try LogFilter(chained).levelSelection == .minimum(.warn))
    }

    @Test func levelSelectionReflectsTheParsedFilter() throws {
        let cases: [(String, LevelSelection)] = [
            ("tag:a", .any),
            ("", .any),
            ("level:W tag:a", .minimum(.warn)),
            ("tag:Net | tag:Http level:WARN", .minimum(.warn)),
            ("(level:E | tag:x)", .mixed),
            ("(level:E | tag:x) level:WARN", .minimum(.warn)),
            ("is:error", .mixed),
            ("level:E is:debug", .mixed),
            ("level:W | tag:a", .mixed),
            ("-level:W", .mixed),
            ("level:W & level:E", .minimum(.error)),
            ("is:crash", .any),
        ]
        for (query, expected) in cases {
            #expect(try LogFilter(query).levelSelection == expected, "\(query)")
        }
    }

    @Test func simpleQueriesStayFreeOfParentheses() {
        let cases: [(query: String, edit: (String) -> String, expected: String)] = [
            ("tag:a", { add("-tag=:b", $0) }, "tag:a -tag=:b"),
            ("tag:a", { level(.warn, $0) }, "tag:a level:WARN"),
            ("level:W tag:a", { level(.error, $0) }, "level:ERROR tag:a"),
            ("package:mine", { add("-package=:com.x", $0) }, "package:mine -package=:com.x"),
            ("", { add("tag=:a", $0) }, "tag=:a"),
            ("tag:a & level:W", { add("-tag=:b", $0) }, "tag:a & level:W -tag=:b"),
            ("foo bar", { add("pid:3", $0) }, "foo bar pid:3"),
        ]
        for (query, edit, expected) in cases {
            let result = edit(query)
            #expect(result == expected, "\(query)")
            #expect(!result.contains("("), "\(query)")
        }
    }

    @Test func repeatedEditsAreNoOps() {
        #expect(add("-tag=:b", "tag:a -tag=:b") == "tag:a -tag=:b")
        #expect(add("-tag=:NetCache", "(tag:Net | tag:Http) & -tag=:NetCache") == "(tag:Net | tag:Http) & -tag=:NetCache")
        #expect(add("tag=:NetCache", "(tag:Net | tag:Http) & tag=:NetCache") == "(tag:Net | tag:Http) & tag=:NetCache")
        #expect(level(.warn, "level:w") == "level:w")
        #expect(add("tag=:Http", "tag=:Http") == "tag=:Http")
    }

    @Test func removingTermsKeepsFreeTextPhrasesApart() throws {
        let removed = level(nil, "foo level:W bar")
        #expect(removed == "foo \"bar\"")
        #expect(try sameMeaning(removed, "foo & bar"))
        #expect(level(.error, "foo level:W bar") == "foo level:ERROR bar")
        #expect(add("tag=:c", "foo tag:a bar tag:b baz qux") == "foo tag=:c bar \"baz qux\"")
        #expect(level(nil, "\"foo\" level:W bar") == "\"foo\" bar")
    }

    @Test func editsKeepNamesQuotesAndSpacing() throws {
        #expect(add("tag=:b", "name:\"My filter\" tag:a") == "name:\"My filter\" tag=:b")
        #expect(add("-tag=:b", "tag:a  ") == "tag:a -tag=:b")
        let hidden = add("-tag=:" + FilterQueryEditor.quoted("My Tag"), "tag:a")
        #expect(hidden == "tag:a -tag=:\"My Tag\"")
        #expect(try !matches(hidden, entry(tag: "My Tag")))
        #expect(try matches(hidden, entry(tag: "a")))
        // A quoted `|` is not a top-level `|`.
        #expect(level(.warn, "message:\"x | y\"") == "message:\"x | y\" level:WARN")
    }

    @Test func invalidQueriesStayInvalid() {
        #expect(add("-tag=:b", "tag:a |") == "(tag:a |) & -tag=:b")
        #expect(add("-tag=:b", "(tag:a") == "((tag:a) & -tag=:b")
        #expect(level(nil, "tag:a |") == "tag:a |")
        #expect(level(.warn, "tag:a |") == "(tag:a |) & level:WARN")
        for query in ["tag:a |", "(tag:a"] {
            #expect(throws: FilterError.self) { try LogFilter(add("-tag=:b", query)) }
        }
    }

    @Test func quotedValues() throws {
        #expect(FilterQueryEditor.quoted("plain") == "plain")
        #expect(FilterQueryEditor.quoted("My Tag") == "\"My Tag\"")
        #expect(FilterQueryEditor.quoted("a\"b") == "\"a\\\"b\"")
        #expect(FilterQueryEditor.quoted("a\\b") == "\"a\\\\b\"")
        #expect(FilterQueryEditor.quoted("") == "\"\"")
        for value in ["x|y", "(x)", "a&b", "it's"] {
            #expect(FilterQueryEditor.quoted(value).hasPrefix("\""), "\(value)")
        }
        for value in ["plain", "My Tag", "a\"b", "a\\b", "x|y", "(x)", "a&b", "it's"] {
            #expect(try matches("tag=:" + FilterQueryEditor.quoted(value), entry(tag: value)), "\(value)")
        }
    }

    @Test func hidingIsAlwaysAndedWithTheWholeQuery() throws {
        // None of these has a lone top-level level term, which the picker would replace instead.
        let queries = [
            "", "tag:a", "tag:a tag:b", "tag:a | tag:b", "foo bar", "(level:E | tag:x)", "tag:a & level:W",
            "is:crash is:stacktrace", "name:n tag:a | tag:b",
        ]
        for query in queries {
            for term in ["-tag=:z", "-package=:com.z"] {
                let result = add(term, query)
                #expect(throws: Never.self) { try LogFilter(result) }
                if !query.isEmpty {
                    #expect(try sameMeaning(result, "(\(query)) & \(term)"), "\(query) + \(term) = \(result)")
                }
            }
            let warn = level(.warn, query)
            #expect(throws: Never.self) { try LogFilter(warn) }
            if !query.isEmpty {
                #expect(try sameMeaning(warn, "(\(query)) & level:WARN"), "\(query) + WARN = \(warn)")
            }
        }
    }
}
