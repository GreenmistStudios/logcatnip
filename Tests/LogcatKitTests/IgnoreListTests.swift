import Foundation
import Testing
@testable import LogcatKit

private func entry(
    tag: String = "Tag",
    message: String = "hello world",
    level: LogLevel = .info,
    pid: Int32 = 100,
    tid: Int32 = 101,
    process: String? = "com.example.app"
) -> LogEntry {
    LogEntry(timestamp: 1_000_000, pid: pid, tid: tid, level: level, tag: tag, message: message, processName: process)
}

private func context(
    _ list: IgnoreList = IgnoreList(),
    processNames: [Int32: String] = [:]
) -> FilterContext {
    FilterContext(processNames: processNames, now: 1_000_000, ignoreList: list)
}

private func outcome(
    _ query: String,
    _ entry: LogEntry,
    caseSensitive: Bool = false,
    context: FilterContext
) throws -> FilterOutcome {
    try LogFilter(query, caseSensitive: caseSensitive).evaluate(entry, context: context)
}

@Suite struct IgnoreListTests {
    @Test func ignoredTagIsHiddenBeforeTheQuery() throws {
        let list = IgnoreList(tags: ["chatty"])
        let filter = try LogFilter("")
        #expect(filter.evaluate(entry(tag: "chatty"), context: context(list)) == .ignored)
        #expect(!filter.matches(entry(tag: "chatty"), context: context(list)))
        #expect(filter.evaluate(entry(tag: "Other"), context: context(list)) == .shown)
        #expect(filter.matches(entry(tag: "Other"), context: context(list)))
    }

    @Test func ignoredTagMatchIsExactAndCaseSensitive() throws {
        let ctx = context(IgnoreList(tags: ["chatty"]))
        for caseSensitive in [false, true] {
            for tag in ["Chatty", "chatty2", "xchatty", "CHATTY"] {
                #expect(try outcome("", entry(tag: tag), caseSensitive: caseSensitive, context: ctx) == .shown)
            }
            #expect(try outcome("", entry(tag: "chatty"), caseSensitive: caseSensitive, context: ctx) == .ignored)
        }
    }

    @Test func ignoredPackageUsesThePackageOfTheProcess() throws {
        let ctx = context(IgnoreList(packages: ["com.noisy"]))
        #expect(try outcome("", entry(process: "com.noisy:remote"), context: ctx) == .ignored)
        #expect(try outcome("", entry(process: "com.noisy"), context: ctx) == .ignored)
        #expect(try outcome("", entry(process: "com.noisy.other"), context: ctx) == .shown)
        #expect(try outcome("", entry(process: "Com.Noisy"), context: ctx) == .shown)
        #expect(try outcome("", entry(process: nil), context: ctx) == .shown)

        let resolved = context(IgnoreList(packages: ["com.noisy"]), processNames: [100: "com.noisy"])
        #expect(try outcome("", entry(pid: 100, process: nil), context: resolved) == .ignored)
        #expect(try outcome("", entry(pid: 101, process: nil), context: resolved) == .shown)
    }

    @Test func ignoredEntryRejectedByTheQueryIsFilteredOut() throws {
        let ctx = context(IgnoreList(tags: ["Bar"]))
        #expect(try outcome("tag:Foo", entry(tag: "Bar"), context: ctx) == .filteredOut)
        #expect(try outcome("tag:Foo", entry(tag: "Foo"), context: ctx) == .shown)
        #expect(try outcome("tag:Bar", entry(tag: "Bar"), context: ctx) == .ignored)
    }

    @Test func ignoreListAppliesWhateverTheQuery() throws {
        let ctx = context(IgnoreList(tags: ["chatty"]))
        let chatty = entry(tag: "chatty", level: .error)
        for query in ["tag:chatty", "level:V", "chatty", "-tag:Other", "tag:chatty | tag:x", "tag=:chatty"] {
            #expect(try outcome(query, chatty, context: ctx) != .shown, "\(query)")
        }
    }

    @Test func markersAreNeverIgnored() throws {
        let ctx = context(IgnoreList(tags: ["chatty"], packages: ["x"]))
        let marker = LogEntry.marker("Device disconnected")
        #expect(try outcome("tag:chatty", marker, context: ctx) == .shown)
        #expect(try outcome("", marker, context: ctx) == .shown)
    }

    @Test func removingAnIgnoredTagShowsItAgain() throws {
        let list = IgnoreList(tags: ["chatty"], packages: ["com.noisy"])
        let tagged = entry(tag: "chatty")
        let packaged = entry(process: "com.noisy")
        #expect(try outcome("", tagged, context: context(list)) == .ignored)
        #expect(try outcome("", tagged, context: context(list.removingTag("chatty"))) == .shown)
        #expect(try outcome("", packaged, context: context(list)) == .ignored)
        #expect(try outcome("", packaged, context: context(list.removingPackage("com.noisy"))) == .shown)
    }

