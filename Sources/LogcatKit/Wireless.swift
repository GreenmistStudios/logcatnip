import Foundation

// Wireless debugging: finding devices over mDNS, pairing, connecting and telling adb's answers apart.
// adb exits 0 for many failures, so everything here judges success from adb's text, not its exit status.

/// A service adb found over mDNS: a device offering pairing (`_adb-tls-pairing._tcp`) or connections.
public struct MdnsService: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case pairing
        case tlsConnect
        case connect
        case other
    }

    public static let pairingType = "_adb-tls-pairing._tcp"
    public static let tlsConnectType = "_adb-tls-connect._tcp"
    public static let connectType = "_adb._tcp"

    /// `adb-35121FDJH000R8-xyMD0H`, or `studio-AbC123xyz-` for a QR pairing service.
    public var instance: String
    /// Without the trailing dot older adb prints: `_adb-tls-pairing._tcp`.
    public var type: String
    public var ipv4: String?
    public var ipv6: String?
    public var port: Int
    /// The TXT record's `serial`; only `adb mdns track-services` reports it.
    public var serial: String?
    public var productModel: String?
    public var givenName: String?
    public var sdkVersion: String?

    public init(instance: String, type: String, ipv4: String? = nil, ipv6: String? = nil, port: Int,
                serial: String? = nil, productModel: String? = nil, givenName: String? = nil, sdkVersion: String? = nil) {
        self.instance = instance
        self.type = type
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.port = port
        self.serial = serial
        self.productModel = productModel
        self.givenName = givenName
        self.sdkVersion = sdkVersion
    }

    public var kind: Kind {
        switch type {
        case Self.pairingType: .pairing
        case Self.tlsConnectType: .tlsConnect
        case Self.connectType: .connect
        default: .other
        }
    }

    public var id: String { mdnsName }

    /// What adb names the transport when it connects to this service, and what `adb connect` resolves.
    public var mdnsName: String { "\(instance).\(type)" }

    /// `ip:port`, IPv4 preferred and IPv6 bracketed; nil when adb reported no address.
    public var address: String? {
        if let ipv4, !ipv4.isEmpty { return "\(ipv4):\(port)" }
        if let ipv6, !ipv6.isEmpty { return "[\(ipv6)]:\(port)" }
        return nil
    }

    /// The TXT serial, else the serial inside adbd's `adb-<serial>-<id>` instance name.
    public var deviceSerial: String? {
        if let serial, !serial.isEmpty { return serial }
        return Self.deviceSerial(fromInstance: instance)
    }

    /// Android Studio names the pairing service behind its QR code `studio-...`.
    public var isQRCodePairing: Bool {
        kind == .pairing && instance.hasPrefix(QRPairingCode.serviceNamePrefix)
    }

    /// adb itself skips emulator services, and so do we.
    public var isEmulator: Bool { instance.hasPrefix("adb-EMULATOR") }

    public var displayName: String {
        for candidate in [givenName, productModel, deviceSerial] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return instance
    }

    /// The hardware serial inside an instance name `adb-<serial>-<instance id>`. The serial itself may
    /// contain dashes, so the instance id is only the part after the last one.
    public static func deviceSerial(fromInstance instance: String) -> String? {
        let prefix = "adb-"
        guard instance.hasPrefix(prefix) else { return nil }
        let middle = instance.dropFirst(prefix.count)
        guard let dash = middle.lastIndex(of: "-"), dash != middle.startIndex else { return nil }
        return String(middle[..<dash])
    }

    /// `adb mdns services`: `instance<TAB>type<TAB>ip:port` lines after a header. Older adb ends the type
    /// with a dot. Lines that don't fit (the header, `* daemon started successfully`) are skipped.
    public static func parseList(_ text: String) -> [MdnsService] {
        var services: [MdnsService] = []
        for line in text.split(separator: "\n") {
            let pieces = line.split(separator: "\t", omittingEmptySubsequences: true)
            guard pieces.count >= 3 else { continue }
            var type = String(pieces[1])
            if type.hasSuffix(".") { type.removeLast() }
            guard type.hasPrefix("_") else { continue }
            let address = pieces[2].trimmingCharacters(in: .whitespaces)
            guard let colon = address.lastIndex(of: ":"),
                  let port = Int(address[address.index(after: colon)...]), (1...65535).contains(port)
            else { continue }
            let host = address[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            guard !host.isEmpty else { continue }
            var service = MdnsService(instance: String(pieces[0]), type: type, port: port)
            if host.contains(":") {
                service.ipv6 = host
            } else {
                service.ipv4 = host
            }
            services.append(service)
        }
        return services
    }
}

