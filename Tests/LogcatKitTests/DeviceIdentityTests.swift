import Foundation
import Testing
@testable import LogcatKit

@Suite struct DeviceIdentityTests {
    // Taken from the shared API 37 emulator: `ro.serialno` encodes the emulator build, so every AVD on it
    // reports the same value and only the AVD name tells them apart.
    static let emulatorLine = "emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:4"
    static let emulatorProps = DeviceProperties.parse("""
    [ro.boot.qemu]: [1]
    [ro.boot.qemu.avd_name]: [Medium_Phone_API_37.0]
    [ro.boot.serialno]: [EMULATOR37X2X12X0]
    [ro.build.version.sdk]: [37]
    [ro.kernel.qemu]: [1]
    [ro.product.model]: [sdk_gphone64_arm64]
    [ro.serialno]: [EMULATOR37X2X12X0]
    """)
    static let otherEmulatorProps = DeviceProperties.parse("""
    [ro.boot.qemu]: [1]
    [ro.boot.qemu.avd_name]: [Pixel_9_API_37]
    [ro.boot.serialno]: [EMULATOR37X2X12X0]
    [ro.kernel.qemu]: [1]
    [ro.serialno]: [EMULATOR37X2X12X0]
    """)
    static let phoneProps = DeviceProperties.parse("""
    [ro.build.version.sdk]: [37]
    [ro.product.manufacturer]: [Google]
    [ro.product.model]: [Pixel 8]
    [ro.serialno]: [35121FDJH000R8]
    """)
    static let usbLine = "35121FDJH000R8         device usb:1-1 product:shiba model:Pixel_8 device:shiba transport_id:7"
    static let wifiLine = "192.168.1.50:41001     device product:shiba model:Pixel_8 device:shiba transport_id:8"
    static let mdnsLine = "adb-35121FDJH000R8-xyMD0H._adb-tls-connect._tcp device product:shiba model:Pixel_8 device:shiba transport_id:9"

    static let phone = DeviceIdentity(kind: .serialNumber, value: "35121FDJH000R8")
    static let avd = DeviceIdentity(kind: .avd, value: "Medium_Phone_API_37.0")

    func descriptor(_ line: String) throws -> DeviceDescriptor {
        try #require(DeviceDescriptor.parse(line: Substring(line)))
    }

    func transport(_ serial: String, _ kind: DeviceTransport, _ identity: DeviceIdentity?, online: Bool = true) -> TransportState {
        TransportState(serial: serial, transport: kind, identity: identity, isOnline: online)
    }

    // MARK: Transport and parsing

    @Test func classifiesUSBTransport() throws {
        let usb = try descriptor(Self.usbLine)
        #expect(DeviceTransport(descriptor: usb, properties: nil) == .usb)
        #expect(DeviceTransport(descriptor: usb, properties: Self.phoneProps) == .usb)
    }

    @Test func classifiesEmulatorBySerial() throws {
        let emulator = try descriptor(Self.emulatorLine)
        #expect(DeviceTransport(descriptor: emulator, properties: nil) == .emulator)
    }

    @Test func classifiesEmulatorReachedOverTCP() throws {
        let line = "127.0.0.1:5555 device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:5"
        let tcp = try descriptor(line)
        #expect(DeviceTransport(descriptor: tcp, properties: Self.emulatorProps) == .emulator)
        #expect(DeviceTransport(descriptor: tcp, properties: nil) == .wifi)
    }

    @Test func classifiesWifiTransports() throws {
        for line in [Self.wifiLine, Self.mdnsLine, "[fe80::1]:5555 device"] {
            let wifi = try descriptor(line)
            #expect(wifi.isNetworkTransport, "\(line)")
            #expect(DeviceTransport(descriptor: wifi, properties: nil) == .wifi, "\(line)")
        }
        #expect(try !descriptor(Self.usbLine).isNetworkTransport)
        #expect(try !descriptor("emulator-5554 device").isNetworkTransport)
        #expect(try !descriptor("ABC:DEF device").isNetworkTransport)
    }

    @Test func parsesMdnsSerial() throws {
        #expect(try descriptor(Self.mdnsLine).mdnsSerial == "35121FDJH000R8")
        // A serial that contains a dash keeps it; only the last dash-separated part is the instance id.
        #expect(try descriptor("adb-ABC-DEF-xyMD0H._adb-tls-connect._tcp device").mdnsSerial == "ABC-DEF")
        #expect(try descriptor(Self.wifiLine).mdnsSerial == nil)
        #expect(try descriptor(Self.usbLine).mdnsSerial == nil)
        #expect(try descriptor(Self.emulatorLine).mdnsSerial == nil)
        #expect(try descriptor("adb-NOID._adb-tls-connect._tcp device").mdnsSerial == nil)
    }

