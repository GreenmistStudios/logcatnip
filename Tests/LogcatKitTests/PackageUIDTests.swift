import Foundation
import Testing
@testable import LogcatKit

/// An excerpt of `pm list packages -U` from an API 37 emulator. uid 10106 is shared by five packages and
/// 1000 / 1001 are system uids.
private let emulatorList = """
package:com.android.providers.telephony uid:1001
package:com.android.phone uid:1001
package:com.android.calllogbackup uid:10106
package:com.android.providers.contacts uid:10106
package:com.android.providers.blockednumber uid:10106
package:com.android.providers.userdictionary uid:10106
package:com.android.providers.contactkeys uid:10106
package:com.google.android.gms uid:10223
package:studio.greenmist.test.lane2 uid:10233
package:android uid:1000
package:com.android.settings uid:1000

"""

/// Android 13+ lists the uids of every user, comma-joined. Derived from AOSP main
/// `PackageManagerShellCommand.runListPackages`.
private let multiUserList = """
package:com.example.both uid:10241,1010241
package:com.example.personal uid:10243
package:com.example.workonly uid:1010242

"""

private func logEntry(process: String? = nil, uid: String? = nil) -> LogEntry {
    LogEntry(timestamp: 0, uid: uid, pid: 100, tid: 100, level: .info, tag: "Tag", message: "m", processName: process)
}

@Suite struct PackageUIDTests {
    @Test func parsesSingleUserList() {
        let map = PackageUIDMap.parse(emulatorList)
        #expect(map.owner(forUID: 10233)?.packages == ["studio.greenmist.test.lane2"])
        #expect(map.owner(forUID: 10233)?.label == "studio.greenmist.test.lane2")
        #expect(map.owner(forUID: "10223")?.packages == ["com.google.android.gms"])
        #expect(map.owner(forUID: 1000) == nil)
        #expect(map.owner(forUID: 1001) == nil)
        #expect(map.count == 3)
    }

    @Test func parsesSharedUID() {
        let owner = PackageUIDMap.parse(emulatorList).owner(forUID: 10106)
        let packages = [
            "com.android.calllogbackup", "com.android.providers.blockednumber", "com.android.providers.contactkeys",
            "com.android.providers.contacts", "com.android.providers.userdictionary",
        ]
        #expect(owner?.packages == packages)
        #expect(owner?.label == packages.joined(separator: " | "))
    }

    @Test func parsesMultiUserUIDLists() {
        let map = PackageUIDMap.parse(multiUserList)
        #expect(map.owner(forUID: 10241)?.packages == ["com.example.both"])
        #expect(map.owner(forUID: 1_010_241)?.packages == ["com.example.both"])
        // A package installed only for the work profile still resolves in user 0 and back, by app id.
        #expect(map.owner(forUID: 1_010_242)?.packages == ["com.example.workonly"])
        #expect(map.owner(forUID: 10242)?.packages == ["com.example.workonly"])
        #expect(map.owner(forUID: 1_010_243)?.packages == ["com.example.personal"])
        #expect(map.count == 3)
    }

    @Test func secondaryUserUIDMapsByAppID() {
        let map = PackageUIDMap.parse(emulatorList)
        #expect(map.owner(forUID: "1010233")?.packages == ["studio.greenmist.test.lane2"])
    }

    @Test func isolatedSandboxAndSystemUIDsStayUnresolved() {
        let map = PackageUIDMap(owners: [10233: ["a"]])
        for uid in [99000, 99005, 90000, 1_099_001, 20233, 1000, 0, -1] {
            #expect(map.owner(forUID: uid) == nil, "\(uid)")
        }
        for text in ["system", "shell", "", nil] as [String?] {
            #expect(map.owner(forUID: text) == nil, "\(text ?? "nil")")
        }
        #expect(PackageUIDMap.appID(forUID: 19999) == 19999)
        #expect(PackageUIDMap.appID(forUID: 20000) == nil)
        #expect(PackageUIDMap.appID(forUID: 10000) == 10000)
        #expect(PackageUIDMap.appID(forUID: 9999) == nil)
        #expect(PackageUIDMap.appID(forUID: 1_010_233) == 10233)
        #expect(PackageUIDMap.uid(fromLogcat: "10233") == 10233)
        #expect(PackageUIDMap.uid(fromLogcat: "shell") == nil)
        #expect(PackageUIDMap.uid(fromLogcat: nil) == nil)
    }

