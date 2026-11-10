import Foundation

/// Which packages own each app uid, from `pm list packages -U`. Keyed by app id (`uid % 100000`), so the
/// uid of a package in any user resolves. Several packages can share one uid.
public struct PackageUIDMap: Sendable, Equatable {
    public struct Owner: Sendable, Equatable {
        /// Sorted, so the label does not change between refreshes.
        public let packages: [String]
        /// The packages joined with `" | "`, for display.
        public let label: String
    }

    private var byAppID: [Int: Owner]

    /// `owners` maps an app id to its packages; they are sorted, deduplicated and labelled here.
    public init(owners: [Int: [String]] = [:]) {
        byAppID = owners.reduce(into: [:]) { result, item in
            let packages = Array(Set(item.value)).sorted()
            guard !packages.isEmpty else { return }
            result[item.key] = Owner(packages: packages, label: packages.joined(separator: " | "))
        }
    }

    /// This map with the app ids of `newer` replaced. Apps that left the list stay: their uid dropped out of
    /// `pm list packages` (uninstalled, or reinstalled under a new uid), but the entries they logged are
    /// still in the buffer.
    public func merging(_ newer: PackageUIDMap) -> PackageUIDMap {
        var merged = self
        merged.byAppID.merge(newer.byAppID) { _, new in new }
        return merged
    }

    /// The number of app ids with an owner.
    public var count: Int { byAppID.count }

    /// Reads `pm list packages -U` output: `package:<name> uid:<uid>`, where Android 13 and later join the
    /// uids of several users with commas (`uid:10241,1010241`). Anything else is ignored: errors from
    /// releases without `-U`, APEX modules (no uid) and blank lines.
    public static func parse(_ text: String) -> PackageUIDMap {
        var owners: [Int: Set<String>] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("package:") else { continue }
            let rest = line.dropFirst("package:".count)
            guard let marker = rest.range(of: " uid:", options: .backwards) else { continue }
            let name = rest[..<marker.lowerBound]
            guard !name.isEmpty, !name.contains(where: \.isWhitespace) else { continue }
            for uidText in rest[marker.upperBound...].split(separator: ",") {
                guard let uid = Int(uidText), let appID = appID(forUID: uid) else { continue }
                owners[appID, default: []].insert(String(name))
            }
        }
        return PackageUIDMap(owners: owners.mapValues { Array($0) })
    }

    /// The app id of a uid that belongs to an installed app, nil for system uids (below 10000), SDK sandbox
    /// uids (20000 to 29999) and isolated uids (90000 and up), which have no package of their own.
    public static func appID(forUID uid: Int) -> Int? {
        guard uid >= 0 else { return nil }
        let appID = uid % 100_000
        return (10_000..<20_000).contains(appID) ? appID : nil
    }

    /// The number in a `-v uid` column, nil for names such as `system` or `shell`.
    public static func uid(fromLogcat text: String?) -> Int? {
        guard let text, !text.isEmpty, text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return Int(text)
    }

    public func owner(forAppID appID: Int) -> Owner? { byAppID[appID] }

    public func owner(forUID uid: Int) -> Owner? {
        Self.appID(forUID: uid).flatMap { byAppID[$0] }
    }

    /// The owners of the uid in a `-v uid` column.
    public func owner(forUID text: String?) -> Owner? {
        Self.uid(fromLogcat: text).flatMap { owner(forUID: $0) }
    }

    /// The package to show for an entry: its process name's package, else the owners of its uid. A process
    /// name wins even when it is not a package (`android.process.acore`), because it is what the process
    /// really was; the uid only fills in for processes that were never seen.
    public func resolvedPackage(for entry: LogEntry) -> ResolvedPackage? {
        guard entry.kind == .log else { return nil }
        if let process = entry.processName {
            let package = LogEntry.packageName(forProcess: process)
            return ResolvedPackage(packages: [package], label: package, viaUID: false)
        }
        guard let owner = owner(forUID: entry.uid) else { return nil }
        return ResolvedPackage(packages: owner.packages, label: owner.label, viaUID: true)
    }
}

/// The package (or packages, for a shared uid) an entry belongs to.
public struct ResolvedPackage: Sendable, Equatable {
    public var packages: [String]
    public var label: String
    /// True when the package comes from the uid because the process was never named.
    public var viaUID: Bool

    public init(packages: [String], label: String, viaUID: Bool) {
        self.packages = packages
        self.label = label
        self.viaUID = viaUID
    }
}

/// Decides when to read `pm list packages -U` again: when the session starts, then only for app uids the map
/// lacks, each asked about at most once, so a session whose processes all resolve makes no extra calls.
public struct PackageUIDTracker: Sendable {
    /// A refresh in progress and the app ids it answers for.
    public struct Refresh: Sendable, Equatable {
        let covering: Set<Int>
    }

    public private(set) var map: PackageUIDMap
    /// Set when `pm` failed, which on old releases means it has no `-U`. Nothing asks again this stream.
    public private(set) var isUnavailable = false
    private var wanted: Set<Int> = []
    private var asked: Set<Int> = []

    public init(map: PackageUIDMap = PackageUIDMap()) {
        self.map = map
    }

    public var needsRefresh: Bool { !isUnavailable && !wanted.isEmpty }

    /// Records the uid of an entry whose process was never named. Only an app uid the map lacks, and has
    /// not asked about yet, counts.
    public mutating func note(uid: Int) {
        guard !isUnavailable, let appID = PackageUIDMap.appID(forUID: uid),
              map.owner(forAppID: appID) == nil, !asked.contains(appID) else { return }
        wanted.insert(appID)
    }

    public mutating func beginRefresh() -> Refresh {
        defer { wanted = [] }
        return Refresh(covering: wanted)
    }

    /// Merges the list into the map and returns whether the map changed. App ids noted up to now count as
    /// asked even if `newMap` lacks them, because an app that is not installed will not be installed by
    /// asking again.
    @discardableResult
    public mutating func finishRefresh(_ refresh: Refresh, with newMap: PackageUIDMap) -> Bool {
        let merged = map.merging(newMap)
        let changed = merged != map
        map = merged
        asked.formUnion(refresh.covering)
        asked.formUnion(wanted)
        wanted = []
        return changed
    }

    public mutating func failRefresh(_ refresh: Refresh) {
        isUnavailable = true
        wanted = []
    }

    /// A new logcat stream (the first one, or after a reconnect) may see apps installed in between, so it
    /// asks again. The map is kept: it is still right for the uids it knows.
    public mutating func reset() {
        isUnavailable = false
        wanted = []
        asked = []
    }
}

extension ADB {
    /// App uid owners. `-U` needs Android 8.0; `-u` adds packages installed only for other users on the
    /// releases that list user 0 by default.
    public func packagesByUID(serial: String) async throws -> PackageUIDMap {
        PackageUIDMap.parse(try await shell(serial: serial, "pm list packages -U -u"))
    }
}