    @Test func readsSerialNumber() {
        #expect(Self.phoneProps.serialNumber == "35121FDJH000R8")
        #expect(DeviceProperties.parse("[ro.serialno]: [unknown]").serialNumber == nil)
        #expect(DeviceProperties.parse("[ro.serialno]: []\n[ro.boot.serialno]: [XYZ]").serialNumber == "XYZ")
        #expect(DeviceProperties.parse("[ro.product.model]: [Pixel 8]").serialNumber == nil)
    }

    @Test func detectsEmulatorProperties() {
        #expect(Self.emulatorProps.isEmulator)
        #expect(!Self.phoneProps.isEmulator)
        #expect(DeviceProperties.parse("[ro.kernel.qemu]: [1]").isEmulator)
        #expect(!DeviceProperties.parse("[ro.kernel.qemu]: [0]").isEmulator)
    }

    // MARK: Identity

    @Test func emulatorIdentityIsAVDName() throws {
        let first = try descriptor(Self.emulatorLine)
        let second = try descriptor("emulator-5556 device")
        let a = DeviceIdentity(descriptor: first, properties: Self.emulatorProps)
        let b = DeviceIdentity(descriptor: second, properties: Self.emulatorProps)
        #expect(a == DeviceIdentity(kind: .avd, value: "Medium_Phone_API_37.0"))
        #expect(a == b)
        #expect(a.description == "avd:Medium_Phone_API_37.0")
        #expect(a.isStable)
    }

    @Test func emulatorIgnoresSharedSerialNumber() throws {
        let emulator = try descriptor(Self.emulatorLine)
        let a = DeviceIdentity(descriptor: emulator, properties: Self.emulatorProps)
        let b = DeviceIdentity(descriptor: emulator, properties: Self.otherEmulatorProps)
        #expect(a != b)
    }

    @Test func phoneIdentityIsSerialNumberAcrossTransports() throws {
        let usb = DeviceIdentity(descriptor: try descriptor(Self.usbLine), properties: Self.phoneProps)
        let wifi = DeviceIdentity(descriptor: try descriptor(Self.wifiLine), properties: Self.phoneProps)
        let mdns = DeviceIdentity(descriptor: try descriptor(Self.mdnsLine), properties: nil)
        #expect(usb == Self.phone)
        #expect(wifi == Self.phone)
        #expect(mdns == Self.phone)
        #expect(usb.isStable && wifi.isStable && mdns.isStable)
        #expect(usb.description == "serial:35121FDJH000R8")
    }

    @Test func fallsBackToTransportSerial() throws {
        let usb = DeviceIdentity(descriptor: try descriptor(Self.usbLine), properties: nil)
        #expect(usb == DeviceIdentity(kind: .transport, value: "35121FDJH000R8"))
        #expect(!usb.isStable)

        let partial = DeviceProperties.parse("[ro.kernel.qemu]: [1]")
        let emulator = DeviceIdentity(descriptor: try descriptor(Self.emulatorLine), properties: partial)
        #expect(emulator == DeviceIdentity(kind: .transport, value: "emulator-5554"))
        #expect(!emulator.isStable)
    }

    // MARK: Matching

