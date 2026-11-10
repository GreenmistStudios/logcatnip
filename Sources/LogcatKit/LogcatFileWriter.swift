import Foundation

/// Writes Android Studio's `.logcat` format exactly as its Gson setup does (pretty printing, HTML-safe escaping, field
/// order, no trailing newline), so Android Studio opens our files and a file it wrote survives a round trip. The pieces
/// are separate so `LogFileWriter` can stream a large file a batch of messages at a time.
public enum LogcatFileWriter {
    /// The whole file in memory; for tests and small saves. Markers are not log records and are skipped.
    public static func encode(
        metadata: LogcatFileMetadata, entries: [LogEntry], processNames: [Int32: String] = [:]
    ) -> String {
        var output = opening(metadata)
        var isFirst = true
        for entry in entries where entry.kind == .log {
            output += message(entry, processName: entry.processName ?? processNames[entry.pid], isFirst: isFirst)
            isFirst = false
        }
        output += closing(hadMessages: !isFirst)
        return output
    }

    /// `{`, the metadata object, and `"logcatMessages": [` (no newline after the bracket).
    static func opening(_ metadata: LogcatFileMetadata) -> String {
        var output = "{\n  \"metadata\": {\n"
        if let device = metadata.device {
            output += deviceObject(device) + ",\n"
        }
        output += "    \"filter\": \(quoted(metadata.filter)),\n"
        output += "    \"projectApplicationIds\": \(stringArray(metadata.projectApplicationIds, indent: 4))"
        // Logcatnip's own keys come last and only when used, so a file without ignore lists is byte for byte what
        // Android Studio writes.
        if !metadata.ignoredTags.isEmpty {
            output += ",\n    \"ignoredTags\": \(stringArray(metadata.ignoredTags, indent: 4))"
        }
        if !metadata.ignoredPackages.isEmpty {
            output += ",\n    \"ignoredPackages\": \(stringArray(metadata.ignoredPackages, indent: 4))"
        }
        output += "\n  },\n  \"logcatMessages\": ["
        return output
    }

    /// One message object at indent level 2, preceded by "\n    " for the first message and ",\n    " otherwise.
    static func message(_ entry: LogEntry, processName: String?, isFirst: Bool) -> String {
        let (applicationId, process) = names(for: entry, processName: processName)
        // The table's rounding, so the saved time is the displayed time; split like `Instant` (floored).
        let milliseconds = LogcatTime.milliseconds(entry.timestamp)
        let seconds = milliseconds >= 0 ? milliseconds / 1000 : (milliseconds - 999) / 1000
        let nanos = Int(milliseconds - seconds * 1000) * 1_000_000

        var output = isFirst ? "\n    {\n" : ",\n    {\n"
        output += "      \"header\": {\n"
        output += "        \"logLevel\": \"\(entry.level.name)\",\n"
        output += "        \"pid\": \(entry.pid),\n"
        output += "        \"tid\": \(entry.tid),\n"
        output += "        \"applicationId\": \(quoted(applicationId)),\n"
        output += "        \"processName\": \(quoted(process)),\n"
        output += "        \"tag\": \(quoted(entry.tag)),\n"
        output += "        \"timestamp\": {\n"
        output += "          \"seconds\": \(seconds),\n"
        output += "          \"nanos\": \(nanos)\n"
        output += "        }\n"
        output += "      },\n"
        output += "      \"message\": \(quoted(entry.message))\n"
        output += "    }"
        return output
    }

    /// "]\n}" when there were no messages, "\n  ]\n}" otherwise.
    static func closing(hadMessages: Bool) -> String {
        hadMessages ? "\n  ]\n}" : "]\n}"
    }

    /// Android Studio's header values for an entry: (applicationId, processName). It writes `pid-N` where it doesn't
    /// know the process, and `kernel` for pid 0 (`LogcatHeaderParser`); reading maps `pid-N` back to "unknown".
    static func names(for entry: LogEntry, processName: String?) -> (applicationId: String, processName: String) {
        if let processName, !processName.isEmpty {
            return (LogEntry.packageName(forProcess: processName), processName)
        }
        let placeholder = entry.pid == 0 ? "kernel" : "pid-\(entry.pid)"
        return (placeholder, placeholder)
    }

    // MARK: JSON

