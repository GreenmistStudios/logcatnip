import Foundation
import Testing
@testable import LogcatKit

@Suite struct LogViewOptionsTests {
    @Test func standardPreset() {
        let options = LogViewOptions.standard
        #expect(options.visibleColumns == [.time, .pid, .tag, .package, .level, .message])
        #expect(options.timestampStyle == .dateTime)
        #expect(options.timeZone == .local)
        #expect(options.pidStyle == .pidTid)
        #expect(options.tagWidth == 23)
        #expect(options.packageWidth == 35)
        #expect(options.processWidth == 35)
        #expect(!options.hideRepeatedTags && !options.hideRepeatedPackages && !options.hideRepeatedProcesses)
        #expect(options.colorTags)
        #expect(options.preset == .standard)
    }

    @Test func compactPreset() {
        let options = LogViewOptions.compact
        #expect(options.visibleColumns == [.time, .tag, .level, .message])
        #expect(options.timestampStyle == .time)
        #expect(options.preset == .compact)
        #expect(LogViewOptions.Preset.compact.options == .compact)
        #expect(LogViewOptions.Preset.standard.options == .standard)
    }

    @Test func anyChangeIsCustom() {
        var mutations: [(String, (inout LogViewOptions) -> Void)] = []
        for column in LogColumn.allCases where column != .message {
            mutations.append(("toggle \(column)", { $0.setVisible(column, !$0.isVisible(column)) }))
        }
        for style in TimestampStyle.allCases where style != .dateTime {
            mutations.append(("style \(style)", { $0.timestampStyle = style }))
        }
        mutations.append(("utc", { $0.timeZone = .utc }))
        mutations.append(("pid", { $0.pidStyle = .pid }))
        for column in [LogColumn.tag, .package, .process] {
            mutations.append(("width \(column)", { $0.setWidth(($0.width(of: column) ?? 0) + 1, of: column) }))
        }
        mutations.append(("hide tags", { $0.hideRepeatedTags = true }))
        mutations.append(("hide packages", { $0.hideRepeatedPackages = true }))
        mutations.append(("hide processes", { $0.hideRepeatedProcesses = true }))
        mutations.append(("colors", { $0.colorTags = false }))

        for (name, mutate) in mutations {
            var options = LogViewOptions.standard
            mutate(&options)
            #expect(options.preset == nil, "\(name) should make the view Custom")
        }
    }

    @Test func choosingPresetRestoresIt() {
        var options = LogViewOptions.standard
        options.timestampStyle = .epoch
        options.setWidth(60, of: .tag)
        options.hideRepeatedTags = true
        #expect(options.preset == nil)
        options = LogViewOptions.Preset.standard.options
        #expect(options.preset == .standard)
        options = LogViewOptions.Preset.compact.options
        #expect(options.preset == .compact)
    }

    @Test func messageAlwaysVisible() {
        var options = LogViewOptions.standard
        options.setVisible(.message, false)
        #expect(options.isVisible(.message))
    }

    @Test func widthsClamp() {
        var options = LogViewOptions.standard
        options.setWidth(3, of: .tag)
        #expect(options.tagWidth == 10)
        options.setWidth(500, of: .package)
        #expect(options.packageWidth == 100)
        let before = options
        options.setWidth(40, of: .time)
        #expect(options == before)
        #expect(options.width(of: .time) == nil)
        #expect(options.width(of: .process) == 35)
    }

    @Test func differsOnlyInWidths() {
        var other = LogViewOptions.standard
        #expect(LogViewOptions.standard.differsOnlyInWidths(from: other))
        other.setWidth(40, of: .tag)
        #expect(LogViewOptions.standard.differsOnlyInWidths(from: other))
        other.hideRepeatedTags = true
        #expect(!LogViewOptions.standard.differsOnlyInWidths(from: other))
    }

    @Test func codableRoundTrip() throws {
        var options = LogViewOptions.compact
        options.setVisible(.process, true)
        options.timestampStyle = .delta
        options.timeZone = .utc
        options.pidStyle = .pid
        options.setWidth(44, of: .process)
        options.hideRepeatedPackages = true
        options.colorTags = false

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(options)
        #expect(try JSONDecoder().decode(LogViewOptions.self, from: data) == options)

        // The saved column order follows LogColumn.allCases, not Set iteration order, so the JSON is stable.
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""visibleColumns":["time","tag","process","level","message"]"#))
        #expect(try encoder.encode(options) == data)
    }