    @Test func ignoresErrorsApexAndBlankLines() {
        #expect(PackageUIDMap.parse("Error: Unknown option: -U\n").count == 0)
        #expect(PackageUIDMap.parse("").count == 0)

        let text = "package:com.android.apex.foo\r\n\r\n"
            + "package:com.example.a uid:10001\r\n"
            + "package:com.example.a uid:10001\r\n"
            + "package: uid:10002\r\n"
            + "package:bad name uid:10003\r\n"
            + "package:com.example.b uid:oops\r\n"
            + "package:com.example.c uid:10004,xx\r\n"
            + "warning: something else\r\n"
        let map = PackageUIDMap.parse(text)
        #expect(map.count == 2)
        #expect(map.owner(forUID: 10001)?.packages == ["com.example.a"])
        #expect(map.owner(forUID: 10002) == nil)
        #expect(map.owner(forUID: 10003) == nil)
        #expect(map.owner(forUID: 10004)?.packages == ["com.example.c"])
    }

    @Test func resolvedPackagePrefersProcessName() {
        let map = PackageUIDMap.parse(emulatorList)
        #expect(map.resolvedPackage(for: logEntry(process: "com.foo:remote", uid: "10233"))
            == ResolvedPackage(packages: ["com.foo"], label: "com.foo", viaUID: false))
        #expect(map.resolvedPackage(for: logEntry(uid: "10233"))
            == ResolvedPackage(packages: ["studio.greenmist.test.lane2"], label: "studio.greenmist.test.lane2", viaUID: true))

        let shared = map.resolvedPackage(for: logEntry(uid: "10106"))
        #expect(shared?.packages.count == 5)
        #expect(shared?.label.contains(" | ") == true)
        #expect(shared?.viaUID == true)

        #expect(map.resolvedPackage(for: logEntry(uid: "system")) == nil)
        #expect(map.resolvedPackage(for: logEntry()) == nil)
        #expect(map.resolvedPackage(for: LogEntry.marker("restarted")) == nil)
    }
}

@Suite struct PackageFilterTests {
    private func matches(_ query: String, _ entry: LogEntry, mine: Set<String> = [], packages: PackageUIDMap) throws -> Bool {
        let context = FilterContext(myPackages: mine, packages: packages)
        return try LogFilter(query).matches(entry, context: context)
    }

    @Test func packageMineMatchesViaUID() throws {
        let map = PackageUIDMap.parse(emulatorList)
        let e = logEntry(uid: "10233")
        let mine: Set<String> = ["studio.greenmist.test.lane2"]
        #expect(try matches("package:mine", e, mine: mine, packages: map))
        #expect(try !matches("package:mine", e, mine: mine, packages: PackageUIDMap()))
        #expect(try matches("package:studio.greenmist", e, packages: map))
        #expect(try !matches("package:other", e, packages: map))
    }

    @Test func packageTermsMatchAnySharedUIDOwner() throws {
        let map = PackageUIDMap.parse(emulatorList)
        let e = logEntry(uid: "10106")
        #expect(try matches("package=:com.android.providers.contacts", e, packages: map))
        #expect(try matches("package=:com.android.calllogbackup", e, packages: map))
        #expect(try matches("-package:com.android.mtp", e, packages: map))
        #expect(try !matches("-package=:com.android.providers.contacts", e, packages: map))
        // `process:` has no uid fallback: the process was never seen.
        #expect(try !matches("process:com.android", e, packages: map))
        #expect(try matches("package:mine", e, mine: ["com.android.providers.contacts"], packages: map))
        #expect(try !matches("package:mine", e, mine: ["com.example"], packages: map))
    }