/// Decodes `adb mdns track-services --proto-text`: a stream of full snapshots, each starting at a
/// `Services:` line followed by `tls { service { ... } }` and `pair { service { ... } }` blocks.
public struct MdnsTrackDecoder: Sendable {
    private struct Builder {
        var instance: String?
        var type: String?
        var ipv4: String?
        var ipv6: String?
        var port: Int?
        var serial: String?
        var productModel: String?
        var givenName: String?
        var sdkVersion: String?

        mutating func set(key: String, value: String) {
            switch key {
            case "instance": instance = value
            case "service": type = value
            case "ipv4": ipv4 = ipv4 ?? value
            case "ipv6": ipv6 = ipv6 ?? value
            case "port": port = Int(value)
            case "serial": serial = value
            case "product_model": productModel = value
            case "given_name": givenName = value
            case "build_version_sdk_full": sdkVersion = value
            default: break
            }
        }

        var service: MdnsService? {
            guard let instance, let type, let port else { return nil }
            return MdnsService(instance: instance, type: type, ipv4: ipv4, ipv6: ipv6, port: port,
                               serial: serial, productModel: productModel, givenName: givenName, sdkVersion: sdkVersion)
        }
    }

    private var buffer: [UInt8] = []
    private var current: [MdnsService] = []
    private var builder: Builder?
    private var depth = 0
    private var inSnapshot = false
    private var dirty = false

    public init() {}

    /// Returns each snapshot that completed. adb writes a whole snapshot at once, so one is returned as soon
    /// as its braces balance instead of waiting for the next `Services:` header. A chunk that ends between
    /// two top-level blocks therefore yields a shorter list first, then the full one.
    public mutating func feed(_ data: Data) -> [[MdnsService]] {
        buffer.append(contentsOf: data)
        var snapshots: [[MdnsService]] = []
        if let lastNewline = buffer.lastIndex(of: 0x0A) {
            let complete = buffer[..<lastNewline]
            let lines = complete.split(separator: 0x0A, omittingEmptySubsequences: false)
            for line in lines {
                handle(line: String(decoding: line, as: UTF8.self), snapshots: &snapshots)
            }
            buffer.removeSubrange(...lastNewline)
        }
        if inSnapshot, depth == 0, buffer.isEmpty, dirty {
            snapshots.append(current)
            dirty = false
        }
        return snapshots
    }

    private mutating func handle(line raw: String, snapshots: inout [[MdnsService]]) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return }
        if line == "Services:" {
            if inSnapshot, dirty { snapshots.append(current) }
            current = []
            builder = nil
            depth = 0
            inSnapshot = true
            dirty = true
            return
        }
        guard inSnapshot else { return }
        if line.hasSuffix("{") {
            depth += 1
            let name = line.dropLast().trimmingCharacters(in: .whitespaces)
            if name == "service", depth == 2 { builder = Builder() }
        } else if line == "}" {
            if depth == 2, let finished = builder?.service {
                current.append(finished)
                dirty = true
            }
            if depth == 2 { builder = nil }
            depth = max(0, depth - 1)
        } else if builder != nil, let colon = line.firstIndex(of: ":") {
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            builder?.set(key: key, value: Self.unquote(value))
        }
    }

    /// Quoted values use protobuf text escapes (`\n`, `\"`, octal `\303`, hex `\xC3`); unquoted ones are
    /// numbers and enums.
    static func unquote(_ value: String) -> String {
        guard value.hasPrefix("\"") else { return value }
        let bytes = Array(value.utf8.dropFirst())
        var output: [UInt8] = []
        var index = 0
        func isOctal(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x37 }
        func hexValue(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: byte - 0x30
            case 0x41...0x46: byte - 0x41 + 10
            case 0x61...0x66: byte - 0x61 + 10
            default: nil
            }
        }
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 0x22 { break }
            guard byte == 0x5C, index < bytes.count else {
                output.append(byte)
                continue
            }
            let escaped = bytes[index]
            index += 1
            switch escaped {
            case UInt8(ascii: "n"): output.append(0x0A)
            case UInt8(ascii: "t"): output.append(0x09)
            case UInt8(ascii: "r"): output.append(0x0D)
            case UInt8(ascii: "x"):
                var number: UInt8 = 0
                var digits = 0
                while digits < 2, index < bytes.count, let digit = hexValue(bytes[index]) {
                    number = number &* 16 &+ digit
                    index += 1
                    digits += 1
                }
                output.append(number)
            case _ where isOctal(escaped):
                var number = UInt16(escaped - 0x30)
                var digits = 1
                while digits < 3, index < bytes.count, isOctal(bytes[index]) {
                    number = number * 8 + UInt16(bytes[index] - 0x30)
                    index += 1
                    digits += 1
                }
                output.append(UInt8(truncatingIfNeeded: number))
            default: output.append(escaped)
            }
        }
        return String(decoding: output, as: UTF8.self)
    }
}

