import AppKit
import Foundation
import SwiftUI
import Testing

/// Screenshot testing without dependencies: renders a view offscreen at a fixed size, scale and
/// appearance and compares it with a reference PNG in `__Snapshots__/macOS-<major>/`.
///
/// Text rendering changes between macOS releases, so references are kept per major version. When a
/// reference is missing the test records it and fails, so new images get looked at before they are
/// committed; on CI (`CI` set) it only records, because the runner's macOS may have no references yet.
/// Set `LOGCATNIP_RECORD_SNAPSHOTS=1` to rewrite every reference. Mismatches write the actual image
/// and a diff to `.build/snapshot-failures/`.
@MainActor
enum Snapshot {
    /// Rendered at 2x whatever the screen, so references match on Retina and non-Retina machines.
    static let scale: CGFloat = 2

    /// A channel may differ by this much (out of 255) before the pixel counts as changed, which absorbs
    /// antialiasing noise.
    nonisolated static let channelTolerance = 16
    /// Fraction of pixels that may change before the comparison fails. Rendering is exact from run to run
    /// on one macOS version, so this only allows a few stray pixels; one level badge is about 1,300.
    nonisolated static let pixelTolerance = 0.00002

    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let osDirectory = "macOS-\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"
    static let referenceDirectory = packageRoot
        .appending(path: "Tests/LogcatnipTests/__Snapshots__").appending(path: osDirectory)
    static let failureDirectory = packageRoot.appending(path: ".build/snapshot-failures").appending(path: osDirectory)

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static func assertSnapshot(
        of view: some View,
        named name: String,
        size: CGSize,
        appearance: NSAppearance.Name = .aqua,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let image = try await render(view, size: size, appearance: appearance)
        let reference = referenceDirectory.appending(path: "\(name).png")
        let fileManager = FileManager.default

        if environment["LOGCATNIP_RECORD_SNAPSHOTS"] == "1" || !fileManager.fileExists(atPath: reference.path) {
            let existed = fileManager.fileExists(atPath: reference.path)
            try fileManager.createDirectory(at: referenceDirectory, withIntermediateDirectories: true)
            try writePNG(image, to: reference)
            if !existed, environment["CI"] == nil, environment["LOGCATNIP_RECORD_SNAPSHOTS"] != "1" {
                Issue.record("Recorded a new reference at \(reference.path). Check it and run the tests again.", sourceLocation: sourceLocation)
            }
            return
        }

        let expected = try #require(loadPNG(reference), "Could not read \(reference.path)", sourceLocation: sourceLocation)
        let actual = Bitmap(image)
        let comparison = Bitmap(expected).compare(with: actual)
        let actualURL = failureDirectory.appending(path: "\(name).actual.png")
        let diffURL = failureDirectory.appending(path: "\(name).diff.png")
        guard !comparison.passes else {
            try? fileManager.removeItem(at: actualURL)
            try? fileManager.removeItem(at: diffURL)
            return
        }

        try fileManager.createDirectory(at: failureDirectory, withIntermediateDirectories: true)
        try writePNG(image, to: actualURL)
        var message = "Snapshot \(name) does not match \(reference.path): \(comparison.summary).\nActual: \(actualURL.path)"
        if let diff = comparison.diff {
            try writePNG(diff, to: diffURL)
            message += "\nDiff: \(diffURL.path)"
        }
        message += "\nIf the change is intended, run with LOGCATNIP_RECORD_SNAPSHOTS=1."
        Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
    }

    /// Hosts the view in a borderless offscreen window and draws it into an sRGB bitmap.
    static func render(_ view: some View, size: CGSize, appearance: NSAppearance.Name) async throws -> CGImage {
        _ = NSApplication.shared
        let appearance = try #require(NSAppearance(named: appearance))
        let root = view
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hosting
        defer { window.close() }

        // SwiftUI updates and the table's column sizing are deferred to later main-queue turns.
        for _ in 0..<6 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        hosting.layoutSubtreeIfNeeded()

        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        rep.size = size
        appearance.performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
        }
        let drawn = try #require(rep.cgImage)
        return try #require(Bitmap(drawn).image)
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    private static func loadPNG(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// RGBA pixels in sRGB, so images compare the same whatever color space they were drawn or saved in.
private struct Bitmap {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    var image: CGImage? {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    struct Comparison {
        var passes: Bool
        var summary: String
        /// The actual image faded, with changed pixels in red.
        var diff: CGImage?
    }

    func compare(with actual: Bitmap) -> Comparison {
        guard width == actual.width, height == actual.height else {
            return Comparison(
                passes: false,
                summary: "size changed from \(width)x\(height) to \(actual.width)x\(actual.height) pixels",
                diff: nil
            )
        }
        let identical = pixels.withUnsafeBytes { expected in
            actual.pixels.withUnsafeBytes { memcmp(expected.baseAddress, $0.baseAddress, expected.count) == 0 }
        }
        if identical {
            return Comparison(passes: true, summary: "identical", diff: nil)
        }
        var diff = actual
        var changed = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            var delta = 0
            for channel in 0..<4 {
                delta = max(delta, abs(Int(pixels[offset + channel]) - Int(actual.pixels[offset + channel])))
            }
            if delta > Snapshot.channelTolerance {
                changed += 1
                diff.pixels[offset] = 255
                diff.pixels[offset + 1] = 0
                diff.pixels[offset + 2] = 0
                diff.pixels[offset + 3] = 255
            } else {
                for channel in 0..<3 {
                    diff.pixels[offset + channel] = UInt8(255 - (255 - Int(actual.pixels[offset + channel])) / 4)
                }
                diff.pixels[offset + 3] = 255
            }
        }
        let fraction = Double(changed) / Double(width * height)
        let percent = (fraction * 100).formatted(.number.precision(.fractionLength(3)))
        return Comparison(
            passes: fraction <= Snapshot.pixelTolerance,
            summary: "\(changed) pixels (\(percent)%) differ",
            diff: diff.image
        )
    }
}
