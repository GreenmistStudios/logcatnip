#!/usr/bin/env swift
// Renders the app icon concept drafts to design/icons/.
//
//   swift design/render-icons.swift
//
// Plain CoreGraphics so it needs no tools beyond the Swift toolchain. Coordinates are top-left origin on a
// 1024 canvas; the icon body follows Apple's macOS grid (an 824pt rounded square inset by 100pt).
import AppKit
import CoreGraphics
import Foundation

let size: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let corner: CGFloat = 185

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// Dark-mode level colors from LogColors.swift, so the icon matches the table.
enum Level {
    static let verbose: UInt32 = 0xBBBBBB
    static let debug: UInt32 = 0x4FC1E9
    static let info: UInt32 = 0xA6C93A
    static let warn: UInt32 = 0xE0C341
    static let error: UInt32 = 0xFF6B68
    static let assert: UInt32 = 0xE38BFF
}

struct Random {
    var state: UInt64
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((state >> 33) % 10_000) / 10_000
    }
}

func linearGradient(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func radialGradient(_ ctx: CGContext, _ colors: [CGColor], center: CGPoint, radius: CGFloat) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
}

func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGRect {
    CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)
}

func render(_ name: String, draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(
        data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

    let squircle = CGPath(roundedRect: body, cornerWidth: corner, cornerHeight: corner, transform: nil)
    // Drop shadow as on macOS Big Sur+ icons. Shadow offsets are in device space, so negative y is down.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(squircle)
    ctx.setFillColor(color(0x000000))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    draw(ctx)
    ctx.restoreGState()

    // A faint inner edge highlight keeps dark icons from melting into a dark Dock.
    ctx.addPath(squircle)
    ctx.setStrokeColor(color(0xFFFFFF, 0.10))
    ctx.setLineWidth(2)
    ctx.strokePath()

    return ctx.makeImage()!
}

func save(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("Wrote \(url.path)")
}

// MARK: - 1. The log cat

func drawLogCat(_ ctx: CGContext) {
    linearGradient(ctx, [color(0x3E5288), color(0x1C2440)], from: CGPoint(x: 0, y: 100), to: CGPoint(x: 0, y: 924))

    // Stars.
    var random = Random(state: 7)
    for _ in 0..<26 {
        let x = 130 + random.next() * 760, y = 130 + random.next() * 300, r = 2 + random.next() * 3
        ctx.setFillColor(color(0xFFFFFF, 0.25 + random.next() * 0.4))
        ctx.fillEllipse(in: ellipse(x, y, r, r))
    }
    // Moon.
    ctx.setFillColor(color(0xFFF4D6, 0.9))
    ctx.fillEllipse(in: ellipse(770, 250, 52, 52))
    ctx.setFillColor(color(0x3A4D80))
    ctx.fillEllipse(in: ellipse(795, 232, 46, 46))

    // Ground.
    ctx.setFillColor(color(0x141A2E))
    ctx.fillEllipse(in: ellipse(512, 1000, 560, 190))

    // Log body.
    let logTop: CGFloat = 610, logBottom: CGFloat = 800, logLeft: CGFloat = 250, logRight: CGFloat = 840
    let logMidY = (logTop + logBottom) / 2, logRY = (logBottom - logTop) / 2
    ctx.setFillColor(color(0x000000, 0.3))
    ctx.fillEllipse(in: ellipse(560, 818, 330, 26))

    let bark = CGMutablePath()
    bark.addRect(CGRect(x: logLeft, y: logTop, width: logRight - logLeft, height: logBottom - logTop))
    bark.addEllipse(in: ellipse(logRight, logMidY, 46, logRY))
    ctx.saveGState()
    ctx.addPath(bark)
    ctx.clip()
    linearGradient(ctx, [color(0x9A6438), color(0x7A4A28), color(0x4E2F18)], from: CGPoint(x: 0, y: logTop), to: CGPoint(x: 0, y: logBottom))
    // Bark grooves read as log lines running along the trunk.
    ctx.setLineCap(.round)
    ctx.setLineWidth(9)
    for (i, y) in stride(from: logTop + 30, to: logBottom - 10, by: 34).enumerated() {
        ctx.setStrokeColor(color(0x3A2210, 0.55))
        let start = logLeft + 60 + CGFloat(i % 3) * 40
        ctx.move(to: CGPoint(x: start, y: y))
        ctx.addLine(to: CGPoint(x: start + 220 + CGFloat((i * 97) % 160), y: y))
        ctx.strokePath()
    }
    ctx.restoreGState()

    // End grain, with each growth ring in a logcat level color.
    let ringColors: [UInt32] = [0x5A3519, Level.error, Level.warn, Level.info, Level.debug, Level.verbose, Level.assert]
    let rx: CGFloat = 80
    for (i, ring) in ringColors.enumerated() {
        let t = 1 - CGFloat(i) / CGFloat(ringColors.count)
        ctx.setFillColor(color(0xF1D3A8))
        ctx.fillEllipse(in: ellipse(logLeft, logMidY, rx * t, logRY * t))
        ctx.setFillColor(color(ring))
        let inset: CGFloat = i == 0 ? 0 : 4
        ctx.fillEllipse(in: ellipse(logLeft, logMidY, rx * t - inset, logRY * t - inset))
    }
    ctx.setFillColor(color(0x3A2210))
    ctx.fillEllipse(in: ellipse(logLeft, logMidY, 8, 10))

    let fur = color(0xF39B43), furDark = color(0xC86A22), ink = color(0x3A2212)

    // Tail drapes over the front of the log in a tilde.
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: 740, y: 585))
    tail.addCurve(to: CGPoint(x: 790, y: 690), control1: CGPoint(x: 820, y: 600), control2: CGPoint(x: 840, y: 660))
    tail.addCurve(to: CGPoint(x: 640, y: 690), control1: CGPoint(x: 740, y: 720), control2: CGPoint(x: 700, y: 640))
    tail.addCurve(to: CGPoint(x: 560, y: 712), control1: CGPoint(x: 610, y: 715), control2: CGPoint(x: 585, y: 722))
    ctx.addPath(tail)
    ctx.setLineCap(.round)
    ctx.setLineWidth(40)
    ctx.setStrokeColor(furDark)
    ctx.strokePath()
    ctx.addPath(tail)
    ctx.setLineWidth(30)
    ctx.setStrokeColor(fur)
    ctx.strokePath()

    // Body loaf with tabby stripes.
    let bodyRect = ellipse(590, 548, 200, 92)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: color(0x000000, 0.35))
    ctx.setFillColor(fur)
    ctx.fillEllipse(in: bodyRect)
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: bodyRect)
    ctx.clip()
    linearGradient(ctx, [color(0xFFB868), color(0xE8862E)], from: CGPoint(x: 0, y: 460), to: CGPoint(x: 0, y: 640))
    ctx.setStrokeColor(furDark)
    ctx.setLineWidth(18)
    for x in stride(from: CGFloat(540), through: 740, by: 52) {
        ctx.move(to: CGPoint(x: x, y: 450))
        ctx.addQuadCurve(to: CGPoint(x: x + 10, y: 545), control: CGPoint(x: x + 26, y: 500))
        ctx.strokePath()
    }
    ctx.restoreGState()

    // Head, resting low on the log.
    let head = CGPoint(x: 418, y: 552)
    for (tip, a, b) in [
        (CGPoint(x: 352, y: 432), CGPoint(x: 352, y: 512), CGPoint(x: 408, y: 476)),
        (CGPoint(x: 478, y: 430), CGPoint(x: 436, y: 476), CGPoint(x: 490, y: 508)),
    ] {
        ctx.move(to: tip); ctx.addLine(to: a); ctx.addLine(to: b); ctx.closePath()
        ctx.setFillColor(fur)
        ctx.fillPath()
        let inner = { (p: CGPoint) in CGPoint(x: p.x + (head.x - p.x) * 0.0 + (tip.x - p.x) * 0.25, y: p.y + (tip.y - p.y) * 0.25) }
        ctx.move(to: CGPoint(x: tip.x + (head.x - tip.x) * 0.12, y: tip.y + 22))
        ctx.addLine(to: inner(a)); ctx.addLine(to: inner(b)); ctx.closePath()
        ctx.setFillColor(color(0xF7A7A0))
        ctx.fillPath()
    }
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: color(0x000000, 0.3))
    ctx.setFillColor(fur)
    ctx.fillEllipse(in: ellipse(head.x, head.y, 92, 80))
    ctx.restoreGState()
    ctx.setFillColor(color(0xFFD9A8))
    ctx.fillEllipse(in: ellipse(head.x, head.y + 34, 52, 34))
    // Forehead stripes.
    ctx.setStrokeColor(furDark)
    ctx.setLineWidth(8)
    for dx in [-18, 0, 18] as [CGFloat] {
        ctx.move(to: CGPoint(x: head.x + dx, y: head.y - 76))
        ctx.addLine(to: CGPoint(x: head.x + dx * 0.8, y: head.y - 50))
        ctx.strokePath()
    }
    // Closed, content eyes.
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(8)
    for x in [head.x - 36, head.x + 36] {
        ctx.move(to: CGPoint(x: x - 18, y: head.y + 2))
        ctx.addQuadCurve(to: CGPoint(x: x + 18, y: head.y + 2), control: CGPoint(x: x, y: head.y + 18))
        ctx.strokePath()
    }
    ctx.move(to: CGPoint(x: head.x - 10, y: head.y + 24))
    ctx.addLine(to: CGPoint(x: head.x + 10, y: head.y + 24))
    ctx.addLine(to: CGPoint(x: head.x, y: head.y + 36))
    ctx.closePath()
    ctx.setFillColor(color(0xE0707A))
    ctx.fillPath()
    // Whiskers.
    ctx.setStrokeColor(color(0xFFF1DE, 0.8))
    ctx.setLineWidth(3)
    for (dy, slope) in [(30, -8), (42, 4)] as [(CGFloat, CGFloat)] {
        ctx.move(to: CGPoint(x: head.x - 40, y: head.y + dy)); ctx.addLine(to: CGPoint(x: head.x - 118, y: head.y + dy + slope))
        ctx.move(to: CGPoint(x: head.x + 40, y: head.y + dy)); ctx.addLine(to: CGPoint(x: head.x + 118, y: head.y + dy + slope))
    }
    ctx.strokePath()
    // Paws over the edge of the log.
    for x in [480, 545] as [CGFloat] {
        ctx.setFillColor(fur)
        ctx.fillEllipse(in: ellipse(x, 618, 34, 20))
        ctx.setStrokeColor(furDark)
        ctx.setLineWidth(4)
        for dx in [-10, 10] as [CGFloat] {
            ctx.move(to: CGPoint(x: x + dx, y: 626)); ctx.addLine(to: CGPoint(x: x + dx, y: 636))
        }
        ctx.strokePath()
    }

    // Sleepy "z"s set in the log font.
    let font = NSFont.monospacedSystemFont(ofSize: 54, weight: .bold)
    for (text, x, y, scale, hex) in [("z", 488, 392, 1.0, Level.debug), ("Z", 532, 330, 1.35, Level.info)] as [(String, CGFloat, CGFloat, CGFloat, UInt32)] {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: font.pointSize * scale, weight: .bold),
            .foregroundColor: NSColor(cgColor: color(hex))!,
        ]).draw(at: CGPoint(x: x, y: y))
    }
}