/// Android Studio's QR pairing payload, `WIFI:T:ADB;S:<service>;P:<password>;;`.
///
/// The alphabets are Android Studio's, taken from `WiFiPairingServiceImpl`. The password alphabet has no
/// `;` `:` `,` `\` or `"`, so nothing needs the WIFI QR escaping, and `:` would break adb's pairing query.
public struct QRPairingCode: Sendable, Hashable {
    public static let serviceNamePrefix = "studio-"
    public static let nameCharacters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"
    public static let passwordCharacters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()-+*/<>{}"

    /// The pairing service instance the device will advertise after scanning, `studio-` plus ten characters.
    public var serviceName: String
    public var password: String

    public init(serviceName: String, password: String) {
        self.serviceName = serviceName
        self.password = password
    }

    public var payload: String { "WIFI:T:ADB;S:\(serviceName);P:\(password);;" }

    public static func random<G: RandomNumberGenerator>(using generator: inout G) -> QRPairingCode {
        let name = Array(nameCharacters)
        let password = Array(passwordCharacters)
        let suffix = String((0..<10).map { _ in name.randomElement(using: &generator)! })
        let secret = String((0..<12).map { _ in password.randomElement(using: &generator)! })
        return QRPairingCode(serviceName: serviceNamePrefix + suffix, password: secret)
    }

    public static func random() -> QRPairingCode {
        var generator = SystemRandomNumberGenerator()
        return random(using: &generator)
    }
}

/// A `host:port` typed for `adb connect` or `adb pair`.
public struct WirelessAddress: Sendable, Hashable, CustomStringConvertible {
    /// What `adb connect` assumes when no port is given.
    public static let defaultPort = 5555

    public var host: String
    public var port: Int

    /// Accepts `host`, `host:port`, `[v6]`, `[v6]:port` and a bare IPv6 address. With `defaultPort` nil a
    /// port is required, as for pairing, where the port is random and shown on the device.
    public init?(_ text: String, defaultPort: Int? = WirelessAddress.defaultPort) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }

        let host: String
        var portText: Substring?
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":") else { return nil }
                portText = rest.dropFirst()
            }
        } else {
            let colons = trimmed.filter { $0 == ":" }.count
            if colons == 1, let colon = trimmed.firstIndex(of: ":") {
                host = String(trimmed[..<colon])
                portText = trimmed[trimmed.index(after: colon)...]
            } else {
                host = trimmed
            }
        }
        guard !host.isEmpty else { return nil }

        let port: Int
        if let portText {
            guard !portText.isEmpty, portText.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(portText), (1...65535).contains(value)
            else { return nil }
            port = value
        } else if let defaultPort {
            port = defaultPort
        } else {
            return nil
        }
        self.host = host
        self.port = port
    }

    public var description: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

