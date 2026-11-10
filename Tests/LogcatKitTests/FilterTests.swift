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
