import Foundation

/// A device as reported by `adb track-devices -l` / `adb devices -l`.
public struct DeviceDescriptor: Sendable, Hashable, Identifiable {
    public enum State: Sendable, Hashable {
        case device
        case offline
        case unauthorized
        case authorizing
        case connecting
        case recovery
        case sideload
        case bootloader
        case other(String)

        init(_ text: String) {
            switch text {
            case "device": self = .device
            case "offline": self = .offline
            case "unauthorized": self = .unauthorized
            case "authorizing": self = .authorizing
            case "connecting": self = .connecting
            case "recovery": self = .recovery
            case "sideload": self = .sideload
            case "bootloader": self = .bootloader
            default: self = .other(text)
            }
        }

        public var description: String {
            switch self {
            case .device: "online"
            case .offline: "offline"
            case .unauthorized: "unauthorized"
            case .authorizing: "authorizing"
            case .connecting: "connecting"
            case .recovery: "recovery"
            case .sideload: "sideload"
            case .bootloader: "bootloader"
            case let .other(text): text
            }
        }
    }

    public var serial: String
    public var state: State
    /// `usb`, `product`, `model`, `device`, `transport_id`, ...
    public var attributes: [String: String]

    public var id: String { serial }
    public var isOnline: Bool { state == .device }
    public var isEmulator: Bool { serial.hasPrefix("emulator-") }
    public var model: String? { attributes["model"]?.replacingOccurrences(of: "_", with: " ") }

    public init(serial: String, state: State, attributes: [String: String] = [:]) {
        self.serial = serial
        self.state = state
        self.attributes = attributes
    }

    private static let knownAttributeKeys: Set<String> = ["usb", "product", "model", "device", "transport_id", "features"]

    /// Parses one line of `adb devices -l` output: `serial  state key:value key:value`. The state can contain
    /// spaces (`no permissions (...)`), so it runs until the first known `key:` attribute.
    public static func parse(line: Substring) -> DeviceDescriptor? {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard tokens.count >= 2 else { return nil }
        let serial = String(tokens[0])
        var stateWords: [Substring] = []
        var attributes: [String: String] = [:]
        for token in tokens.dropFirst() {
            if let colon = token.firstIndex(of: ":"), knownAttributeKeys.contains(String(token[..<colon])) {
                attributes[String(token[..<colon])] = String(token[token.index(after: colon)...])
            } else if attributes.isEmpty {
                stateWords.append(token)
            }
        }
        guard !stateWords.isEmpty else { return nil }
        return DeviceDescriptor(serial: serial, state: State(stateWords.joined(separator: " ")), attributes: attributes)
    }
}

/// Decodes the `adb track-devices` stream: each update is a 4-hex-digit length followed by that many bytes
/// of `adb devices -l` output describing every attached device.
public struct TrackDevicesDecoder: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func feed(_ data: Data) -> [[DeviceDescriptor]] {
        buffer.append(contentsOf: data)
        var snapshots: [[DeviceDescriptor]] = []
        while buffer.count >= 4 {
            guard let length = Int(String(decoding: buffer[0..<4], as: UTF8.self), radix: 16) else {
                // Out of sync; drop everything rather than misreading.
                buffer.removeAll()
                break
            }
            guard buffer.count >= 4 + length else { break }
            let payload = String(decoding: buffer[4..<(4 + length)], as: UTF8.self)
            buffer.removeFirst(4 + length)
            snapshots.append(payload.split(separator: "\n").compactMap { DeviceDescriptor.parse(line: $0) })
        }
        return snapshots
    }
}

/// Properties read with `getprop` for display and for choosing logcat options.
public struct DeviceProperties: Sendable, Hashable {
    public var values: [String: String]

    public init(values: [String: String] = [:]) {
        self.values = values
    }

    public var apiLevel: Int? { values["ro.build.version.sdk"].flatMap(Int.init) }
    public var release: String? { values["ro.build.version.release"] }
    public var manufacturer: String? { values["ro.product.manufacturer"] }
    public var model: String? { values["ro.product.model"] }
    public var avdName: String? {
        values["ro.boot.qemu.avd_name"] ?? values["ro.kernel.qemu.avd_name"]
    }

    /// Parses `getprop` output: `[key]: [value]` per line.
    public static func parse(_ text: String) -> DeviceProperties {
        var values: [String: String] = [:]
        text.enumerateLines { line, _ in
            guard line.hasPrefix("["), let separator = line.range(of: "]: [") else { return }
            let key = line[line.index(after: line.startIndex)..<separator.lowerBound]
            var value = line[separator.upperBound...]
            if value.hasSuffix("]") { value = value.dropLast() }
            values[String(key)] = String(value)
        }
        return DeviceProperties(values: values)
    }
}

/// Parses `ps` output into pid -> process name. Works with `ps -A -o PID,NAME` (API 26+) and the older
/// `USER PID PPID VSIZE RSS WCHAN PC NAME` layout, by locating the PID and NAME columns in the header.
public enum ProcessListParser {
    public static func parse(_ text: String) -> [Int32: String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).makeIterator()
        guard let header = lines.next() else { return [:] }
        let columns = header.split(separator: " ", omittingEmptySubsequences: true).map { $0.uppercased() }
        guard let pidColumn = columns.firstIndex(of: "PID") else { return [:] }
        let nameColumn = columns.firstIndex(of: "NAME") ?? columns.firstIndex(of: "CMD") ?? (columns.count - 1)
        let hasLegacyStateColumn = columns.contains("WCHAN") && columns.contains("PC")

        var result: [Int32: String] = [:]
        while let line = lines.next() {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count > pidColumn, let pid = Int32(fields[pidColumn]) else { continue }
            // Pre-Oreo ps prints an unlabelled state column between PC and NAME.
            let name: String
            if nameColumn == columns.count - 1 {
                let skip = (hasLegacyStateColumn && fields.count > columns.count) ? 1 : 0
                guard nameColumn + skip < fields.count else { continue }
                name = fields[(nameColumn + skip)...].joined(separator: " ")
            } else if nameColumn < fields.count {
                name = String(fields[nameColumn])
            } else {
                continue
            }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !(trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) else { continue }
            result[pid] = trimmed
        }
        return result
    }
}
