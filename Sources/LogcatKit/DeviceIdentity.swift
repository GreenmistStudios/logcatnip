import Foundation

/// How adb reaches a device. Sessions prefer USB: it is faster and survives Wi-Fi changes.
public enum DeviceTransport: String, Sendable, Hashable, CaseIterable {
    case usb
    case wifi
    case emulator

    /// First match wins. An emulator reached with `adb connect localhost:5555` has a network serial but
    /// still reports `qemu` properties, so it is classified by those before the serial is judged a Wi-Fi one.
    public init(descriptor: DeviceDescriptor, properties: DeviceProperties?) {
        if descriptor.isEmulator || properties?.isEmulator == true {
            self = .emulator
        } else if descriptor.isNetworkTransport {
            self = .wifi
        } else {
            self = .usb
        }
    }

    /// Used in session markers, for example "Device reconnected (Wi-Fi)".
    public var label: String {
        switch self {
        case .usb: "USB"
        case .wifi: "Wi-Fi"
        case .emulator: "emulator"
        }
    }

    /// Lower is preferred when a device is reachable several ways.
    public var rank: Int {
        switch self {
        case .usb: 0
        case .emulator: 1
        case .wifi: 2
        }
    }
}

extension DeviceDescriptor {
    private static let mdnsSuffixes = ["._adb-tls-connect._tcp", "._adb._tcp"]

    /// `host:port` from `adb connect`, or an mDNS transport such as `adb-<serial>-<id>._adb-tls-connect._tcp`.
    public var isNetworkTransport: Bool {
        if Self.mdnsSuffixes.contains(where: serial.hasSuffix) { return true }
        guard let colon = serial.lastIndex(of: ":"), colon != serial.startIndex else { return false }
        let port = serial[serial.index(after: colon)...]
        return (1...5).contains(port.count) && port.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The hardware serial inside an mDNS transport name. adb names the transport
    /// `adb-<serial>-<instance id>._adb-tls-connect._tcp`; the serial itself may contain dashes, so the
    /// instance id is only the part after the last one.
    public var mdnsSerial: String? {
        let prefix = "adb-"
        let suffix = "._adb-tls-connect._tcp"
        guard serial.hasPrefix(prefix), serial.hasSuffix(suffix), serial.count > prefix.count + suffix.count else { return nil }
        let middle = serial.dropFirst(prefix.count).dropLast(suffix.count)
        guard let dash = middle.lastIndex(of: "-"), dash != middle.startIndex else { return nil }
        return String(middle[..<dash])
    }
}

extension DeviceProperties {
    /// `ro.serialno`, else `ro.boot.serialno`. Empty and "unknown" mean the device does not expose one.
    public var serialNumber: String? {
        for key in ["ro.serialno", "ro.boot.serialno"] {
            if let value = values[key], !value.isEmpty, value.lowercased() != "unknown" { return value }
        }
        return nil
    }

    public var isEmulator: Bool {
        values["ro.kernel.qemu"] == "1" || values["ro.boot.qemu"] == "1" || !(avdName ?? "").isEmpty
    }
}

/// What a device is, independent of how it is connected right now. Sessions follow this rather than the
/// transport serial, which changes with Wi-Fi ports, emulator ports, and USB versus Wi-Fi.
public struct DeviceIdentity: Sendable, Hashable, CustomStringConvertible {
    public enum Kind: String, Sendable, Hashable {
        case avd
        case serialNumber = "serial"
        /// The adb transport serial: the last resort, and not stable across reconnects.
        case transport
    }

    public var kind: Kind
    public var value: String

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }

    /// Emulators are identified by AVD name only. Their `ro.serialno` encodes the emulator build, so every
    /// AVD run by one build reports the same value and would be merged into one device.
    public init(descriptor: DeviceDescriptor, properties: DeviceProperties?) {
        if DeviceTransport(descriptor: descriptor, properties: properties) == .emulator {
            if let avd = properties?.avdName, !avd.isEmpty {
                self.init(kind: .avd, value: avd)
            } else {
                self.init(kind: .transport, value: descriptor.serial)
            }
        } else if let serialNumber = properties?.serialNumber {
            self.init(kind: .serialNumber, value: serialNumber)
        } else if let mdnsSerial = descriptor.mdnsSerial {
            // getprop can fail on a flaky Wi-Fi link; the transport name already carries the serial.
            self.init(kind: .serialNumber, value: mdnsSerial)
        } else {
            self.init(kind: .transport, value: descriptor.serial)
        }
    }