    @Test func decodesEmptyObjectAsStandard() throws {
        let options = try JSONDecoder().decode(LogViewOptions.self, from: Data("{}".utf8))
        #expect(options == .standard)
    }

    @Test func ignoresUnknownValues() throws {
        let json = #"{"visibleColumns":["time","uid","tag"],"timestampStyle":"bogus","tagWidth":4}"#
        let options = try JSONDecoder().decode(LogViewOptions.self, from: Data(json.utf8))
        #expect(options.visibleColumns == [.time, .tag, .message])
        #expect(options.timestampStyle == .dateTime)
        #expect(options.tagWidth == 10)
        #expect(options.preset == nil)
    }

    @Test func summaryNamesThePreset() {
        #expect(LogViewOptions.standard.summary.hasPrefix("preset=standard columns=time,pid,tag,package,level,message"))
        #expect(LogViewOptions.compact.summary.hasPrefix("preset=compact "))
        var custom = LogViewOptions.standard
        custom.hideRepeatedTags = true
        #expect(custom.summary.hasPrefix("preset=custom "))
        #expect(custom.summary.contains("hide=tag/-/-"))
    }

    // MARK: Layout

    @Test func layoutDefaultsToTable() {
        #expect(LogViewOptions.standard.layout == .table)
        #expect(LogViewOptions.compact.layout == .table)
        #expect(LogViewOptions(visibleColumns: [.message], timestampStyle: .time).layout == .table)
    }

    @Test func layoutIsNotPartOfAPreset() {
        var standard = LogViewOptions.standard
        standard.layout = .cards
        #expect(standard.preset == .standard)
        var compact = LogViewOptions.compact
        compact.layout = .cards
        #expect(compact.preset == .compact)
        standard.hideRepeatedTags = true
        #expect(standard.preset == nil)
    }

    @Test func applyingPresetKeepsLayout() {
        var options = LogViewOptions.standard
        options.layout = .cards
        options.timestampStyle = .epoch
        options.apply(.compact)
        #expect(options.layout == .cards)
        #expect(options.preset == .compact)
        #expect(options.timestampStyle == .time)

        var table = LogViewOptions.compact
        table.apply(.standard)
        #expect(table.layout == .table)
        #expect(table.preset == .standard)
    }

    @Test func layoutChangeIsNotWidthsOnly() {
        var cards = LogViewOptions.standard
        cards.layout = .cards
        #expect(!LogViewOptions.standard.differsOnlyInWidths(from: cards))
        #expect(!cards.differsOnlyInWidths(from: .standard))
    }

    @Test func cardSections() {
        #expect(LogViewOptions.standard.cardHasHeader)
        #expect(LogViewOptions.standard.cardHasFooter)
        #expect(LogViewOptions.compact.cardHasHeader)
        #expect(!LogViewOptions.compact.cardHasFooter)

        var bare = LogViewOptions.standard
        for column in [LogColumn.level, .tag, .time] { bare.setVisible(column, false) }
        #expect(!bare.cardHasHeader)
        #expect(bare.cardHasFooter)

        let processOnly = LogViewOptions(visibleColumns: [.message, .process], timestampStyle: .time)
        #expect(!processOnly.cardHasHeader)
        #expect(processOnly.cardHasFooter)
    }

    @Test func codableLayout() throws {
        var options = LogViewOptions.standard
        options.layout = .cards
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(options)
        #expect(String(decoding: data, as: UTF8.self).contains(#""layout":"cards""#))
        #expect(try JSONDecoder().decode(LogViewOptions.self, from: data) == options)

        #expect(try JSONDecoder().decode(LogViewOptions.self, from: Data("{}".utf8)).layout == .table)
        let bogus = try JSONDecoder().decode(LogViewOptions.self, from: Data(#"{"layout":"bogus"}"#.utf8))
        #expect(bogus.layout == .table)
        #expect(bogus.preset == .standard)
    }

    @Test func summaryShowsLayout() {
        #expect(LogViewOptions.standard.summary.hasSuffix(" layout=table"))
        var cards = LogViewOptions.standard
        cards.layout = .cards
        #expect(cards.summary.hasSuffix(" layout=cards"))
        #expect(cards.summary.hasPrefix("preset=standard "))
    }
}