    @Test func ignoreListKeepsOrderAndDropsDuplicatesAndBlanks() {
        let list = IgnoreList(tags: ["b", "", "a", "b"])
        #expect(list.tags == ["b", "a"])
        #expect(list.addingTag("a") == list)
        #expect(list.addingTag("c").tags == ["b", "a", "c"])
        #expect(list.addingTag("") == list)
        #expect(list.removingTag("zzz") == list)
        #expect(list.removingTag("b").tags == ["a"])
        #expect(IgnoreList().isEmpty)
        #expect(!list.isEmpty)
        #expect(!IgnoreList(packages: ["p"]).isEmpty)
        #expect(IgnoreList(packages: ["p", "p", ""]).packages == ["p"])
        #expect(IgnoreList().addingPackage("p").addingPackage("q").removingPackage("p").packages == ["q"])
    }

    @Test func tagsAreNotTrimmed() {
        // A tag from the context menu must match the logged one exactly, whatever it contains.
        let list = IgnoreList(tags: [" spaced "])
        #expect(list.ignoresTag(" spaced "))
        #expect(!list.ignoresTag("spaced"))
    }

    @Test func ignoredCountEqualsEntriesRevealedWhenShown() throws {
        var entries: [LogEntry] = []
        for level in [LogLevel.verbose, .warn, .error] {
            entries.append(entry(tag: "chatty", level: level))
            entries.append(entry(tag: "Net", level: level))
            entries.append(entry(tag: "App", level: level, process: "com.noisy"))
        }
        entries.append(entry(tag: "App", level: .warn, process: "com.example.app"))
        entries.append(entry(tag: "App", level: .error, process: "com.example.app"))
        entries.append(LogEntry.marker("restarted"))
        #expect(entries.count == 12)

        let list = IgnoreList(tags: ["chatty"], packages: ["com.noisy"])
        for query in ["", "level:W", "tag:App", "-tag:Net", "chatty | Net"] {
            let filter = try LogFilter(query)
            let withList = context(list)
            let withoutList = context()
            let ignored = entries.filter { filter.evaluate($0, context: withList) == .ignored }.count
            let shown = entries.filter { filter.evaluate($0, context: withList) == .shown }.count
            let matchedWithout = entries.filter { filter.matches($0, context: withoutList) }.count
            let matchedWith = entries.filter { filter.matches($0, context: withList) }.count
            #expect(ignored == matchedWithout - matchedWith, "\(query)")
            #expect(shown + ignored == matchedWithout, "\(query)")
        }
    }

    @Test func emptyIgnoreListChangesNothing() throws {
        let entries = [entry(tag: "Foo"), entry(tag: "Bar", level: .error), entry(tag: "Baz", process: nil)]
        for query in ["", "tag:Foo", "level:E | Baz"] {
            let filter = try LogFilter(query)
            for e in entries {
                let expected: FilterOutcome = filter.matches(e, context: FilterContext(now: 1_000_000)) ? .shown : .filteredOut
                #expect(filter.evaluate(e, context: FilterContext(now: 1_000_000)) == expected, "\(query)")
            }
        }
        #expect(FilterContext().ignoreList.isEmpty)
    }
}

@Suite struct DefaultFilterTests {
    @Test func fallbackIsMineOnlyWithMyPackages() {
        #expect(DefaultFilter.fallback(myPackages: []) == "")
        #expect(DefaultFilter.fallback(myPackages: ["com.x"]) == "package:mine")
    }

    @Test func unsetDefaultUsesTheFallback() {
        #expect(DefaultFilter.initialQuery(configured: nil, mostRecentlyUsed: nil, useMostRecent: false,
                                           myPackages: ["com.x"]) == "package:mine")
        #expect(DefaultFilter.initialQuery(configured: nil, mostRecentlyUsed: nil, useMostRecent: false,
                                           myPackages: []) == "")
    }

    @Test func configuredDefaultWinsEvenWhenEmpty() {
        #expect(DefaultFilter.initialQuery(configured: "", mostRecentlyUsed: nil, useMostRecent: false,
                                           myPackages: ["com.x"]) == "")
        #expect(DefaultFilter.initialQuery(configured: "level:W", mostRecentlyUsed: nil, useMostRecent: false,
                                           myPackages: ["com.x"]) == "level:W")
    }

    @Test func mostRecentlyUsedWinsWhenEnabled() {
        #expect(DefaultFilter.initialQuery(configured: "level:W", mostRecentlyUsed: "tag:Net", useMostRecent: true,
                                           myPackages: []) == "tag:Net")
        #expect(DefaultFilter.initialQuery(configured: "level:W", mostRecentlyUsed: "", useMostRecent: true,
                                           myPackages: []) == "")
        #expect(DefaultFilter.initialQuery(configured: "level:W", mostRecentlyUsed: "tag:Net", useMostRecent: false,
                                           myPackages: []) == "level:W")
    }

    @Test func mostRecentlyUsedFallsBackToTheDefaultWhenNeverRecorded() {
        #expect(DefaultFilter.initialQuery(configured: nil, mostRecentlyUsed: nil, useMostRecent: true,
                                           myPackages: ["com.x"]) == "package:mine")
        #expect(DefaultFilter.initialQuery(configured: "level:W", mostRecentlyUsed: nil, useMostRecent: true,
                                           myPackages: []) == "level:W")
    }
}