    @Test func twoInstancesOfOneAVDStayApart() {
        let resolved = DeviceMatching.resolveConflicts([
            transport("emulator-5554", .emulator, Self.avd),
            transport("emulator-5556", .emulator, Self.avd),
        ])
        #expect(resolved.map(\.identity) == [
            DeviceIdentity(kind: .transport, value: "emulator-5554"),
            DeviceIdentity(kind: .transport, value: "emulator-5556"),
        ])
    }

    @Test func conflictsOnlyAmongOnlineTransports() {
        let input = [
            transport("emulator-5554", .emulator, Self.avd, online: false),
            transport("emulator-5556", .emulator, Self.avd),
        ]
        #expect(DeviceMatching.resolveConflicts(input) == input)
    }

    @Test func usbAndWifiOfOnePhoneShareIdentity() {
        let input = [
            transport("35121FDJH000R8", .usb, Self.phone),
            transport("192.168.1.50:41001", .wifi, Self.phone),
        ]
        #expect(DeviceMatching.resolveConflicts(input) == input)
    }

    @Test func placeholderSerialOnTwoUSBPhonesStaysApart() {
        let placeholder = DeviceIdentity(kind: .serialNumber, value: "0123456789ABCDEF")
        let resolved = DeviceMatching.resolveConflicts([
            transport("0123456789ABCDEF", .usb, placeholder),
            transport("0123456789ABCDEF-2", .usb, placeholder),
        ])
        #expect(resolved.allSatisfy { !($0.identity?.isStable ?? true) })
        #expect(resolved[0].identity != resolved[1].identity)
    }

    @Test func resolveConflictsKeepsOrder() {
        let input = [
            transport("b", .emulator, Self.avd),
            transport("a", .usb, nil),
            transport("c", .emulator, Self.avd),
            transport("d", .wifi, Self.phone, online: false),
        ]
        #expect(DeviceMatching.resolveConflicts(input).map(\.serial) == ["b", "a", "c", "d"])
    }

    @Test func prefersUSBOverWifi() {
        let target = DeviceMatching.preferredTransport(for: Self.phone, current: "192.168.1.50:41001", in: [
            transport("192.168.1.50:41001", .wifi, Self.phone),
            transport("35121FDJH000R8", .usb, Self.phone),
        ])
        #expect(target?.serial == "35121FDJH000R8")
    }

    @Test func movesToWifiWhenUSBGoesAway() {
        let wifi = transport("192.168.1.50:41001", .wifi, Self.phone)
        let offline = DeviceMatching.preferredTransport(for: Self.phone, current: "35121FDJH000R8", in: [
            transport("35121FDJH000R8", .usb, Self.phone, online: false),
            wifi,
        ])
        #expect(offline?.serial == "192.168.1.50:41001")
        let absent = DeviceMatching.preferredTransport(for: Self.phone, current: "35121FDJH000R8", in: [wifi])
        #expect(absent?.serial == "192.168.1.50:41001")
    }

    @Test func reattachesWifiOnNewPort() {
        let target = DeviceMatching.preferredTransport(for: Self.phone, current: "192.168.1.50:41001", in: [
            transport("192.168.1.50:41002", .wifi, Self.phone),
        ])
        #expect(target?.serial == "192.168.1.50:41002")
        #expect(target?.transport == .wifi)
    }

    @Test func reattachesAVDOnNewPort() {
        let target = DeviceMatching.preferredTransport(for: Self.avd, current: "emulator-5554", in: [
            transport("emulator-5556", .emulator, Self.avd),
        ])
        #expect(target?.serial == "emulator-5556")
    }

    @Test func ignoresTransportsWhoseIdentityIsUnknown() {
        let target = DeviceMatching.preferredTransport(for: Self.avd, current: "emulator-5554", in: [
            transport("emulator-5556", .emulator, nil),
            transport("emulator-5554", .emulator, nil),
        ])
        #expect(target == nil)
    }

    @Test func doesNotAttachToADifferentDevice() {
        let target = DeviceMatching.preferredTransport(for: Self.avd, current: "emulator-5554", in: [
            transport("emulator-5554", .emulator, DeviceIdentity(kind: .avd, value: "Other")),
        ])
        #expect(target == nil)
    }

    @Test func fallsBackToCurrentSerialWhenIdentityIsUnknowable() {
        let target = DeviceMatching.preferredTransport(for: Self.avd, current: "emulator-5554", in: [
            transport("emulator-5554", .emulator, DeviceIdentity(kind: .transport, value: "emulator-5554")),
        ])
        #expect(target?.serial == "emulator-5554")
    }

    @Test func keepsCurrentTransportAmongEquals() {
        let a = transport("192.168.1.50:41001", .wifi, Self.phone)
        let b = transport("192.168.1.50:41002", .wifi, Self.phone)
        #expect(DeviceMatching.preferredTransport(for: Self.phone, current: b.serial, in: [a, b])?.serial == b.serial)
        #expect(DeviceMatching.preferredTransport(for: Self.phone, current: a.serial, in: [b, a])?.serial == a.serial)
    }

    @Test func groupsTransportsByIdentity() {
        let groups = DeviceMatching.groups([
            transport("35121FDJH000R8", .usb, Self.phone),
            transport("emulator-5554", .emulator, Self.avd),
            transport("192.168.1.50:41001", .wifi, Self.phone),
            transport("unknown123", .usb, nil),
        ])
        #expect(groups.count == 3)
        #expect(groups.map { $0.map(\.serial) } == [
            ["35121FDJH000R8", "192.168.1.50:41001"],
            ["emulator-5554"],
            ["unknown123"],
        ])
    }

    @Test func groupOrdersOnlineFirst() {
        let groups = DeviceMatching.groups([
            transport("35121FDJH000R8", .usb, Self.phone, online: false),
            transport("192.168.1.50:41001", .wifi, Self.phone),
        ])
        #expect(groups.count == 1)
        #expect(groups[0].map(\.serial) == ["192.168.1.50:41001", "35121FDJH000R8"])
    }
}