    @Test func processNameWinsOverUID() throws {
        let map = PackageUIDMap.parse(emulatorList)
        let e = logEntry(process: "com.foo:remote", uid: "10233")
        #expect(try matches("package=:com.foo", e, packages: map))
        #expect(try !matches("package:greenmist", e, packages: map))
        #expect(try matches("process=:com.foo:remote", e, packages: map))
    }
}

@Suite struct PackageUIDTrackerTests {
    private let emulatorMap = PackageUIDMap.parse(emulatorList)

    @Test func knownUIDsNeedNoRefresh() {
        var tracker = PackageUIDTracker(map: emulatorMap)
        for uid in [10233, 1_010_233, 1000, 99001, 20233] { tracker.note(uid: uid) }
        #expect(!tracker.needsRefresh)
    }

    @Test func unknownAppUIDRefreshesOnce() {
        var tracker = PackageUIDTracker(map: emulatorMap)
        tracker.note(uid: 10300)
        #expect(tracker.needsRefresh)
        let refresh = tracker.beginRefresh()
        #expect(!tracker.needsRefresh)
        let changed = tracker.finishRefresh(refresh, with: emulatorMap)
        #expect(!changed)
        #expect(!tracker.needsRefresh)

        // The same app id (in any user) was asked about and is not installed, so it is not asked again.
        tracker.note(uid: 10300)
        tracker.note(uid: 1_010_300)
        #expect(!tracker.needsRefresh)
        tracker.note(uid: 10301)
        #expect(tracker.needsRefresh)
    }

    @Test func uidsNotedDuringRefreshAreCovered() {
        var tracker = PackageUIDTracker(map: emulatorMap)
        tracker.note(uid: 10300)
        let refresh = tracker.beginRefresh()
        tracker.note(uid: 10302)
        #expect(tracker.needsRefresh)
        tracker.finishRefresh(refresh, with: emulatorMap)
        #expect(!tracker.needsRefresh)
    }

    @Test func failedRefreshStopsAsking() {
        var tracker = PackageUIDTracker(map: emulatorMap)
        tracker.note(uid: 10300)
        let refresh = tracker.beginRefresh()
        tracker.failRefresh(refresh)
        #expect(tracker.isUnavailable)
        tracker.note(uid: 10400)
        #expect(!tracker.needsRefresh)

        tracker.reset()
        #expect(!tracker.isUnavailable)
        tracker.note(uid: 10400)
        #expect(tracker.needsRefresh)
        #expect(tracker.map == emulatorMap)
    }

    @Test func finishReportsWhetherMapChanged() {
        var tracker = PackageUIDTracker()
        tracker.note(uid: 10233)
        let first = tracker.beginRefresh()
        let firstChanged = tracker.finishRefresh(first, with: emulatorMap)
        #expect(firstChanged)
        tracker.note(uid: 10999)
        let second = tracker.beginRefresh()
        let secondChanged = tracker.finishRefresh(second, with: emulatorMap)
        #expect(!secondChanged)
        #expect(tracker.map == emulatorMap)
    }

    /// A reinstall gets a new uid and the old one drops out of `pm list packages`; the entries the old
    /// install logged must keep their package.
    @Test func refreshKeepsOwnersOfAppsThatWentAway() {
        var tracker = PackageUIDTracker(map: PackageUIDMap(owners: [10234: ["com.a"], 10240: ["com.b"]]))
        tracker.note(uid: 10235)
        let refresh = tracker.beginRefresh()
        let changed = tracker.finishRefresh(refresh, with: PackageUIDMap(owners: [10235: ["com.a"], 10240: ["com.b2"]]))
        #expect(changed)
        #expect(tracker.map.owner(forUID: 10234)?.packages == ["com.a"])
        #expect(tracker.map.owner(forUID: 10235)?.packages == ["com.a"])
        #expect(tracker.map.owner(forUID: 10240)?.packages == ["com.b2"])
        #expect(tracker.map.count == 3)
    }
}