// MARK: - 2. The catnip filter

/// An ovate, serrated catnip leaf pointing along `angle` (radians, 0 = right, measured clockwise because y
/// points down).
func leafPath(base: CGPoint, angle: CGFloat, length: CGFloat, width: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let steps = 120
    let teeth: CGFloat = 9
    func point(_ t: CGFloat, _ side: CGFloat) -> CGPoint {
        var w = width * sin(.pi * pow(t, 0.75)) * (1 - 0.25 * t)
        let tooth = t * teeth - floor(t * teeth)
        w *= 1 + 0.07 * (tooth < 0.7 ? tooth / 0.7 : (1 - tooth) / 0.3) * (t > 0.05 && t < 0.95 ? 1 : 0)
        let along = t * length, across = w * side
        return CGPoint(
            x: base.x + along * cos(angle) - across * sin(angle),
            y: base.y + along * sin(angle) + across * cos(angle)
        )
    }
    path.move(to: base)
    for i in 1...steps { path.addLine(to: point(CGFloat(i) / CGFloat(steps), 1)) }
    for i in stride(from: steps - 1, through: 0, by: -1) { path.addLine(to: point(CGFloat(i) / CGFloat(steps), -1)) }
    path.closeSubpath()
    return path
}

func drawCatnip(_ ctx: CGContext) {
    radialGradient(ctx, [color(0x1B3326), color(0x0A140F)], center: CGPoint(x: 512, y: 470), radius: 620)
    // Faint terminal scanlines.
    ctx.setFillColor(color(0xFFFFFF, 0.025))
    for y in stride(from: CGFloat(100), to: 924, by: 8) { ctx.fill(CGRect(x: 100, y: y, width: 824, height: 3)) }

    // Funnel.
    let funnel = CGMutablePath()
    funnel.move(to: CGPoint(x: 380, y: 690))
    funnel.addLine(to: CGPoint(x: 644, y: 690))
    funnel.addLine(to: CGPoint(x: 546, y: 768))
    funnel.addLine(to: CGPoint(x: 546, y: 800))
    funnel.addLine(to: CGPoint(x: 478, y: 800))
    funnel.addLine(to: CGPoint(x: 478, y: 768))
    funnel.closeSubpath()

    // Stem grows out of the funnel.
    let stem = CGMutablePath()
    stem.move(to: CGPoint(x: 512, y: 720))
    stem.addCurve(to: CGPoint(x: 512, y: 300), control1: CGPoint(x: 492, y: 590), control2: CGPoint(x: 532, y: 440))
    ctx.addPath(stem)
    ctx.setLineCap(.round)
    ctx.setLineWidth(22)
    ctx.setStrokeColor(color(0x4F8A32))
    ctx.strokePath()

    var random = Random(state: 42)
    let levels = [Level.verbose, Level.debug, Level.info, Level.info, Level.debug, Level.warn, Level.error]
    let leaves: [(CGPoint, CGFloat, CGFloat, CGFloat)] = [
        (CGPoint(x: 503, y: 600), .pi * 1.06, 290, 96),
        (CGPoint(x: 509, y: 600), -.pi * 0.06, 290, 96),
        (CGPoint(x: 512, y: 440), .pi * 1.24, 210, 74),
        (CGPoint(x: 516, y: 440), -.pi * 0.24, 210, 74),
    ]
    for (base, angle, length, width) in leaves {
        let leaf = leafPath(base: base, angle: angle, length: length, width: width)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0x000000, 0.5))
        ctx.addPath(leaf)
        ctx.setFillColor(color(0x3E8A2E))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(leaf)
        ctx.clip()
        let box = leaf.boundingBox
        linearGradient(ctx, [color(0x7ACB52), color(0x2F7A2A)], from: CGPoint(x: 0, y: box.minY), to: CGPoint(x: 0, y: box.maxY))
        // Log rows across the leaf: a level-colored badge, then the message.
        for y in stride(from: box.minY + 10, to: box.maxY, by: 26) {
            let level = levels[Int(random.next() * CGFloat(levels.count))]
            let x = box.minX + random.next() * 30
            ctx.setFillColor(color(level, 0.95))
            ctx.fill(CGRect(x: x, y: y, width: 22, height: 12))
            ctx.setFillColor(color(level, 0.45))
            ctx.fill(CGRect(x: x + 32, y: y, width: 60 + random.next() * box.width, height: 12))
        }
        ctx.restoreGState()

        // Midrib.
        ctx.move(to: base)
        ctx.addLine(to: CGPoint(x: base.x + length * 0.92 * cos(angle), y: base.y + length * 0.92 * sin(angle)))
        ctx.setLineWidth(6)
        ctx.setStrokeColor(color(0x1F4F1A, 0.8))
        ctx.strokePath()
    }

    // An Android head sprouts at the tip, its antennae drawn like young leaves.
    let androidGreen = color(0x3DDC84)
    let top = CGPoint(x: 512, y: 312)
    ctx.setLineWidth(12)
    ctx.setStrokeColor(androidGreen)
    for side in [-1, 1] as [CGFloat] {
        ctx.move(to: CGPoint(x: top.x + side * 40, y: top.y - 64))
        ctx.addQuadCurve(to: CGPoint(x: top.x + side * 78, y: top.y - 130), control: CGPoint(x: top.x + side * 48, y: top.y - 110))
        ctx.strokePath()
        ctx.setFillColor(androidGreen)
        ctx.fillEllipse(in: ellipse(top.x + side * 82, top.y - 136, 12, 12))
    }
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40, color: color(0x3DDC84, 0.55))
    ctx.move(to: CGPoint(x: top.x - 92, y: top.y))
    ctx.addArc(center: top, radius: 92, startAngle: .pi, endAngle: 0, clockwise: false)
    ctx.closePath()
    ctx.setFillColor(androidGreen)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.setFillColor(color(0x0A140F))
    ctx.fillEllipse(in: ellipse(top.x - 38, top.y - 40, 11, 11))
    ctx.fillEllipse(in: ellipse(top.x + 38, top.y - 40, 11, 11))

    // Funnel drawn over the stem base.
    ctx.saveGState()
    ctx.addPath(funnel)
    ctx.clip()
    linearGradient(ctx, [color(0xE6ECF2), color(0x9AA6B2)], from: CGPoint(x: 360, y: 0), to: CGPoint(x: 664, y: 0))
    ctx.restoreGState()
    ctx.setFillColor(color(0x5B6670))
    ctx.fill(CGRect(x: 380, y: 684, width: 264, height: 14))

    // What the filter lets through.
    for (i, hex) in [Level.error, Level.warn, Level.info].enumerated() {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 16, color: color(hex, 0.8))
        ctx.setFillColor(color(hex))
        ctx.fillEllipse(in: ellipse(512, 828 + CGFloat(i) * 28, 11 - CGFloat(i) * 2, 11 - CGFloat(i) * 2))
        ctx.restoreGState()
    }
}