public enum PairingCode {
    /// Six digits. Spaces inside are dropped, because the device shows the code as "123 456".
    public static func normalized(_ text: String) -> String? {
        let digits = text.filter { !$0.isWhitespace }
        guard digits.count == 6, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return digits
    }
}

/// `adb server-status`: text-proto `key: value` lines.
public struct ADBServerStatus: Sendable, Hashable {
    public var values: [String: String]

    public init(values: [String: String] = [:]) {
        self.values = values
    }

    public static func parse(_ text: String) -> ADBServerStatus {
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { values[key] = value }
        }
        return ADBServerStatus(values: values)
    }

    public var mdnsEnabled: Bool? {
        switch values["mdns_enabled"] {
        case "true": true
        case "false": false
        default: nil
        }
    }

    public var version: String? { values["version"] }
}

/// Whether this adb can discover devices over mDNS, for explaining an empty list instead of showing one.
public enum MdnsAvailability: String, Sendable, Hashable {
    case available
    case disabled
    case unsupported
    case unknown

    /// `serverStatus` is `adb server-status` output, nil if it failed or this adb has no such command;
    /// `mdnsCheck` is `adb mdns check` stdout plus stderr, nil if it could not run.
    public static func evaluate(serverStatus: String?, mdnsCheck: String?) -> MdnsAvailability {
        let status = serverStatus.map(ADBServerStatus.parse)
        if status?.mdnsEnabled == false { return .disabled }
        if let mdnsCheck {
            if mdnsCheck.contains("mdns discovery disabled") { return .disabled }
            if mdnsCheck.contains("mdns daemon version") { return .available }
        }
        if status?.mdnsEnabled == true { return .available }
        if let mdnsCheck, mdnsCheck.lowercased().contains("unknown") { return .unsupported }
        return .unknown
    }
}

/// Turns adb's output into a result. adb exits 0 for many failures (a refused `adb connect`, a wrong pairing
/// code), so success is judged by the text, and a failure carries adb's own words.
public enum WirelessOutput {
    private static let pairPrompt = "Enter pairing code:"

    /// Success is "Successfully paired to"; returns the `[guid=...]` value (adb's `adb-<serial>-<id>`).
    public static func pairing(_ result: CommandResult, timeoutDescription: String) -> Result<String?, ADBError> {
        let output = result.output
        guard output.contains("Successfully paired to") else {
            return .failure(failure(result, timeoutDescription: timeoutDescription))
        }
        guard let start = output.range(of: "[guid="), let end = output[start.upperBound...].firstIndex(of: "]") else {
            return .success(nil)
        }
        let guid = String(output[start.upperBound..<end])
        return .success(guid.isEmpty ? nil : guid)
    }

    /// Success is "connected to X" or "already connected to X"; returns X, the transport serial.
    public static func connection(_ result: CommandResult, timeoutDescription: String) -> Result<String, ADBError> {
        if result.status == 0 {
            for line in result.output.split(separator: "\n") {
                let text = line.trimmingCharacters(in: .whitespaces)
                for prefix in ["already connected to ", "connected to "] where text.hasPrefix(prefix) {
                    return .success(String(text.dropFirst(prefix.count)))
                }
            }
        }
        return .failure(failure(result, timeoutDescription: timeoutDescription))
    }

    public static func disconnection(_ result: CommandResult, timeoutDescription: String = "15 seconds") -> Result<Void, ADBError> {
        if result.status == 0, result.output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("disconnected") {
            return .success(())
        }
        return .failure(failure(result, timeoutDescription: timeoutDescription))
    }

