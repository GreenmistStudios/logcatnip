import Foundation
import LogcatKit

enum SettingsKey {
    static let adbPath = "adbPath"
    static let maxEntries = "maxEntries"
    static let myPackages = "myPackages"
    static let fontSize = "fontSize"
    static let logcatBuffers = "logcatBuffers"
    static let filterHistory = "filterHistory"
    static let favoriteFilters = "favoriteFilters"
    static let autoOpenSessions = "autoOpenSessions"
    static let wrapLines = "wrapLines"
    static let filterPrecedenceChecked = "filterPrecedenceChecked"
    static let precedenceChangedFilters = "precedenceChangedFilters"
    static let filterHistoryAutocomplete = "filterHistoryAutocomplete"
    static let ignoredTags = "ignoredTags"
    static let ignoredPackages = "ignoredPackages"
    /// Absent until the user edits it, so the default can follow "my packages".
    static let defaultFilter = "defaultFilter"
    static let mostRecentlyUsedFilterIsDefault = "mostRecentlyUsedFilterIsDefault"
    static let mostRecentlyUsedFilter = "mostRecentlyUsedFilter"
}

enum Defaults {
    static let maxEntries = 250_000
    static let fontSize = 12.0

    static func register() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.maxEntries: maxEntries,
            SettingsKey.fontSize: fontSize,
            SettingsKey.autoOpenSessions: true,
            SettingsKey.wrapLines: false,
            SettingsKey.logcatBuffers: "",
            SettingsKey.filterPrecedenceChecked: false,
            SettingsKey.filterHistoryAutocomplete: false,
            SettingsKey.mostRecentlyUsedFilterIsDefault: false,
        ])
    }

    static var myPackages: Set<String> {
        let raw = UserDefaults.standard.string(forKey: SettingsKey.myPackages) ?? ""
        return Set(raw.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init))
    }

    static var logcatBuffers: [String] {
        let raw = UserDefaults.standard.string(forKey: SettingsKey.logcatBuffers) ?? ""
        return raw.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
    }

    static var maxEntriesValue: Int {
        max(10_000, UserDefaults.standard.integer(forKey: SettingsKey.maxEntries))
    }

    /// The saved ignore lists, for code that has no `AppModel` (and for the `.logcat` metadata to read).
    static var ignoreList: IgnoreList {
        let defaults = UserDefaults.standard
        return IgnoreList(
            tags: defaults.stringArray(forKey: SettingsKey.ignoredTags) ?? [],
            packages: defaults.stringArray(forKey: SettingsKey.ignoredPackages) ?? []
        )
    }

    /// The query a new device session starts with.
    static var newSessionFilter: String {
        DefaultFilter.initialQuery(
            configured: UserDefaults.standard.string(forKey: SettingsKey.defaultFilter),
            mostRecentlyUsed: FilterLibrary.mostRecentlyUsed,
            useMostRecent: UserDefaults.standard.bool(forKey: SettingsKey.mostRecentlyUsedFilterIsDefault),
            myPackages: myPackages
        )
    }
}

/// Recent and favorite filter queries, shared by all sessions.
enum FilterLibrary {
    static let historyLimit = 30

    static var history: [String] {
        UserDefaults.standard.stringArray(forKey: SettingsKey.filterHistory) ?? []
    }

    static var favorites: [String] {
        UserDefaults.standard.stringArray(forKey: SettingsKey.favoriteFilters) ?? []
    }

    static func remember(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var items = history.filter { $0 != trimmed }
        items.insert(trimmed, at: 0)
        UserDefaults.standard.set(Array(items.prefix(historyLimit)), forKey: SettingsKey.filterHistory)
    }

    static func isFavorite(_ query: String) -> Bool {
        favorites.contains(query.trimmingCharacters(in: .whitespaces))
    }

    static func toggleFavorite(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var items = favorites
        if let index = items.firstIndex(of: trimmed) {
            items.remove(at: index)
        } else {
            items.append(trimmed)
        }
        UserDefaults.standard.set(items, forKey: SettingsKey.favoriteFilters)
    }

    /// The last query applied in any session, for "use the most recently used filter". Nil until one is applied.
    static var mostRecentlyUsed: String? {
        UserDefaults.standard.string(forKey: SettingsKey.mostRecentlyUsedFilter)
    }

    static func noteMostRecentlyUsed(_ query: String) {
        guard mostRecentlyUsed != query else { return }
        UserDefaults.standard.set(query, forKey: SettingsKey.mostRecentlyUsedFilter)
    }

    static func clearHistory() {
        UserDefaults.standard.removeObject(forKey: SettingsKey.filterHistory)
    }

    /// Marks saved queries whose meaning changed when whitespace got the lowest precedence (0.2). It runs once,
    /// so queries typed after the upgrade are never flagged.
    static func flagPrecedenceChangesOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: SettingsKey.filterPrecedenceChecked) else { return }
        defaults.set(true, forKey: SettingsKey.filterPrecedenceChecked)
        let changed = Set(favorites + history).filter(LogFilter.meaningChangedByPrecedence).sorted()
        if !changed.isEmpty {
            defaults.set(changed, forKey: SettingsKey.precedenceChangedFilters)
        }
    }

    /// The flagged queries that are still saved, so removing a favorite or clearing recents drops its flag.
    static var precedenceChanged: Set<String> {
        let flagged = UserDefaults.standard.stringArray(forKey: SettingsKey.precedenceChangedFilters) ?? []
        guard !flagged.isEmpty else { return [] }
        return Set(flagged).intersection(favorites + history)
    }

    static func dismissPrecedenceWarnings() {
        UserDefaults.standard.removeObject(forKey: SettingsKey.precedenceChangedFilters)
    }
}
