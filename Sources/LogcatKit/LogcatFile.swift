import Foundation

/// The device recorded in a `.logcat` file. Android Studio has written two shapes: a `physicalDevice` or
/// `emulatorDevice` wrapper (current) and, until Studio 2024.3, a flat object with `name` and `sdk`.
public struct LogcatFileDevice: Sendable, Equatable {
    public enum Kind: String, Sendable { case physical, emulator }

    public var kind: Kind
    /// The flat format's `name`; the current format derives it (see ``displayName``).
    public var name: String?
    public var serialNumber: String?
    public var isOnline: Bool?
    public var release: String?
    /// `apiLevel.majorVersion`, or the flat format's `sdk`.
    public var apiLevel: Int?
    public var apiMinorLevel: Int?
    public var featureLevel: Int?
    public var manufacturer: String?
    public var model: String?
    public var avdName: String?
    public var avdPath: String?
    /// The flat format's `deviceId` string, or the `identifier` of the current format's object. For debugging only.
    public var deviceId: String?
    /// `HANDHELD`, `WEAR`, ...
    public var type: String?

    public init(
        kind: Kind, name: String? = nil, serialNumber: String? = nil, isOnline: Bool? = nil, release: String? = nil,
        apiLevel: Int? = nil, apiMinorLevel: Int? = nil, featureLevel: Int? = nil, manufacturer: String? = nil,
        model: String? = nil, avdName: String? = nil, avdPath: String? = nil, deviceId: String? = nil, type: String? = nil
    ) {
        self.kind = kind
        self.name = name
        self.serialNumber = serialNumber
        self.isOnline = isOnline
        self.release = release
        self.apiLevel = apiLevel
        self.apiMinorLevel = apiMinorLevel
        self.featureLevel = featureLevel
        self.manufacturer = manufacturer
        self.model = model
        self.avdName = avdName
        self.avdPath = avdPath
        self.deviceId = deviceId
        self.type = type
    }

    /// Android Studio's own name for the device: the AVD name for an emulator, and the manufacturer and model for
    /// a phone unless the model already starts with the manufacturer.
    public var displayName: String? {
        if let name { return name }
        switch kind {
        case .emulator:
            return avdName
        case .physical:
            guard let model else { return nil }
            guard let manufacturer, !model.hasPrefix(manufacturer) else { return model }
            return "\(manufacturer) \(model)"
        }
    }
}

/// The metadata Android Studio writes into a `.logcat` file. Unknown keys are ignored, as Gson ignores them, so
/// fields such as `ignoredTags` can be added later without breaking either app.
public struct LogcatFileMetadata: Sendable, Equatable {
    public var device: LogcatFileDevice?
    public var filter: String
    /// In file order.
    public var projectApplicationIds: [String]
    /// Logcatnip's own addition, for the ignore lists: tags and packages that were hidden when the file was saved.
    /// Android Studio doesn't write these keys and ignores them on read. Empty until the ignore lists exist.
    public var ignoredTags: [String]
    public var ignoredPackages: [String]

    public init(
        device: LogcatFileDevice?, filter: String, projectApplicationIds: [String],
        ignoredTags: [String] = [], ignoredPackages: [String] = []
    ) {
        self.device = device
        self.filter = filter
        self.projectApplicationIds = projectApplicationIds
        self.ignoredTags = ignoredTags
        self.ignoredPackages = ignoredPackages
    }

    /// `package:mine` in a shared file meant the sender's packages, which are not the reader's. This is a port of
    /// Android Studio's `safeGetFilter`: it spells them out unless they are the same as `myPackages`.
    public func filter(forMyPackages myPackages: Set<String>) -> String {
        let mine = "package:mine"
        guard filter.contains(mine) else { return filter }
        var seen = Set<String>()
        let ids = projectApplicationIds.filter { seen.insert($0).inserted }
        if ids.isEmpty { return filter.replacingOccurrences(of: mine, with: "") }
        if Set(ids) == myPackages { return filter }
        if ids.count == 1 { return filter.replacingOccurrences(of: mine, with: "package:\(ids[0])") }
        if filter == mine { return ids.map { "package:\($0)" }.joined(separator: " ") }
        return filter.replacingOccurrences(of: mine, with: "(" + ids.map { "package:\($0)" }.joined(separator: " | ") + ")")
    }
}

