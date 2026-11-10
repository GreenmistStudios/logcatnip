import Foundation

/// Tags and packages hidden in every session before the query applies, like Android Studio's ignore lists.
/// Matches are exact and case-sensitive, as in Android Studio, whatever the match-case toggle says.
public struct IgnoreList: Sendable, Equatable {
    /// In the order they were added, without duplicates or empty values.
    public private(set) var tags: [String]
    public private(set) var packages: [String]
    // Set lookups keep the per-entry check O(1) with hundreds of thousands of rows.
    private var tagSet: Set<String>
    private var packageSet: Set<String>

    /// Values are kept as given, never trimmed: a tag taken from a log line must match that line exactly. The
    /// Settings editor trims what the user types.
    public init(tags: [String] = [], packages: [String] = []) {
        let tags = Self.unique(tags)
        let packages = Self.unique(packages)
        self.tags = tags
        self.packages = packages
        self.tagSet = Set(tags)
        self.packageSet = Set(packages)
    }

    public var isEmpty: Bool { tags.isEmpty && packages.isEmpty }

    public func ignoresTag(_ tag: String) -> Bool { tagSet.contains(tag) }
    public func ignoresPackage(_ package: String) -> Bool { packageSet.contains(package) }

    /// Lets the filter skip resolving a package name when no package is ignored.
    var hasPackages: Bool { !packageSet.isEmpty }

    public func addingTag(_ tag: String) -> IgnoreList {
        guard !tag.isEmpty, !tagSet.contains(tag) else { return self }
        return IgnoreList(tags: tags + [tag], packages: packages)
    }

    public func removingTag(_ tag: String) -> IgnoreList {
        guard tagSet.contains(tag) else { return self }
        return IgnoreList(tags: tags.filter { $0 != tag }, packages: packages)
    }

    public func addingPackage(_ package: String) -> IgnoreList {
        guard !package.isEmpty, !packageSet.contains(package) else { return self }
        return IgnoreList(tags: tags, packages: packages + [package])
    }

    public func removingPackage(_ package: String) -> IgnoreList {
        guard packageSet.contains(package) else { return self }
        return IgnoreList(tags: tags, packages: packages.filter { $0 != package })
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// What a filter does with one entry.
public enum FilterOutcome: Sendable, Equatable {
    case shown
    /// Matches the query but its tag or package is on the ignore list. Showing ignored entries reveals exactly these.
    case ignored
    /// Rejected by the query, whether or not it is also ignored.
    case filteredOut
}

/// The query a new device session starts with, after Android Studio's `getDefaultFilter`.
public enum DefaultFilter {
    public static let mine = "package:mine"

    /// The default until the user sets one: `package:mine` when "my packages" are set, otherwise empty, because
    /// `package:mine` with no packages would only add noise to the field.
    public static func fallback(myPackages: Set<String>) -> String {
        myPackages.isEmpty ? "" : mine
    }

    /// A recorded most recently used query wins when the user asked for it, even an empty one. Otherwise the
    /// configured default wins, even an empty one; `configured == nil` means the user never set one.
    public static func initialQuery(
        configured: String?,
        mostRecentlyUsed: String?,
        useMostRecent: Bool,
        myPackages: Set<String>
    ) -> String {
        if useMostRecent, let mostRecentlyUsed { return mostRecentlyUsed }
        return configured ?? fallback(myPackages: myPackages)
    }
}
