import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

enum QRCodeImage {
    /// Renders `text` as a QR code at least `minimumPixels` wide. Core Image makes one pixel per module, so
    /// it is scaled by a whole factor with nearest-neighbor sampling to keep the edges sharp for scanners.
    static func make(_ text: String, minimumPixels: CGFloat = 400) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, (minimumPixels / output.extent.width).rounded(.up))
        let scaled = output.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}

/// A QR code on a white square with a quiet zone, in light and dark mode alike: scanners need dark modules
/// on a light background.
struct QRCodeView: View {
    let payload: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
            } else {
                Color.white
            }
        }
        .frame(width: 200, height: 200)
        .padding(12)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: payload) { image = QRCodeImage.make(payload) }
        .accessibilityLabel("Pairing QR code")
    }
}
