import AppKit
import LogcatKit

/// Colors used for log levels and tags, close to Android Studio's defaults in both light and dark mode.
enum LogColors {
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    static let verbose = dynamic(light: rgb(0x6E6E6E), dark: rgb(0xBBBBBB))
    static let debug = dynamic(light: rgb(0x1D6F8C), dark: rgb(0x4FC1E9))
    static let info = dynamic(light: rgb(0x4A7A00), dark: rgb(0xA6C93A))
    static let warn = dynamic(light: rgb(0x9A6B00), dark: rgb(0xE0C341))
    static let error = dynamic(light: rgb(0xC0262D), dark: rgb(0xFF6B68))
    static let assert = dynamic(light: rgb(0x8B2FA8), dark: rgb(0xE38BFF))

    static func text(for level: LogLevel) -> NSColor {
        switch level {
        case .verbose: verbose
        case .debug: debug
        case .info: info
        case .warn: warn
        case .error: error
        case .assert: assert
        }
    }

    static func badgeBackground(for level: LogLevel) -> NSColor {
        switch level {
        case .verbose: rgb(0xD6D6D6)
        case .debug: rgb(0x305D78)
        case .info: rgb(0x6A8759)
        case .warn: rgb(0xBBB529)
        case .error: rgb(0xCF5B56)
        case .assert: rgb(0x9876AA)
        }
    }

    static func badgeText(for level: LogLevel) -> NSColor {
        switch level {
        case .verbose, .warn: .black
        default: .white
        }
    }

    private static let tagPalette: [NSColor] = [
        dynamic(light: rgb(0x2E7D32), dark: rgb(0x81C784)),
        dynamic(light: rgb(0x1565C0), dark: rgb(0x64B5F6)),
        dynamic(light: rgb(0x6A1B9A), dark: rgb(0xBA68C8)),
        dynamic(light: rgb(0xAD1457), dark: rgb(0xF06292)),
        dynamic(light: rgb(0x00838F), dark: rgb(0x4DD0E1)),
        dynamic(light: rgb(0xEF6C00), dark: rgb(0xFFB74D)),
        dynamic(light: rgb(0x4E342E), dark: rgb(0xBCAAA4)),
        dynamic(light: rgb(0x283593), dark: rgb(0x9FA8DA)),
        dynamic(light: rgb(0x558B2F), dark: rgb(0xC5E1A5)),
        dynamic(light: rgb(0x00695C), dark: rgb(0x80CBC4)),
    ]

    /// A stable color per tag, so the same tag is easy to spot as it scrolls by.
    static func tag(_ tag: String) -> NSColor {
        var hash: UInt32 = 2166136261
        for byte in tag.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16777619
        }
        return tagPalette[Int(hash % UInt32(tagPalette.count))]
    }
}