    /// adb's own words: trimmed stdout without the pairing prompt, and trimmed stderr, joined by a newline.
    static func adbMessage(_ result: CommandResult) -> String {
        var out = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.hasPrefix(pairPrompt) { out = String(out.dropFirst(pairPrompt.count)) }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return [out, err].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Only our own safety timeout earns a sentence of ours; otherwise the user reads what adb said.
    private static func failure(_ result: CommandResult, timeoutDescription: String) -> ADBError {
        let message = adbMessage(result)
        if result.timedOut {
            let head = "adb didn't answer within \(timeoutDescription)."
            return ADBError(message.isEmpty ? head : head + "\n" + message)
        }
        return ADBError(message.isEmpty ? "adb exited with status \(result.status)." : message)
    }
}

public enum WirelessMatching {
    /// Connect services whose device is not online over any transport, for the Discovered list. Emulators
    /// are skipped, as adb does. A service is hidden when an online transport is named after it, uses its
    /// address, or belongs to the same device (the serial in its name matches the transport's identity), so a
    /// phone that is on USB does not also show up as a Wi-Fi candidate.
    public static func unconnectedServices(_ services: [MdnsService], transports: [TransportState]) -> [MdnsService] {
        let online = transports.filter(\.isOnline)
        let serials = Set(online.map(\.serial))
        let identities = Set(online.compactMap(\.identity).filter { $0.kind == .serialNumber }.map(\.value))
        var seen = Set<String>()
        return services
            .filter { service in
                guard service.kind == .tlsConnect || service.kind == .connect, !service.isEmulator,
                      seen.insert(service.mdnsName).inserted
                else { return false }
                if serials.contains(service.mdnsName) { return false }
                if let address = service.address, serials.contains(address) { return false }
                if let serial = service.deviceSerial, identities.contains(serial) { return false }
                return true
            }
            .sorted { lhs, rhs in
                let order = lhs.displayName.localizedStandardCompare(rhs.displayName)
                return order == .orderedSame ? lhs.mdnsName < rhs.mdnsName : order == .orderedAscending
            }
    }

    /// The online transport, with a known identity, of the device adb just paired. `guid` is the
    /// `adb-<serial>-<id>` adb reports; adb auto-connects the device under `<guid>._adb-tls-connect._tcp`.
    public static func pairedTransport(guid: String, in transports: [TransportState]) -> TransportState? {
        let serial = MdnsService.deviceSerial(fromInstance: guid).map { DeviceIdentity(kind: .serialNumber, value: $0) }
        return transports.first { state in
            guard state.isOnline, let identity = state.identity else { return false }
            return state.serial.hasPrefix(guid + ".") || identity == serial
        }
    }

    /// The online transport, with a known identity, that `adb connect` made for a Discovered service. adb
    /// reports the transport serial it used, but a service can also end up as `ip:port`, or as its mDNS
    /// name when adb's own auto-connect got there first, so every name this device could have is accepted.
    public static func connectedTransport(for service: MdnsService, reportedSerial: String?,
                                          in transports: [TransportState]) -> TransportState? {
        let identity = service.deviceSerial.map { DeviceIdentity(kind: .serialNumber, value: $0) }
        return transports.first { state in
            guard state.isOnline, let candidate = state.identity else { return false }
            return state.serial == reportedSerial || state.serial == service.mdnsName
                || (service.address != nil && state.serial == service.address) || candidate == identity
        }
    }
}

public enum MdnsEvent: Sendable {
    case services([MdnsService])
    case failed(String)
}

extension ADB {
    /// `adb host-features`: what the server supports, such as `track_mdns`.
    public func hostFeatures() async throws -> Set<String> {
        let result = try await run(["host-features"], timeout: .seconds(10))
        guard result.status == 0 else { throw ADBError(WirelessOutput.adbMessage(result)) }
        return Set(result.output.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init))
    }

    /// `adb mdns services`, one snapshot.
    public func mdnsServices() async throws -> [MdnsService] {
        let result = try await run(["mdns", "services"], timeout: .seconds(10))
        guard result.status == 0 else { throw ADBError(WirelessOutput.adbMessage(result)) }
        return MdnsService.parseList(result.output)
    }

    /// nil when the command fails, which is what an adb that predates `server-status` does.
    public func serverStatus() async -> ADBServerStatus? {
        guard let result = try? await run(["server-status"], timeout: .seconds(10)), result.status == 0 else { return nil }
        return ADBServerStatus.parse(result.output)
    }

    /// Combines `adb server-status` and `adb mdns check` into the answer the pairing sheet explains.
    public func mdnsAvailability() async -> MdnsAvailability {
        async let status = try? run(["server-status"], timeout: .seconds(10))
        async let check = try? run(["mdns", "check"], timeout: .seconds(10))
        let statusText = await status.flatMap { $0.status == 0 ? $0.output : nil }
        let checkText = await check.map { $0.output + $0.stderr }
        return MdnsAvailability.evaluate(serverStatus: statusText, mdnsCheck: checkText)
    }

