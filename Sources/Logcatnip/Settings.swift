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
    /// Soft wrap for sessions opened from now on: each session wraps on its own, and the last value chosen
    /// with View > Soft Wrap (or the toolbar button) becomes the next session's starting point.
    static let wrapLines = "wrapLines"
    /// View options for sessions opened from now on, as `LogViewOptions` JSON. Empty means Standard.
    static let defaultViewOptions = "defaultViewOptions"
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
            SettingsKey.defaultViewOptions: "",
            SettingsKey.logcatBuffers: "",
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

    /// The view options new sessions start with: Standard unless the user saved something else.
    static var viewOptions: LogViewOptions {
        LogViewOptions(json: UserDefaults.standard.string(forKey: SettingsKey.defaultViewOptions) ?? "") ?? .standard
    }

    static func setViewOptions(_ options: LogViewOptions) {
        UserDefaults.standard.set(options.json, forKey: SettingsKey.defaultViewOptions)
    }
}

extension LogViewOptions {
    /// The options as the JSON stored in Settings, with stable key order so equal options save equal text.
    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// Reads Settings JSON. Nil for empty or malformed text, which callers treat as Standard.
    init?(json: String) {
        guard !json.isEmpty, let options = try? JSONDecoder().decode(LogViewOptions.self, from: Data(json.utf8)) else { return nil }
        self = options
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

    static func clearHistory() {
        UserDefaults.standard.removeObject(forKey: SettingsKey.filterHistory)
    }
}