    /// A JSON string literal, quoted and escaped like Gson's `JsonWriter` with HTML-safe escaping, which Android
    /// Studio leaves on: `"` and `\`, the short forms of `\t \b \n \r \f`, `\u00xx` for other control characters,
    /// and `\u003c \u003e \u0026 \u003d \u0027` for `< > & = '`, as well as U+2028 and U+2029. Everything else,
    /// DEL and non-ASCII included, is written as it is.
    static func quoted(_ text: String) -> String {
        guard needsEscaping(text) else { return "\"" + text + "\"" }
        var output = "\""
        output.reserveCapacity(text.utf8.count + 16)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\u{0C}": output += "\\f"
            case "<", ">", "&", "=", "'", "\u{2028}", "\u{2029}":
                output += unicodeEscape(scalar)
            default:
                if scalar.value < 0x20 {
                    output += unicodeEscape(scalar)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
        return output
    }

    /// The bytes that need work: control characters, `"`, `\`, `<`, `>`, `&`, `=`, `'`, and 0xE2, the lead byte of
    /// U+2028 and U+2029 (it also leads other characters such as `…`, which then take the slow path for nothing).
    private static func needsEscaping(_ text: String) -> Bool {
        for byte in text.utf8 {
            switch byte {
            case 0..<0x20, 0x22, 0x5C, 0x3C, 0x3E, 0x26, 0x3D, 0x27, 0xE2: return true
            default: continue
            }
        }
        return false
    }

    private static func unicodeEscape(_ scalar: Unicode.Scalar) -> String {
        let hex = String(scalar.value, radix: 16)
        return "\\u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
    }

    /// `[]` when empty, otherwise one string per line, indented two columns deeper than the key that owns the array.
    private static func stringArray(_ values: [String], indent: Int) -> String {
        guard !values.isEmpty else { return "[]" }
        let inner = String(repeating: " ", count: indent + 2)
        let outer = String(repeating: " ", count: indent)
        return "[\n" + values.map { inner + quoted($0) }.joined(separator: ",\n") + "\n" + outer + "]"
    }

    /// Every value is written, as Gson would for Android Studio's non-null fields. The `name` fallbacks keep the
    /// name of a device from a pre-2025 file's flat format when that file is saved again.
    private static func deviceObject(_ device: LogcatFileDevice) -> String {
        let isEmulator = device.kind == .emulator
        let identifier = device.deviceId
            ?? (isEmulator ? "path=\(device.avdPath ?? "")" : "serial=\(device.serialNumber ?? "")")
        let apiLevel = device.apiLevel ?? 0
        var output = "    \"device\": {\n"
        output += "      \"\(isEmulator ? "emulatorDevice" : "physicalDevice")\": {\n"
        output += "        \"deviceId\": {\n"
        output += "          \"pluginId\": \"\(isEmulator ? "LocalEmulator" : "PhysicalDevice")\",\n"
        output += "          \"isTemplate\": false,\n"
        output += "          \"identifier\": \(quoted(identifier))\n"
        output += "        },\n"
        output += "        \"serialNumber\": \(quoted(device.serialNumber ?? "")),\n"
        output += "        \"isOnline\": \(device.isOnline ?? false),\n"
        output += "        \"release\": \(quoted(device.release ?? "")),\n"
        output += "        \"apiLevel\": {\n"
        output += "          \"majorVersion\": \(apiLevel),\n"
        output += "          \"minorVersion\": \(device.apiMinorLevel ?? 0)\n"
        output += "        },\n"
        output += "        \"featureLevel\": \(device.featureLevel ?? apiLevel),\n"
        if isEmulator {
            output += "        \"avdName\": \(quoted(device.avdName ?? device.name ?? "")),\n"
            output += "        \"avdPath\": \(quoted(device.avdPath ?? "")),\n"
        } else {
            output += "        \"manufacturer\": \(quoted(device.manufacturer ?? "")),\n"
            output += "        \"model\": \(quoted(device.model ?? device.name ?? "")),\n"
        }
        output += "        \"type\": \(quoted(device.type ?? "HANDHELD"))\n"
        output += "      }\n"
        output += "    }"
        return output
    }
}

// MARK: Describing a device for saving

extension LogcatFileDevice {
    /// A live device the way Android Studio's `Device.createPhysical` / `createEmulator` describes it, from getprop.
    /// Emulators are recognized by their AVD name, which Android Studio's `EmulatorDevice` has and phones don't.
    public init(properties: DeviceProperties, serial: String, isOnline: Bool, avdPath: String?) {
        let avdName = properties.avdName.flatMap { $0.isEmpty ? nil : $0 }
        let apiLevel = properties.apiLevel ?? 0
        // `37.0`, `36.1`: the minor version of the SDK, which Android 16 QPR releases bump without a new API level.
        let minor = properties.values["ro.build.version.sdk_full"]
            .flatMap { $0.split(separator: ".").dropFirst().first }
            .flatMap { Int($0) } ?? 0
        // A preview build reports the next API level's codename, and Android Studio counts it as that level.
        let codename = properties.values["ro.build.version.codename"] ?? "REL"
        let featureLevel = (codename.isEmpty || codename == "REL") ? apiLevel : apiLevel + 1
        let characteristics = (properties.values["ro.build.characteristics"] ?? "").split(separator: ",").map(String.init)
        let type = if characteristics.contains("watch") {
            "WEAR"
        } else if characteristics.contains("tv") {
            "TV"
        } else if characteristics.contains("automotive") {
            "AUTOMOTIVE"
        } else {
            "HANDHELD"
        }
        let release = Self.normalizedRelease(properties.release ?? "")
        if let avdName {
            self.init(
                kind: .emulator, serialNumber: serial, isOnline: isOnline, release: release, apiLevel: apiLevel,
                apiMinorLevel: minor, featureLevel: featureLevel, avdName: avdName, avdPath: avdPath ?? "",
                deviceId: "path=\(avdPath ?? "")", type: type
            )
        } else {
            self.init(
                kind: .physical, serialNumber: serial, isOnline: isOnline, release: release, apiLevel: apiLevel,
                apiMinorLevel: minor, featureLevel: featureLevel, manufacturer: properties.manufacturer ?? "",
                model: properties.model ?? "", deviceId: "serial=\(serial)", type: type
            )
        }
    }

