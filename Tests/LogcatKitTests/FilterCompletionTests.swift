import Foundation
import Testing
@testable import LogcatKit

private func entry(tag: String = "Tag") -> LogEntry {
    LogEntry(timestamp: 1_000_000, pid: 100, tid: 101, level: .info, tag: tag, message: "hello", processName: "com.example.app")
}

private func suggestions(_ query: String, cursor: Int? = nil, _ source: FilterCompletionSource = .init()) -> [FilterSuggestion] {
    FilterCompletion.suggestions(query: query, cursor: cursor ?? query.count, source: source)
}

private func labels(_ query: String, cursor: Int? = nil, _ source: FilterCompletionSource = .init()) -> [String] {
    suggestions(query, cursor: cursor, source).map(\.label)
}

private func insertions(_ query: String, cursor: Int? = nil, _ source: FilterCompletionSource = .init()) -> [String] {
    suggestions(query, cursor: cursor, source).map(\.insertion)
}

private func context(_ query: String, _ cursor: Int) -> FilterCompletionContext {
    FilterCompletion.completionContext(query: query, cursor: cursor)
}

private func spans(_ query: String) -> [String] {
    let chars = Array(query)
    return FilterSyntax.highlighting(for: query).spans.map { "\($0.kind) \(String(chars[$0.range]))" }
}

@Suite struct FilterSyntaxTests {
    @Test func spansClassifyEveryToken() {
        #expect(spans("-tag~:^Net (package:\"my app\" | level:W) && foo \"bar baz\"") == [
            "key -tag~:", "regexValue ^Net", "parenthesis (", "key package:", "quotedValue \"my app\"",
            "logicalOperator |", "key level:", "value W", "parenthesis )", "logicalOperator &&",
            "text foo", "quotedText \"bar baz\"",
        ])
    }

    @Test func spansSurviveInvalidQueries() {
        #expect(spans("tag:a level: \"open") == ["key tag:", "value a", "key level:", "quotedText \"open"])
        #expect(spans("tag~:\"[x") == ["key tag~:", "regexValue \"[x"])
    }

    @Test func highlightingReportsTheError() {
        let broken = FilterSyntax.highlighting(for: "level:loud tag:a")
        #expect(broken.spans.count == 4)
        #expect(broken.error?.range == 6..<10)
        #expect(FilterSyntax.highlighting(for: "tag:a").error == nil)
    }

    @Test func textOffsetsConvertToUTF16() {
        let emoji = FilterTextOffsets("tag:😀 x")
        #expect(emoji.utf16(5) == 6)
        #expect(emoji.utf16(7) == 8)
        #expect(emoji.character(forUTF16: 6) == 5)
        #expect(emoji.character(forUTF16: 5) == 4)
        #expect(emoji.nsRange(4..<5) == NSRange(location: 4, length: 2))
        let combined = FilterTextOffsets("e\u{301}x")
        #expect(combined.utf16(1) == 2)
        #expect(combined.character(forUTF16: 1) == 0)
    }
}

@Suite struct FilterCompletionTests {
    @Test func typingTaSuggestsTagKeys() {
        let result = suggestions("ta")
        #expect(result.map(\.label) == ["tag:", "tag=:", "tag~:"])
        #expect(result.map(\.insertion) == ["tag:", "tag=:", "tag~:"])
        #expect(result.allSatisfy { $0.replacement == 0..<2 })
        #expect(labels("TA") == ["tag:", "tag=:", "tag~:"])
    }

