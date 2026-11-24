import Foundation

/// An installed app's version, read from `dumpsys package <pkg>` for crash reports.
public struct AppVersion: Sendable, Hashable {
    public var versionName: String?
    public var versionCode: Int?
    public var targetSdk: Int?
    public var installerPackage: String?

    public init(versionName: String? = nil, versionCode: Int? = nil, targetSdk: Int? = nil, installerPackage: String? = nil) {
        self.versionName = versionName
        self.versionCode = versionCode
        self.targetSdk = targetSdk
        self.installerPackage = installerPackage
    }

    /// `1.2.3 (123)`, `1.2.3` or `(123)`, or nil when neither is known.
    public var displayText: String? {
        switch (versionName, versionCode) {
        case let (name?, code?): "\(name) (\(code))"
        case let (name?, nil): name
        case let (nil, code?): "(\(code))"
        case (nil, nil): nil
        }
    }

    /// Reads the first package of the `Packages:` section. An updated system app also lists its factory
    /// version under `Hidden system packages:`, and some releases print a second `Packages:` section for
    /// it; the first one is the version that runs. Fields print as `null` when the manifest leaves them out.
    public static func parse(dumpsysPackage output: String) -> AppVersion? {
        var inPackages = false
        var packageIndent: Int?
        var version = AppVersion()
        var found = false
        for line in output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let indent = line.prefix { $0 == " " }.count
            if packageIndent == nil {
                if trimmed == "Packages:" {
                    inPackages = true
                } else if inPackages, trimmed.hasPrefix("Package [") {
                    packageIndent = indent
                    found = true
                } else if inPackages, !trimmed.isEmpty, indent == 0 {
                    inPackages = false
                }
                continue
            }
            // The package's fields are indented under its `Package [...]` line; anything else ends it.
            guard !trimmed.isEmpty else { continue }
            if indent <= packageIndent! { break }
            if trimmed.hasPrefix("versionName=") {
                version.versionName = value(trimmed.dropFirst("versionName=".count))
            } else if trimmed.hasPrefix("installerPackageName=") {
                version.installerPackage = value(trimmed.dropFirst("installerPackageName=".count))
            } else if trimmed.hasPrefix("versionCode=") {
                // `versionCode=123 minSdk=24 targetSdk=34`; API 23 and older print no minSdk.
                for token in trimmed.split(separator: " ") {
                    guard let equals = token.firstIndex(of: "=") else { continue }
                    let number = Int(token[token.index(after: equals)...])
                    switch token[..<equals] {
                    case "versionCode": version.versionCode = number
                    case "targetSdk": version.targetSdk = number
                    default: break
                    }
                }
            }
        }
        return found ? version : nil
    }

    private static func value(_ text: Substring) -> String? {
        let value = text.trimmingCharacters(in: .whitespaces)
        return value.isEmpty || value == "null" ? nil : value
    }
}
