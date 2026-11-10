import Foundation
import Testing
@testable import LogcatKit

/// Talks to a real device. Run with `LOGCATNIP_DEVICE_TESTS=1 swift test` with a device attached.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LOGCATNIP_DEVICE_TESTS"] == "1"))
struct PackageUIDDeviceTests {
    @Test func readsPackageOwners() async throws {
        let adb = try #require(ADB.locate())
        let output = try await adb.run(["devices", "-l"]).output
        let devices = output.split(separator: "\n").dropFirst().compactMap { DeviceDescriptor.parse(line: $0) }
        let serial = try #require(devices.first(where: \.isOnline)?.serial, "No online device")
        let properties = try await adb.properties(serial: serial)
        // `pm list packages -U` needs Android 8.0.
        guard (properties.apiLevel ?? 0) >= 26 else { return }
        let map = try await adb.packagesByUID(serial: serial)
        #expect(map.count > 0)
    }
}