    /// False for the transport-serial fallback, which cannot match a device after it reconnects.
    public var isStable: Bool { kind != .transport }

    public var description: String { "\(kind.rawValue):\(value)" }
}

/// One adb transport, reduced to what matching sessions to devices needs.
public struct TransportState: Sendable, Hashable {
    public var serial: String
    public var transport: DeviceTransport
    /// nil until getprop has been tried for this transport.
    public var identity: DeviceIdentity?
    public var isOnline: Bool

    public init(serial: String, transport: DeviceTransport, identity: DeviceIdentity?, isOnline: Bool) {
        self.serial = serial
        self.transport = transport
        self.identity = identity
        self.isOnline = isOnline
    }
}

/// Pure matching rules between sessions and transports, kept out of the app model so they can be tested.
public enum DeviceMatching {
    private struct ConflictKey: Hashable {
        var identity: DeviceIdentity
        var transport: DeviceTransport
    }

    /// Returns `transports` in the same order and count. Two online transports of one kind that share a
    /// stable identity are two devices (two instances of one AVD, or two phones reporting a placeholder
    /// serial number), so both fall back to their transport serial. A USB and a Wi-Fi transport that share
    /// an identity are one phone and keep it.
    public static func resolveConflicts(_ transports: [TransportState]) -> [TransportState] {
        func conflictKey(_ state: TransportState) -> ConflictKey? {
            guard state.isOnline, let identity = state.identity, identity.isStable else { return nil }
            return ConflictKey(identity: identity, transport: state.transport)
        }
        var counts: [ConflictKey: Int] = [:]
        for state in transports {
            if let key = conflictKey(state) { counts[key, default: 0] += 1 }
        }
        return transports.map { state in
            guard let key = conflictKey(state), counts[key, default: 0] > 1 else { return state }
            var demoted = state
            demoted.identity = DeviceIdentity(kind: .transport, value: state.serial)
            return demoted
        }
    }

    /// The online transport a session for `identity`, currently on `current`, should stream from. Matches
    /// transports with the same identity, plus `current` itself when its identity is only the transport
    /// fallback (getprop failed, or a conflict demoted it): then nothing better is knowable and the session
    /// stays put. Transports whose identity is still unknown never match, so a reused serial cannot take
    /// over another device's session before getprop answers. Best transport first, ties keep `current`.
    public static func preferredTransport(for identity: DeviceIdentity, current: String,
                                          in transports: [TransportState]) -> TransportState? {
        transports
            .filter { state in
                guard state.isOnline, let candidate = state.identity else { return false }
                return candidate == identity || (state.serial == current && !candidate.isStable)
            }
            .min { lhs, rhs in
                if lhs.transport.rank != rhs.transport.rank { return lhs.transport.rank < rhs.transport.rank }
                if (lhs.serial == current) != (rhs.serial == current) { return lhs.serial == current }
                return lhs.serial < rhs.serial
            }
    }

    /// Transports grouped by identity, one group per physical device; a transport with no identity yet is
    /// its own group. Groups keep first-appearance order. Inside a group the transport sessions would
    /// stream from comes first: online, then by rank, then by serial.
    public static func groups(_ transports: [TransportState]) -> [[TransportState]] {
        var groups: [[TransportState]] = []
        var indexByIdentity: [DeviceIdentity: Int] = [:]
        for state in transports {
            guard let identity = state.identity else {
                groups.append([state])
                continue
            }
            if let index = indexByIdentity[identity] {
                groups[index].append(state)
            } else {
                indexByIdentity[identity] = groups.count
                groups.append([state])
            }
        }
        return groups.map { group in
            group.sorted { lhs, rhs in
                if lhs.isOnline != rhs.isOnline { return lhs.isOnline }
                if lhs.transport.rank != rhs.transport.rank { return lhs.transport.rank < rhs.transport.rank }
                return lhs.serial < rhs.serial
            }
        }
    }
}