    /// What a bug report tells us about its device, so a saved bug report still names it. Nil when it names nothing.
    /// Android Studio's name for the result is the model, which is the name the status bar showed.
    public init?(info: LogFileInfo) {
        guard info.deviceName != nil || info.serial != nil else { return nil }
        let apiLevel = info.apiLevel ?? 0
        self.init(
            kind: .physical, serialNumber: info.serial ?? "", isOnline: false, release: info.release ?? "",
            apiLevel: apiLevel, apiMinorLevel: 0, featureLevel: apiLevel, manufacturer: "", model: info.deviceName ?? "",
            deviceId: "serial=\(info.serial ?? "")", type: "HANDHELD"
        )
    }

    /// `14.0` -> `14`, `8.1.0` -> `8.1`: trailing `.0` parts dropped, like Android Studio's `normalizeVersion`.
    static func normalizedRelease(_ release: String) -> String {
        var result = release
        while result.hasSuffix(".0") { result.removeLast(2) }
        return result
    }
}

/// Finds an AVD's data folder the way the emulator does: `<avd home>/<name>.ini` names it (`path=`, or `path.rel=`
/// relative to the Android user home). The folder name often differs from the AVD name (`Medium_Phone.avd` for
/// `Medium_Phone_API_37.0`), so guessing `<name>.avd` is only the last resort.
public enum AvdLocator {
    public static func path(forAvdName name: String, environment: [String: String], home: URL) -> String? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        var avdHomes: [URL] = []
        if let value = environment["ANDROID_AVD_HOME"], !value.isEmpty {
            avdHomes.append(URL(fileURLWithPath: value, isDirectory: true))
        }
        if let value = environment["ANDROID_USER_HOME"], !value.isEmpty {
            avdHomes.append(URL(fileURLWithPath: value, isDirectory: true).appendingPathComponent("avd"))
        }
        avdHomes.append(home.appendingPathComponent(".android").appendingPathComponent("avd"))

        for avdHome in avdHomes where isDirectory(avdHome.path) {
            if let text = try? String(contentsOf: avdHome.appendingPathComponent("\(name).ini"), encoding: .utf8) {
                let values = parseINI(text)
                if let path = values["path"], isDirectory(path) { return path }
                if let relative = values["path.rel"] {
                    let resolved = avdHome.deletingLastPathComponent().appendingPathComponent(relative).path
                    if isDirectory(resolved) { return resolved }
                }
            }
            let guess = avdHome.appendingPathComponent("\(name).avd").path
            if isDirectory(guess) { return guess }
        }
        return nil
    }

    private static func parseINI(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        text.enumerateLines { line, _ in
            guard let separator = line.firstIndex(of: "=") else { return }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            values[key] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }
        return values
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