// MARK: - 3. Cat eyes in the stream

func drawCatEyes(_ ctx: CGContext) {
    linearGradient(ctx, [color(0x161E3A), color(0x080B18)], from: CGPoint(x: 0, y: 100), to: CGPoint(x: 0, y: 924))

    let lines: [(UInt32, String)] = [
        (Level.debug, "D OkHttp: --> GET https://api.example.com/v1/feed"),
        (Level.info, "I ActivityManager: Start proc 4821:com.example.app/u0a231"),
        (Level.verbose, "V Choreographer: Skipped 2 frames! The application may be"),
        (Level.warn, "W System.err: java.net.SocketTimeoutException: timeout"),
        (Level.debug, "D ViewRootImpl: performTraversals mFirst=true"),
        (Level.error, "E AndroidRuntime: FATAL EXCEPTION: main"),
        (Level.error, "E AndroidRuntime:   at com.example.MainActivity.onCreate"),
        (Level.info, "I Zygote: Process 4821 exited due to signal 9 (Killed)"),
        (Level.debug, "D BluetoothAdapter: isLeEnabled(): ON"),
        (Level.verbose, "V WindowManager: Relayout Window{a1b2c3 u0 MainActivity}"),
        (Level.warn, "W ActivityTaskManager: Activity top resumed state loss"),
        (Level.info, "I chatty: uid=10231(com.example.app) RenderThread identical"),
    ]
    let font = NSFont.monospacedSystemFont(ofSize: 21, weight: .medium)
    var y: CGFloat = 104
    var i = 0
    while y < 924 {
        let (level, text) = lines[i % lines.count]
        let pid = 4800 + (i * 37) % 200
        let line = "11-10 14:02:\(String(format: "%02d.%03d", (i * 7) % 60, (i * 131) % 1000)) \(pid) \(pid + 12) \(text)"
        NSAttributedString(string: line, attributes: [
            .font: font,
            .foregroundColor: NSColor(cgColor: color(level, level == Level.error ? 0.5 : 0.28))!,
        ]).draw(at: CGPoint(x: 112 - CGFloat((i * 53) % 140), y: y))
        y += 29
        i += 1
    }

    // Cat head silhouette that swallows the text behind it.
    let head = CGMutablePath()
    head.move(to: CGPoint(x: 190, y: 560))
    head.addLine(to: CGPoint(x: 236, y: 230))
    head.addLine(to: CGPoint(x: 400, y: 380))
    head.addQuadCurve(to: CGPoint(x: 624, y: 380), control: CGPoint(x: 512, y: 340))
    head.addLine(to: CGPoint(x: 788, y: 230))
    head.addLine(to: CGPoint(x: 834, y: 560))
    head.addCurve(to: CGPoint(x: 512, y: 860), control1: CGPoint(x: 850, y: 760), control2: CGPoint(x: 700, y: 860))
    head.addCurve(to: CGPoint(x: 190, y: 560), control1: CGPoint(x: 324, y: 860), control2: CGPoint(x: 174, y: 760))
    head.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 50, color: color(0x000000, 0.9))
    ctx.addPath(head)
    ctx.setFillColor(color(0x05070F, 0.94))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(head)
    ctx.setStrokeColor(color(0x4FC1E9, 0.22))
    ctx.setLineWidth(3)
    ctx.strokePath()

    // Eyes: amber for WARN, red for ERROR.
    for (center, inner, outer) in [
        (CGPoint(x: 380, y: 585), 0xFFF1A8 as UInt32, Level.warn),
        (CGPoint(x: 644, y: 585), 0xFFC2BF as UInt32, Level.error),
    ] {
        let w: CGFloat = 92, h: CGFloat = 62
        let eye = CGMutablePath()
        eye.move(to: CGPoint(x: center.x - w, y: center.y))
        eye.addQuadCurve(to: CGPoint(x: center.x + w, y: center.y), control: CGPoint(x: center.x, y: center.y - h * 2))
        eye.addQuadCurve(to: CGPoint(x: center.x - w, y: center.y), control: CGPoint(x: center.x, y: center.y + h * 2))
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 70, color: color(outer, 0.9))
        ctx.addPath(eye)
        ctx.setFillColor(color(outer))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(eye)
        ctx.clip()
        radialGradient(ctx, [color(inner), color(outer)], center: center, radius: w)
        ctx.restoreGState()
        // Slit pupil shaped like a text cursor.
        ctx.setFillColor(color(0x05070F))
        ctx.addPath(CGPath(roundedRect: CGRect(x: center.x - 11, y: center.y - 56, width: 22, height: 112), cornerWidth: 11, cornerHeight: 11, transform: nil))
        ctx.fillPath()
        ctx.setFillColor(color(0xFFFFFF, 0.85))
        ctx.fillEllipse(in: ellipse(center.x + 30, center.y - 22, 9, 9))
    }

    // Nose and whiskers; the whiskers are log lines.
    ctx.move(to: CGPoint(x: 492, y: 690)); ctx.addLine(to: CGPoint(x: 532, y: 690)); ctx.addLine(to: CGPoint(x: 512, y: 714)); ctx.closePath()
    ctx.setFillColor(color(Level.assert, 0.75))
    ctx.fillPath()
    ctx.setLineCap(.round)
    ctx.setLineWidth(6)
    for (dy, slope, hex) in [(-6, -26, Level.debug), (14, 0, Level.info), (34, 26, Level.verbose)] as [(CGFloat, CGFloat, UInt32)] {
        ctx.setStrokeColor(color(hex, 0.7))
        ctx.move(to: CGPoint(x: 440, y: 710 + dy)); ctx.addLine(to: CGPoint(x: 250, y: 710 + dy + slope))
        ctx.move(to: CGPoint(x: 584, y: 710 + dy)); ctx.addLine(to: CGPoint(x: 774, y: 710 + dy + slope))
        ctx.strokePath()
    }
}

