import Foundation

/// Which packages own each app uid, from `pm list packages -U`. Keyed by app id (`uid % 100000`), so the
/// uid of a package in any user resolves. Several packages can share one uid.
public struct PackageUIDMap: Sendable, Equatable {
    public struct Owner: Sendable, Hashable {
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

    fileprivate func removing(_ appIDs: Set<Int>) -> PackageUIDMap {
        var result = self
        for appID in appIDs { result.byAppID[appID] = nil }
        return result
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

    /// Prefer the captured attribution when this uid has since changed owners.
    public func owner(for entry: LogEntry) -> Owner? {
        entry.uidOwner ?? owner(forUID: entry.uid)
    }

    public func stamp(_ entry: inout LogEntry) {
        guard entry.kind == .log, entry.uidOwner == nil else { return }
        entry.uidOwner = owner(forUID: entry.uid)
    }

    /// Called only on snapshot changes, not for each displayed row.
    public func stamp(_ entries: inout [LogEntry]) {
        for index in entries.indices { stamp(&entries[index]) }
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
        guard let owner = owner(for: entry) else { return nil }
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

/// Refreshes missing app uids once and known owners when a process-start identity contradicts them.
public struct PackageUIDTracker: Sendable {
    /// A refresh in progress and the app ids it answers for.
    public struct Refresh: Sendable, Equatable {
        let covering: Set<Int>
        let revision: Int
    }

    public private(set) var map: PackageUIDMap
    /// Set when `pm` failed, which on old releases means it has no `-U`. Nothing asks again this stream.
    public private(set) var isUnavailable = false
    private var wanted: Set<Int> = []
    private var asked: Set<Int> = []
    private var revision = 0
    private var invalidated: [Int: Int] = [:]
    private var checkedIdentities: [Int: Set<String>] = [:]

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

    /// A custom/shared-uid process name may legitimately differ from the package list. Check each
    /// conflicting identity once per stream, rather than repeatedly refreshing on every start event.
    public mutating func processStarted(uid: Int, process: String) {
        guard !isUnavailable, let appID = PackageUIDMap.appID(forUID: uid) else { return }
        guard let owner = map.owner(forAppID: appID) else {
            note(uid: uid)
            return
        }
        let package = LogEntry.packageName(forProcess: process)
        guard !owner.packages.contains(package),
              checkedIdentities[appID, default: []].insert(package).inserted else { return }
        revision += 1
        invalidated[appID] = revision
        map = map.removing([appID])
        asked.remove(appID)
        wanted.insert(appID)
    }

    public mutating func beginRefresh() -> Refresh {
        defer { wanted = [] }
        return Refresh(covering: wanted, revision: revision)
    }

    /// Only ids covered at request start count as asked. Missing ids first seen during the read still
    /// need a follow-up; re-noting a covered id must not cause endless retries.
    @discardableResult
    public mutating func finishRefresh(_ refresh: Refresh, with newMap: PackageUIDMap) -> Bool {
        invalidated = invalidated.filter { $0.value > refresh.revision }
        let pendingInvalidation = Set(invalidated.keys)
        let snapshot = newMap.removing(pendingInvalidation)
        let changed = snapshot != map
        map = snapshot
        asked.formUnion(refresh.covering.subtracting(pendingInvalidation))
        wanted = wanted.filter { !asked.contains($0) && map.owner(forAppID: $0) == nil }
        return changed
    }

    public mutating func failRefresh(_ refresh: Refresh) {
        isUnavailable = true
        wanted = []
    }

    /// A new logcat stream (the first one, or after a reconnect) may see apps installed in between, so it
    /// asks again. Buffered entries keep their stamped owners; new entries wait for a fresh snapshot.
    public mutating func reset() {
        isUnavailable = false
        wanted = []
        asked = []
        map = PackageUIDMap()
        invalidated = [:]
        checkedIdentities = [:]
    }
}

extension ADB {
    /// App uid owners. `-U` needs Android 8.0; `-u` adds packages installed only for other users on the
    /// releases that list user 0 by default.
    public func packagesByUID(serial: String) async throws -> PackageUIDMap {
        PackageUIDMap.parse(try await shell(serial: serial, "pm list packages -U -u"))
    }
}
