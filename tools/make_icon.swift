// make_icon.swift — draws the CCTV app icon and builds AppIcon.icns.
//
//   swift tools/make_icon.swift [output.icns] [keep-iconset-dir]
//
// Default output: <project>/AppIcon.icns. Everything is drawn with
// CoreGraphics on a 1024×1024 design grid (Apple's macOS icon grid:
// 824×824 rounded body centred on the canvas, with a soft drop shadow).
// Small sizes (≤ 32 px) use a simplified, bolder drawing so they stay legible.

import AppKit
import CoreGraphics

// MARK: - helpers

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
               colors: stops.map { $0.1 } as CFArray,
               locations: stops.map { $0.0 })!
}

/// Apple-style "squircle": a superellipse is a close match for the continuous-corner
/// rounded rectangle used by macOS app icons.
func squircle(_ r: CGRect, exponent n: CGFloat = 4.4) -> CGPath {
    let p = CGMutablePath()
    let a = r.width / 2, b = r.height / 2, cx = r.midX, cy = r.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

extension CGContext {
    func fill(_ path: CGPath, _ g: CGGradient, from: CGPoint, to: CGPoint) {
        saveGState(); addPath(path); clip()
        drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        restoreGState()
    }
    func fill(_ path: CGPath, _ c: CGColor) {
        saveGState(); addPath(path); setFillColor(c); fillPath(); restoreGState()
    }
    func stroke(_ path: CGPath, _ c: CGColor, _ w: CGFloat) {
        saveGState(); addPath(path); setStrokeColor(c); setLineWidth(w); strokePath(); restoreGState()
    }
}

// MARK: - drawing (design space: 1024×1024, y grows DOWN — we flip once up front)

func drawIcon(_ ctx: CGContext, small: Bool) {
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)

    // ---- body + shadow
    let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let body = squircle(bodyRect)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: rgb(0x000000, 0.45))
    ctx.fill(body, rgb(0x1E2530))
    ctx.restoreGState()

    // dark slate gradient
    ctx.fill(body, gradient([(0, rgb(0x46546A)), (0.55, rgb(0x2A3341)), (1, rgb(0x161B23))]),
             from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924))
    // soft top glow
    ctx.saveGState(); ctx.addPath(body); ctx.clip()
    ctx.drawRadialGradient(gradient([(0, rgb(0x7F93B0, 0.35)), (1, rgb(0x7F93B0, 0))]),
                           startCenter: CGPoint(x: 400, y: 160), startRadius: 0,
                           endCenter: CGPoint(x: 400, y: 160), endRadius: 620, options: [])
    ctx.restoreGState()
    // inner hairline for a crisp edge
    if !small { ctx.stroke(body, rgb(0xFFFFFF, 0.10), 3) }

    // the camera group sits slightly below centre so the composition balances
    let shiftY: CGFloat = 62

    // ---- field-of-view beam (very subtle)
    if !small {
        ctx.saveGState(); ctx.addPath(body); ctx.clip()
        ctx.translateBy(x: 0, y: shiftY)
        let beam = CGMutablePath()
        beam.move(to: CGPoint(x: 235, y: 500))
        beam.addLine(to: CGPoint(x: -160, y: 560))
        beam.addLine(to: CGPoint(x: 40, y: 1000))
        beam.addLine(to: CGPoint(x: 262, y: 585))
        beam.closeSubpath()
        ctx.addPath(beam); ctx.clip()
        ctx.drawRadialGradient(gradient([(0, rgb(0xA9CBFF, 0.22)), (0.5, rgb(0xA9CBFF, 0.07)), (1, rgb(0xA9CBFF, 0))]),
                               startCenter: CGPoint(x: 250, y: 545), startRadius: 20,
                               endCenter: CGPoint(x: 250, y: 545), endRadius: 520, options: [])
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.translateBy(x: 0, y: shiftY)

    // ---- wall mount (drawn behind the camera)
    let metalDark = gradient([(0, rgb(0xC9D0D9)), (1, rgb(0x7D8794))])
    let plate = roundedRect(CGRect(x: 772, y: 380, width: 70, height: 250), 22)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 8), blur: 16, color: rgb(0x000000, 0.35))
    ctx.fill(plate, rgb(0xAAB2BD))
    ctx.restoreGState()
    ctx.fill(plate, metalDark, from: CGPoint(x: 770, y: 470), to: CGPoint(x: 840, y: 720))
    if !small {
        for y in [420.0, 590.0] {   // screws
            let s = CGPath(ellipseIn: CGRect(x: 795, y: y - 10, width: 20, height: 20), transform: nil)
            ctx.fill(s, rgb(0x5E6774))
        }
    }
    // arm: from plate to the joint under the camera
    let arm = CGMutablePath()
    arm.move(to: CGPoint(x: 790, y: 505))
    arm.addLine(to: CGPoint(x: 680, y: 505))
    arm.addLine(to: CGPoint(x: 650, y: 440))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 8), blur: 14, color: rgb(0x000000, 0.35))
    ctx.addPath(arm); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setLineWidth(small ? 62 : 52); ctx.setStrokeColor(rgb(0x9AA3AE)); ctx.strokePath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(arm); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setLineWidth(small ? 62 : 52); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0xDCE1E7)), (1, rgb(0x8A94A1))]),
                           start: CGPoint(x: 0, y: 470), end: CGPoint(x: 0, y: 535), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // ---- camera (local coordinates, rotated so the lens points down-left)
    ctx.saveGState()
    ctx.translateBy(x: 505, y: 420)
    ctx.rotate(by: -0.34)                      // ~19°: lens tips down-left

    let L: CGFloat = small ? -300 : -290       // front x
    let R: CGFloat = 230                       // back x
    let H: CGFloat = small ? 112 : 100         // half height of housing

    // housing with drop shadow
    let housing = roundedRect(CGRect(x: L, y: -H, width: R - L, height: 2 * H), H * 0.62)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 10, height: 26), blur: 40, color: rgb(0x000000, 0.55))
    ctx.fill(housing, rgb(0xC8CED6))
    ctx.restoreGState()
    ctx.fill(housing, gradient([(0, rgb(0xFFFFFF)), (0.45, rgb(0xE6EAEF)), (1, rgb(0x98A2AE))]),
             from: CGPoint(x: 0, y: -H), to: CGPoint(x: 0, y: H))
    // specular streak
    if !small {
        let streak = roundedRect(CGRect(x: L + 70, y: -H + 22, width: (R - L) - 150, height: 26), 13)
        ctx.fill(streak, rgb(0xFFFFFF, 0.75))
    }
    // seam between housing and back cap
    if !small {
        let seam = CGMutablePath()
        seam.move(to: CGPoint(x: R - 70, y: -H + 6)); seam.addLine(to: CGPoint(x: R - 70, y: H - 6))
        ctx.stroke(seam, rgb(0x7A8491, 0.55), 5)
    }

    // sun-shade visor across the top, overhanging the front
    let visor = roundedRect(CGRect(x: L - 46, y: -H - 44, width: (R - L) + 30, height: 70), 32)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 16, color: rgb(0x000000, 0.30))
    ctx.fill(visor, rgb(0xEEF1F4))
    ctx.restoreGState()
    ctx.fill(visor, gradient([(0, rgb(0xFFFFFF)), (1, rgb(0xC3CAD3))]),
             from: CGPoint(x: 0, y: -H - 44), to: CGPoint(x: 0, y: -H + 26))

    // front bezel (seen in 3/4 view as an ellipse) + lens
    let fx = L + 22
    let bezel = CGPath(ellipseIn: CGRect(x: fx - 62, y: -H + 4, width: 124, height: 2 * H - 8), transform: nil)
    ctx.fill(bezel, gradient([(0, rgb(0x3A424E)), (1, rgb(0x14181E))]),
             from: CGPoint(x: 0, y: -H), to: CGPoint(x: 0, y: H))
    ctx.stroke(bezel, small ? rgb(0xB8C1CC) : rgb(0x5B6573), small ? 16 : 5)
    let lensR: CGFloat = small ? 66 : 62
    let lens = CGPath(ellipseIn: CGRect(x: fx - lensR * 0.62, y: -lensR, width: lensR * 1.24, height: 2 * lensR), transform: nil)
    ctx.saveGState(); ctx.addPath(lens); ctx.clip()
    ctx.drawRadialGradient(gradient([(0, rgb(0x5D8DDB)), (0.45, rgb(0x1E3A6E)), (1, rgb(0x05080F))]),
                           startCenter: CGPoint(x: fx - 6, y: 8), startRadius: 0,
                           endCenter: CGPoint(x: fx, y: 0), endRadius: lensR * 1.05, options: [])
    ctx.restoreGState()
    // inner iris ring and glints
    if !small {
        let iris = CGPath(ellipseIn: CGRect(x: fx - 22, y: -34, width: 44, height: 68), transform: nil)
        ctx.fill(iris, rgb(0x02040A, 0.85))
        ctx.stroke(iris, rgb(0x7FA6E8, 0.35), 3)
    }
    let glint = CGPath(ellipseIn: CGRect(x: fx - 26, y: -lensR * 0.72, width: small ? 26 : 20, height: small ? 34 : 28), transform: nil)
    ctx.fill(glint, rgb(0xFFFFFF, 0.85))
    if !small {
        let glint2 = CGPath(ellipseIn: CGRect(x: fx + 8, y: lensR * 0.30, width: 10, height: 14), transform: nil)
        ctx.fill(glint2, rgb(0xFFFFFF, 0.45))
    }

    // red recording LED on the housing side, with glow
    let led = CGPoint(x: small ? 70 : 90, y: small ? 18 : 22)
    let ledR: CGFloat = small ? 34 : 24
    if !small {
    ctx.saveGState()
    ctx.drawRadialGradient(gradient([(0, rgb(0xFF3B30, 0.55)), (1, rgb(0xFF3B30, 0))]),
                           startCenter: led, startRadius: ledR * 0.6, endCenter: led, endRadius: ledR * 3.0, options: [])
    ctx.restoreGState()
    }
    let ledPath = CGPath(ellipseIn: CGRect(x: led.x - ledR, y: led.y - ledR, width: 2 * ledR, height: 2 * ledR), transform: nil)
    ctx.saveGState(); ctx.addPath(ledPath); ctx.clip()
    ctx.drawRadialGradient(gradient([(0, rgb(0xFF8A80)), (0.5, rgb(0xFF3B30)), (1, rgb(0xC0160E))]),
                           startCenter: CGPoint(x: led.x - ledR * 0.3, y: led.y - ledR * 0.35), startRadius: 0,
                           endCenter: led, endRadius: ledR, options: [])
    ctx.restoreGState()
    if !small {
        ctx.stroke(ledPath, rgb(0x7A0B06, 0.6), 2.5)
        let hl = CGPath(ellipseIn: CGRect(x: led.x - ledR * 0.55, y: led.y - ledR * 0.7, width: ledR * 0.6, height: ledR * 0.45), transform: nil)
        ctx.fill(hl, rgb(0xFFFFFF, 0.7))
    }
    ctx.restoreGState()
    ctx.restoreGState()   // shiftY
}