// MARK: - Output

let output = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("icons")
try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let concepts: [(String, CGImage)] = [
    ("concept-1-log-cat", render("log cat", draw: drawLogCat)),
    ("concept-2-catnip-filter", render("catnip", draw: drawCatnip)),
    ("concept-3-cat-eyes", render("cat eyes", draw: drawCatEyes)),
]
for (name, image) in concepts {
    save(image, to: output.appendingPathComponent("\(name).png"))
}

// Preview sheet: each concept at Dock and Finder sizes, on light and dark backgrounds, to check small-size
// legibility.
let sizes: [CGFloat] = [256, 128, 64, 32, 16]
let rowHeight: CGFloat = 300, sheetWidth: CGFloat = 1100
let sheet = CGContext(
    data: nil, width: Int(sheetWidth), height: Int(rowHeight * CGFloat(concepts.count * 2)), bitsPerComponent: 8,
    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
sheet.interpolationQuality = .high
for (row, (_, image)) in concepts.enumerated() {
    for (shade, background) in [(0, color(0xECECEC)), (1, color(0x1E1E1E))] {
        let top = CGFloat(sheet.height) - rowHeight * CGFloat(row * 2 + shade + 1)
        sheet.setFillColor(background)
        sheet.fill(CGRect(x: 0, y: top, width: sheetWidth, height: rowHeight))
        var x: CGFloat = 22
        for s in sizes {
            sheet.draw(image, in: CGRect(x: x, y: top + (rowHeight - s) / 2, width: s, height: s))
            x += s + 40
        }
    }
}
save(sheet.makeImage()!, to: output.appendingPathComponent("preview.png"))
