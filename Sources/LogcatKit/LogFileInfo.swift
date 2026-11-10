import Foundation

/// What a saved log says about where it came from: the device, its build, and when it was captured. Shown in the
/// status bar of file sessions.
public struct LogFileInfo: Sendable, Equatable {
    public var deviceName: String?
    public var release: String?
    public var apiLevel: Int?
    public var serial: String?
    public var fingerprint: String?
    public var build: String?
    public var capturedAt: Date?

    public init(
        deviceName: String? = nil, release: String? = nil, apiLevel: Int? = nil, serial: String? = nil,
        fingerprint: String? = nil, build: String? = nil, capturedAt: Date? = nil
    ) {
        self.deviceName = deviceName
        self.release = release
        self.apiLevel = apiLevel
        self.serial = serial
        self.fingerprint = fingerprint
        self.build = build
        self.capturedAt = capturedAt
    }

    /// Named like the sidebar names a live device: the AVD name with spaces, or the manufacturer and model.
    /// `Device.displayName` in the app does the same; it can't move here without dragging the app type along.
    public init(properties: DeviceProperties) {
        var name: String?
        if let avd = properties.avdName, !avd.isEmpty {
            name = avd.replacingOccurrences(of: "_", with: " ")
        } else if let model = properties.model, !model.isEmpty {
            name = Self.name(manufacturer: properties.manufacturer, model: model)
        }
        self.init(
            deviceName: name, release: properties.release, apiLevel: properties.apiLevel,
            serial: properties.values["ro.serialno"]
        )
    }

    public init(device: LogcatFileDevice) {
        var name: String?
        if device.kind == .emulator, let avd = device.avdName, !avd.isEmpty {
            name = avd.replacingOccurrences(of: "_", with: " ")
        } else if let model = device.model, !model.isEmpty {
            name = Self.name(manufacturer: device.manufacturer, model: model)
        } else {
            name = device.name
        }
        self.init(deviceName: name, release: device.release, apiLevel: device.apiLevel, serial: device.serialNumber)
    }

    private static func name(manufacturer: String?, model: String) -> String {
        if let manufacturer, !manufacturer.isEmpty, !model.lowercased().hasPrefix(manufacturer.lowercased()) {
            return "\(manufacturer.capitalized) \(model)"
        }
        return model
    }

    /// One line: "Medium Phone API 37.0 · Android 17, API 37 · google/sdk_gphone64_arm64/…/release-keys".
    public var summary: String {
        var parts: [String] = []
        if let deviceName { parts.append(deviceName) }
        if let android = androidText { parts.append(android) }
        if let fingerprint { parts.append(fingerprint) }
        return parts.joined(separator: " · ")
    }

    /// Several lines, for a tooltip.
    public var details: String {
        var lines: [String] = []
        if let deviceName { lines.append("Device: \(deviceName)") }
        if let android = androidText { lines.append("Android: \(android.replacingOccurrences(of: "Android ", with: ""))") }
        if let serial { lines.append("Serial: \(serial)") }
        if let build { lines.append("Build: \(build)") }
        if let fingerprint { lines.append("Fingerprint: \(fingerprint)") }
        if let capturedAt { lines.append("Captured: \(LogcatTime.format(capturedAt.timeIntervalSince1970))") }
        return lines.joined(separator: "\n")
    }

    private var androidText: String? {
        switch (release, apiLevel) {
        case let (release?, api?): "Android \(release), API \(api)"
        case let (release?, nil): "Android \(release)"
        case let (nil, api?): "API \(api)"
        case (nil, nil): nil
        }
    }
}
