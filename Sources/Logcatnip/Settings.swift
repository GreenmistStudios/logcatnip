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
    static let processMarkers = "processMarkers"
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
            SettingsKey.processMarkers: ProcessMarkerScope.mine.rawValue,
        ])
    }

    static var myPackages: Set<String> {
        let raw = UserDefaults.standard.string(forKey: SettingsKey.myPackages) ?? ""
        return Set(raw.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init))
    }

    static var processMarkerScope: ProcessMarkerScope {
        ProcessMarkerScope(rawValue: UserDefaults.standard.string(forKey: SettingsKey.processMarkers) ?? "") ?? .mine
    }

    static var logcatBuffers: [String] {
        let raw = UserDefaults.standard.string(forKey: SettingsKey.logcatBuffers) ?? ""
        return raw.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
    }

    static var maxEntriesValue: Int {
        max(10_000, UserDefaults.standard.integer(forKey: SettingsKey.maxEntries))
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