// MARK: - render + package

func renderPNG(pixels: Int, to url: URL) throws {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let nsctx = NSGraphicsContext(bitmapImageRep: rep) else {
        throw NSError(domain: "make_icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "bitmap alloc failed"])
    }
    let ctx = nsctx.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let s = CGFloat(pixels) / 1024
    ctx.scaleBy(x: s, y: s)
    drawIcon(ctx, small: pixels <= 32)
    nsctx.flushGraphics()
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make_icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
    }
    try data.write(to: url)
}

let fm = FileManager.default
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let project = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let args = Array(CommandLine.arguments.dropFirst())
let output = args.count > 0 ? URL(fileURLWithPath: args[0]) : project.appendingPathComponent("AppIcon.icns")
let iconset: URL = args.count > 1
    ? URL(fileURLWithPath: args[1]).appendingPathComponent("AppIcon.iconset")
    : fm.temporaryDirectory.appendingPathComponent("cctv-\(getpid())/AppIcon.iconset")

try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try renderPNG(pixels: base, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try renderPNG(pixels: base * 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try p.run(); p.waitUntilExit()
guard p.terminationStatus == 0 else { fputs("iconutil failed\n", stderr); exit(1) }
if args.count < 2 { try? fm.removeItem(at: iconset.deletingLastPathComponent()) }
print("Wrote \(output.path)" + (args.count > 1 ? " (PNGs kept in \(iconset.path))" : ""))