/// Android Studio's `.logcat` file: JSON with the device, filter and project packages, and the messages.
public enum LogcatFile {
    public static let fileExtension = "logcat"

    /// Decodes Android Studio's `LogcatFileData`. The "--------- beginning of" placeholders it keeps as messages
    /// (pid 0, no tag, time 0) are dropped. A `pid-N` process placeholder becomes nil, so the table shows its usual
    /// `pid-N` and the pid can still be resolved.
    public static func decode(_ data: Data) throws -> (metadata: LogcatFileMetadata?, entries: [LogEntry]) {
        let file = try JSONDecoder().decode(FileDTO.self, from: data)
        let metadata = file.metadata.map {
            LogcatFileMetadata(
                device: $0.device?.device, filter: $0.filter ?? "", projectApplicationIds: $0.projectApplicationIds ?? [],
                ignoredTags: $0.ignoredTags ?? [], ignoredPackages: $0.ignoredPackages ?? []
            )
        }
        var entries: [LogEntry] = []
        entries.reserveCapacity(file.logcatMessages?.count ?? 0)
        for message in file.logcatMessages ?? [] {
            if let entry = message.entry { entries.append(entry) }
        }
        return (metadata, entries)
    }

    // MARK: Decoding

    private struct FileDTO: Decodable {
        var metadata: MetadataDTO?
        var logcatMessages: [MessageDTO]?
    }

    private struct MetadataDTO: Decodable {
        var device: DeviceDTO?
        var filter: String?
        var projectApplicationIds: [String]?
        var ignoredTags: [String]?
        var ignoredPackages: [String]?
    }

