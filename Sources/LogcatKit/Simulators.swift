import Foundation

/// A simulator as listed by `simctl list devices --json`.
public struct SimulatorDevice: Sendable, Hashable, Identifiable {
    public var udid: String
    public var name: String
    /// `Booted`, `Shutdown`, `Booting`, `Shutting Down`, ...
    public var state: String
    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-5`
    public var runtimeIdentifier: String
    /// `com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro`
    public var deviceTypeIdentifier: String?
    public var isAvailable: Bool

    public var id: String { udid }
    public var isBooted: Bool { state == "Booted" }

    public init(
        udid: String,
        name: String,
        state: String,
        runtimeIdentifier: String,
        deviceTypeIdentifier: String? = nil,
        isAvailable: Bool = true
    ) {
        self.udid = udid
        self.name = name
        self.state = state
        self.runtimeIdentifier = runtimeIdentifier
        self.deviceTypeIdentifier = deviceTypeIdentifier
        self.isAvailable = isAvailable
    }

    /// `iOS 26.5` for `com.apple.CoreSimulator.SimRuntime.iOS-26-5`. simctl only gives the runtime's display
    /// name from a separate `list runtimes` call, and the identifier carries the same information.
    public var runtimeName: String {
        let last = runtimeIdentifier.split(separator: ".").last.map(String.init) ?? runtimeIdentifier
        var parts = last.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return last }
        var platform = parts.removeFirst()
        if platform == "xrOS" { platform = "visionOS" }
        return parts.isEmpty ? platform : "\(platform) \(parts.joined(separator: "."))"
    }

    /// The platform part of the runtime, such as `iOS`, `watchOS`, `tvOS` or `visionOS`.
    public var platform: String {
        runtimeName.split(separator: " ").first.map(String.init) ?? runtimeName
    }
}

/// Decodes `simctl list devices --json`.
public enum SimulatorList {
    private struct Root: Decodable {
        var devices: [String: [Entry]]
    }

    private struct Entry: Decodable {
        var udid: String
        var name: String
        var state: String
        var deviceTypeIdentifier: String?
        var isAvailable: Bool?
    }

    /// Every listed simulator, sorted by runtime and name so the order is stable between polls.
    public static func decode(_ data: Data) throws -> [SimulatorDevice] {
        let root = try JSONDecoder().decode(Root.self, from: data)
        var devices: [SimulatorDevice] = []
        for (runtime, entries) in root.devices {
            for entry in entries {
                devices.append(SimulatorDevice(
                    udid: entry.udid,
                    name: entry.name,
                    state: entry.state,
                    runtimeIdentifier: runtime,
                    deviceTypeIdentifier: entry.deviceTypeIdentifier,
                    isAvailable: entry.isAvailable ?? true
                ))
            }
        }
        return devices.sorted {
            ($0.name, $0.runtimeIdentifier, $0.udid) < ($1.name, $1.runtimeIdentifier, $1.udid)
        }
    }

    /// The simulators whose logs can be streamed: booted and backed by an installed runtime.
    public static func booted(_ data: Data) throws -> [SimulatorDevice] {
        try decode(data).filter { $0.isBooted && $0.isAvailable }
    }
}