    /// `adb pair <address> <code>`; returns adb's guid for the device. The timeout is ours and longer than
    /// adb's own (10 s), so the user normally reads adb's message instead of ours.
    public func pair(address: String, code: String, timeout: Duration = .seconds(90)) async throws -> String? {
        let result = try await run(["pair", address, code], timeout: timeout)
        return try WirelessOutput.pairing(result, timeoutDescription: Self.describe(timeout)).get()
    }

    /// `adb connect <target>`, where target is `host:port` or an mDNS name. Returns the transport serial.
    public func connect(_ target: String, timeout: Duration = .seconds(90)) async throws -> String {
        let result = try await run(["connect", target], timeout: timeout)
        return try WirelessOutput.connection(result, timeoutDescription: Self.describe(timeout)).get()
    }

    /// `adb disconnect <serial>`. adb only finds transports named `host:port`.
    public func disconnect(serial: String) async throws {
        let result = try await run(["disconnect", serial], timeout: .seconds(15))
        try WirelessOutput.disconnection(result).get()
    }

    /// Follows mDNS services with `mdns track-services --proto-text` when the server has `track_mdns`
    /// (it reports serial, model and name too), else polls `mdns services`. Mirrors Android Studio. If the
    /// tracker exits, yields an empty list, then adb's message, and starts again after `restartDelay`.
    /// Cancelling the consuming task stops it.
    public func trackMdnsServices(pollInterval: Duration = .seconds(3), restartDelay: Duration = .seconds(5)) -> AsyncStream<MdnsEvent> {
        AsyncStream { continuation in
            let task = Task {
                var lastFailure: String?
                var hadServices = false
                while !Task.isCancelled {
                    let features = (try? await hostFeatures()) ?? []
                    if features.contains("track_mdns") {
                        let exited = await trackOnce(continuation)
                        if Task.isCancelled { break }
                        continuation.yield(.services([]))
                        if let exited, !exited.isEmpty, exited != lastFailure {
                            lastFailure = exited
                            continuation.yield(.failed(exited))
                        }
                        try? await Task.sleep(for: restartDelay)
                    } else {
                        // Look at the features again now and then: the server may have been restarted.
                        for _ in 0..<20 where !Task.isCancelled {
                            do {
                                let services = try await mdnsServices()
                                hadServices = !services.isEmpty
                                continuation.yield(.services(services))
                                lastFailure = nil
                            } catch {
                                let message = "\(error)"
                                if hadServices {
                                    hadServices = false
                                    continuation.yield(.services([]))
                                }
                                if message != lastFailure {
                                    lastFailure = message
                                    continuation.yield(.failed(message))
                                }
                            }
                            try? await Task.sleep(for: pollInterval)
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Runs one `track-services` process until it exits; returns its stderr when it failed.
    private func trackOnce(_ continuation: AsyncStream<MdnsEvent>.Continuation) async -> String? {
        let process = StreamingProcess(executable: executable, arguments: ["mdns", "track-services", "--proto-text"],
                                       stopsWithParent: true)
        let decoder = MdnsDecoderBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
                do {
                    try process.start(
                        onData: { data in
                            for snapshot in decoder.feed(data) {
                                continuation.yield(.services(snapshot))
                            }
                        },
                        onExit: { status, stderr in
                            done.resume(returning: status == 0 ? nil : stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                    )
                } catch {
                    done.resume(returning: "\(error)")
                }
            }
        } onCancel: {
            process.terminate()
        }
    }

    private static func describe(_ duration: Duration) -> String {
        let seconds = duration.components.seconds
        if seconds >= 1 { return seconds == 1 ? "1 second" : "\(seconds) seconds" }
        return "\(seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000) ms"
    }
}

/// Guards the decoder, which is fed from a process's read queue. The lock orders `feed` calls.
private final class MdnsDecoderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var decoder = MdnsTrackDecoder()
    func feed(_ data: Data) -> [[MdnsService]] { lock.withLock { decoder.feed(data) } }
}
