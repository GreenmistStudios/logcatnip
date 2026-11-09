import Foundation
import Testing
@testable import LogcatKit

/// Talks to a real device. Run with `LOGCATNIP_DEVICE_TESTS=1 swift test` with a device attached.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LOGCATNIP_DEVICE_TESTS"] == "1"))
struct DeviceIntegrationTests {
    private func firstOnlineSerial(_ adb: ADB) async throws -> String {
        let output = try await adb.run(["devices", "-l"]).output
        let devices = output.split(separator: "\n").dropFirst().compactMap { DeviceDescriptor.parse(line: $0) }
        return try #require(devices.first(where: \.isOnline)?.serial, "No online device")
    }

    @Test func tracksDevices() async throws {
        let adb = try #require(ADB.locate())
        for await event in adb.trackDevices() {
            if case let .devices(devices) = event, !devices.isEmpty {
                #expect(devices.contains { $0.isOnline })
                return
            }
        }
    }

    @Test func readsPropertiesAndProcesses() async throws {
        let adb = try #require(ADB.locate())
        let serial = try await firstOnlineSerial(adb)
        let properties = try await adb.properties(serial: serial)
        #expect((properties.apiLevel ?? 0) > 0)
        let processes = try await adb.processes(serial: serial)
        #expect(processes.values.contains("system_server"))
    }

    @Test func streamsAndFiltersLogcat() async throws {
        let adb = try #require(ADB.locate())
        let serial = try await firstOnlineSerial(adb)
        var entries: [LogEntry] = []
        let deadline = Date().addingTimeInterval(5)
        for await event in adb.logcat(serial: serial) {
            if case let .entries(batch) = event { entries += batch }
            if entries.count > 2000 || Date() > deadline { break }
        }
        #expect(!entries.isEmpty)
        #expect(entries.contains { $0.uid != nil })

        let processes = try await adb.processes(serial: serial)
        let filter = try LogFilter("level:INFO -tag:nonexistent")
        let context = FilterContext(processNames: processes)
        let matched = entries.filter { filter.matches($0, context: context) }
        #expect(matched.allSatisfy { $0.level >= .info })
        print("streamed \(entries.count) entries; \(matched.count) at INFO+; resolved \(entries.filter { processes[$0.pid] != nil }.count) process names")
    }
}