    private struct DeviceDTO: Decodable {
        private enum Key: String, CodingKey { case physicalDevice, emulatorDevice }
        var device: LogcatFileDevice?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            if container.contains(.physicalDevice) {
                device = try container.decode(FieldsDTO.self, forKey: .physicalDevice).device(kind: .physical)
            } else if container.contains(.emulatorDevice) {
                device = try container.decode(FieldsDTO.self, forKey: .emulatorDevice).device(kind: .emulator)
            } else if let flat = try? FieldsDTO(from: decoder),
                      flat.serialNumber != nil || flat.name != nil || flat.deviceId != nil {
                device = flat.device(kind: flat.isEmulator == true ? .emulator : .physical)
            }
        }
    }

    /// Every field is optional and a field of an unexpected type is treated as absent, because Android Studio
    /// has changed the types over the years (`release` was a number in 2022.1, `apiLevel` an object later).
    private struct FieldsDTO: Decodable {
        private enum Key: String, CodingKey {
            case deviceId, name, serialNumber, isOnline, release, apiLevel, sdk, featureLevel, manufacturer, model
            case avdName, avdPath, type, isEmulator
        }
        private struct IdentifierKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
        private struct ApiLevelKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        var deviceId: String?
        var name: String?
        var serialNumber: String?
        var isOnline: Bool?
        var release: String?
        var apiLevel: Int?
        var apiMinorLevel: Int?
        var featureLevel: Int?
        var manufacturer: String?
        var model: String?
        var avdName: String?
        var avdPath: String?
        var type: String?
        var isEmulator: Bool?

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            if let text = try? c.decodeIfPresent(String.self, forKey: .deviceId) {
                deviceId = text
            } else if let object = try? c.nestedContainer(keyedBy: IdentifierKey.self, forKey: .deviceId) {
                deviceId = try? object.decodeIfPresent(String.self, forKey: IdentifierKey(stringValue: "identifier")!)
            }
            name = try? c.decodeIfPresent(String.self, forKey: .name)
            serialNumber = try? c.decodeIfPresent(String.self, forKey: .serialNumber)
            isOnline = try? c.decodeIfPresent(Bool.self, forKey: .isOnline)
            if let text = try? c.decodeIfPresent(String.self, forKey: .release) {
                release = text
            } else if let number = try? c.decodeIfPresent(Int.self, forKey: .release) {
                release = String(number)
            } else if let number = try? c.decodeIfPresent(Double.self, forKey: .release) {
                release = String(number)
            }
            if let level = try? c.decodeIfPresent(Int.self, forKey: .apiLevel) {
                apiLevel = level
            } else if let object = try? c.nestedContainer(keyedBy: ApiLevelKey.self, forKey: .apiLevel) {
                apiLevel = try? object.decodeIfPresent(Int.self, forKey: ApiLevelKey(stringValue: "majorVersion")!)
                apiMinorLevel = try? object.decodeIfPresent(Int.self, forKey: ApiLevelKey(stringValue: "minorVersion")!)
            }
            if apiLevel == nil { apiLevel = try? c.decodeIfPresent(Int.self, forKey: .sdk) }
            featureLevel = try? c.decodeIfPresent(Int.self, forKey: .featureLevel)
            manufacturer = try? c.decodeIfPresent(String.self, forKey: .manufacturer)
            model = try? c.decodeIfPresent(String.self, forKey: .model)
            avdName = try? c.decodeIfPresent(String.self, forKey: .avdName)
            avdPath = try? c.decodeIfPresent(String.self, forKey: .avdPath)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            isEmulator = try? c.decodeIfPresent(Bool.self, forKey: .isEmulator)
        }

        func device(kind: LogcatFileDevice.Kind) -> LogcatFileDevice {
            LogcatFileDevice(
                kind: kind, name: name, serialNumber: serialNumber, isOnline: isOnline, release: release,
                apiLevel: apiLevel, apiMinorLevel: apiMinorLevel, featureLevel: featureLevel,
                manufacturer: manufacturer, model: model, avdName: avdName, avdPath: avdPath, deviceId: deviceId,
                type: type
            )
        }
    }

    private struct MessageDTO: Decodable {
        struct Header: Decodable {
            var logLevel: String?
            var pid: Int?
            var tid: Int?
            var applicationId: String?
            var processName: String?
            var tag: String?
            var timestamp: Timestamp?
        }

        struct Timestamp: Decodable {
            var seconds: Int64?
            var nanos: Int?
        }

        var header: Header?
        var message: String?

        /// Nil for messages that aren't log records.
        var entry: LogEntry? {
            guard let header, let pid = header.pid.flatMap(Int32.init(exactly:)),
                  let tid = header.tid.flatMap(Int32.init(exactly:))
            else { return nil }
            let seconds = header.timestamp?.seconds ?? 0
            let tag = header.tag ?? ""
            if pid == 0, tag.isEmpty, seconds == 0 { return nil }
            let timestamp = Double(seconds) + Double(header.timestamp?.nanos ?? 0) / 1_000_000_000
            return LogEntry(
                timestamp: timestamp, pid: pid, tid: tid, level: LogLevel(name: header.logLevel ?? "") ?? .info,
                tag: tag, message: message ?? "", processName: Self.processName(of: header)
            )
        }

        private static func processName(of header: Header) -> String? {
            if let process = header.processName, !process.isEmpty, !isPlaceholder(process) { return process }
            if let application = header.applicationId, !application.isEmpty, !isPlaceholder(application) {
                return application
            }
            return nil
        }

        /// Android Studio writes `pid-1234` where it doesn't know the process.
        private static func isPlaceholder(_ name: String) -> Bool {
            guard name.hasPrefix("pid-") else { return false }
            let digits = name.dropFirst(4)
            return !digits.isEmpty && digits.allSatisfy(\.isASCII) && digits.allSatisfy(\.isNumber)
        }
    }
}