    @Test func emptyQuerySuggestsBaseKeys() {
        #expect(labels("") == [
            "tag:", "package:", "process:", "message:", "line:", "level:", "age:", "is:", "name:", "pid:", "tid:",
            "package:mine",
        ])
        #expect(insertions("").last == "package:mine ")
    }

    @Test func negatedAndTermKeys() {
        #expect(labels("-ta") == ["-tag:", "-tag=:", "-tag~:"])
        #expect(labels("lev") == [
            "level:", "level:verbose", "level:debug", "level:info", "level:warn", "level:error", "level:assert",
        ])
        #expect(labels("is:c") == ["crash"])
        #expect(labels("-n") == [])
    }

    @Test func contextAtEveryPosition() {
        func expect(
            _ query: String, _ cursor: Int, _ kind: FilterCompletionContext.Kind, _ prefix: String, _ replacement: Range<Int>,
            sourceLocation: SourceLocation = #_sourceLocation
        ) {
            let result = context(query, cursor)
            #expect(result.kind == kind, "\(query)@\(cursor)", sourceLocation: sourceLocation)
            #expect(result.prefix == prefix, "\(query)@\(cursor)", sourceLocation: sourceLocation)
            #expect(result.replacement == replacement, "\(query)@\(cursor)", sourceLocation: sourceLocation)
            #expect(result.queryLength == query.count, sourceLocation: sourceLocation)
        }
        expect("", 0, .key(inTerm: false), "", 0..<0)
        expect("tag:a  level:W", 6, .key(inTerm: false), "", 6..<6)
        expect("tag:Act", 7, .value(key: .tag, op: .contains, negated: false), "Act", 4..<7)
        expect("-tag=:Act", 9, .value(key: .tag, op: .exact, negated: true), "Act", 6..<9)
        expect("tag:Activity", 7, .value(key: .tag, op: .contains, negated: false), "Act", 4..<12)
        expect("tag:foo", 2, .key(inTerm: true), "ta", 0..<4)
        expect("taxyz", 2, .key(inTerm: false), "ta", 0..<2)
        expect("tag:\"My T", 9, .value(key: .tag, op: .contains, negated: false), "My T", 4..<9)
        expect("tag:\"a b\"", 9, .none, "", 9..<9)
        expect("\"foo", 4, .none, "", 4..<4)
        expect("tag:a|ta", 8, .key(inTerm: false), "ta", 6..<8)
        expect("tag:a&", 6, .key(inTerm: false), "", 6..<6)
        expect("tag:a\\ b", 8, .value(key: .tag, op: .contains, negated: false), "a b", 4..<8)
    }

    @Test func completionWorksInsideParentheses() {
        #expect(context("(ta", 3).kind == .key(inTerm: false))
        #expect(context("(ta", 3).prefix == "ta")
        #expect(context("(ta", 3).replacement == 1..<3)
        #expect(context("(", 1).kind == .key(inTerm: false))
        #expect(context("(", 1).prefix == "")
        #expect(context("tag:a (level:", 13).kind == .value(key: .level, op: .contains, negated: false))
        #expect(context("(tag:a | ", 9).kind == .key(inTerm: false))
        #expect(context("(tag:a | ", 9).prefix == "")
        let value = context("(tag:a)", 6)
        #expect(value.kind == .value(key: .tag, op: .contains, negated: false))
        #expect(value.prefix == "a")
        #expect(value.replacement == 5..<6)
        #expect(context("(tag:a)", 7).kind == .none)
        #expect(labels("(ta") == ["tag:", "tag=:", "tag~:"])
    }

    @Test func tagValuesFollowPrefixAndFrequency() {
        var source = FilterCompletionSource()
        source.tagCounts = [
            "ActivityManager": 5, "ActivityTaskManager": 50, "Choreographer": 100, "activity_x": 7, "Zygote": 1, "B": 3, "A": 3,
        ]
        let matching = ["ActivityTaskManager", "activity_x", "ActivityManager"]
        #expect(labels("tag:Act", source) == matching)
        #expect(labels("tag:", source) == ["Choreographer", "ActivityTaskManager", "activity_x", "ActivityManager", "A", "B", "Zygote"])
        #expect(labels("-tag~:act", source) == matching)
        let all = suggestions("tag:", source)
        #expect(all.first?.detail == "100 entries")
        #expect(all.last?.detail == "1 entry")
        #expect(suggestions("tag:Act", source).first?.detail == "50 entries")
    }

    private var processSource: FilterCompletionSource {
        var source = FilterCompletionSource()
        source.processCounts = [
            "com.example.app": 10, "com.example.app:remote": 5, "com.android.systemui": 30,
            "/system/bin/surfaceflinger": 40, "log": 3, "android.hardware.audio@2.0-service": 9,
        ]
        source.runningProcesses = ["com.google.android.gms", "com.android.systemui", "[kthreadd]", "zygote64"]
        source.myPackages = ["com.x"]
        return source
    }

    @Test func packageValuesStartWithMine() {
        let source = processSource
        #expect(labels("package:", source) == ["mine", "com.android.systemui", "com.example.app", "com.google.android.gms"])
        #expect(labels("package=:", source) == ["com.android.systemui", "com.example.app", "com.google.android.gms"])
        #expect(labels("package:m", source) == ["mine"])
        #expect(labels("package:com.e", source) == ["com.example.app"])
        #expect(suggestions("package:", source).map(\.detail) == ["My packages: com.x", "30 entries", "15 entries", "Running"])
    }

    @Test func mineDescribesAnEmptyList() {
        #expect(suggestions("package:").first?.detail == "My packages (none set; matches everything)")
        var source = FilterCompletionSource()
        source.myPackages = ["d.d", "c.c", "b.b", "a.a"]
        #expect(suggestions("package:", source).first?.detail == "My packages: a.a, b.b, c.c, …")
    }

    @Test func processValues() {
        let source = processSource
        #expect(labels("process:com.ex", source) == ["com.example.app", "com.example.app:remote"])
        let all = labels("process:", source)
        #expect(Array(all.suffix(2)) == ["com.google.android.gms", "zygote64"])
        #expect(!all.contains("[kthreadd]"))
    }

    @Test func levelIsAgeAndPidValues() {
        #expect(labels("level:") == ["verbose", "debug", "info", "warn", "error", "assert"])
        #expect(labels("level:W") == ["WARN"])
        #expect(labels("is:") == ["crash", "firebase", "stacktrace", "verbose", "debug", "info", "warn", "error", "assert"])
        #expect(labels("is:st") == ["stacktrace"])
        #expect(labels("age:") == ["30s", "5m", "3h", "1d"])

        var source = FilterCompletionSource()
        source.pids = [
            FilterPidInfo(pid: 123, count: 5, processName: "com.a"),
            FilterPidInfo(pid: 456, count: 9, processName: "system_server"),
            FilterPidInfo(pid: 789, count: 1, processName: nil),
        ]
        #expect(labels("pid:", source) == ["456", "123", "789"])
        #expect(suggestions("pid:", source).map(\.detail) == ["system_server", "com.a", nil])
        #expect(labels("pid:12", source) == ["123"])
        #expect(labels("pid:sys", source) == ["456"])
        #expect(labels("message:") == [])
        #expect(labels("name:") == [])
    }

    @Test func acceptedValuesAreQuotedWhenNeeded() throws {
        var source = FilterCompletionSource()
        source.tagCounts = ["My Tag": 3, "a|b": 2, "plain": 1]
        #expect(insertions("tag:", source) == ["\"My Tag\" ", "\"a|b\" ", "plain "])

        let middle = suggestions("tag:My x", cursor: 6, source)
        #expect(middle.first?.insertion == "\"My Tag\"")
        #expect(middle.first?.replacement == 4..<6)
        #expect(insertions("tag:\"My T", source).first == "\"My Tag\" ")

        for suggestion in suggestions("tag=:", source) {
            let (query, cursor) = suggestion.applied(to: "tag=:")
            #expect(cursor == query.count)
            let filter = try LogFilter(query)
            let context = FilterContext(now: 1_000_000)
            #expect(filter.matches(entry(tag: suggestion.label), context: context), "\(query)")
            #expect(!filter.matches(entry(tag: "My"), context: context), "\(query)")
            #expect(suggestion.insertion.trimmingCharacters(in: .whitespaces) == FilterQueryEditor.quoted(suggestion.label))
        }
    }

    @Test func historyIsOffered() {
        var source = FilterCompletionSource()
        source.history = ["tag:Net level:W", "package:mine", "tag:Net level:W"]
        let typed = suggestions("ta", source)
        #expect(typed.map(\.label) == ["tag:", "tag=:", "tag~:", "tag:Net level:W"])
        #expect(typed.last?.replacement == 0..<2)
        #expect(typed.last?.kind == .history)
        #expect(typed.last?.detail == "Saved filter")
        #expect(Array(labels("", source).suffix(2)) == ["tag:Net level:W", "package:mine"])
        #expect(!labels("tag:Net level:W", cursor: 3, source).contains("tag:Net level:W"))
        #expect(labels("ta") == ["tag:", "tag=:", "tag~:"])
    }

    @Test func noKeysAfterQuotesOrParens() {
        #expect(context("( a )b", 6).kind == .none)
        #expect(context("\"a\"b", 4).kind == .none)
    }

    @Test func tenThousandTagsCompleteWithin50ms() {
        var source = FilterCompletionSource()
        for i in 0..<10_000 {
            source.tagCounts["Tag\(i % 7 == 0 ? "Activity" : "Net")Component\(i)"] = (i * 7919) % 1000 + 1
        }
        let clock = ContinuousClock()
        let typed = Array("tag:TagNetComponent12")
        for length in 1...typed.count {
            let query = String(typed[..<length])
            let elapsed = clock.measure { _ = FilterCompletion.suggestions(query: query, cursor: length, source: source) }
            #expect(elapsed < .milliseconds(50), "\(query) took \(elapsed)")
        }
        let all = suggestions("tag:", source)
        #expect(all.count == 100)
        #expect(source.tagCounts[all[0].label] == source.tagCounts.values.max())
        let narrowed = labels("tag:TagNetComponent12", source)
        #expect(!narrowed.isEmpty)
        #expect(narrowed.allSatisfy { $0.hasPrefix("TagNetComponent12") })
    }
}
