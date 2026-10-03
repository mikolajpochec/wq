// Draws WindowQueue's app icon and writes Resources/AppIcon.icns.
// Usage: swift Scripts/make-icon.swift [output-dir-for-preview-pngs]
import AppKit
import SwiftUI

let canvas: CGFloat = 1024
// Apple's macOS icon grid: an 824 pt rounded square centred on a 1024 pt canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// The continuous-corner rounded square macOS icons are cut to.
func squircle(_ r: CGRect) -> CGPath {
    RoundedRectangle(cornerRadius: r.width * 0.2237, style: .continuous).path(in: r).cgPath
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: r).cgPath
}

func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

let focus = rgb(0xffd23f)

/// One window card. The one in front gets a title bar with the three lights, a few lines of text
/// and the focus ring; the ones queued behind it are plain.
func window(_ ctx: CGContext, _ r: CGRect, alpha: CGFloat, front: Bool) {
    let radius = r.width * 0.075
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 44, color: rgb(0x0a0630, front ? 0.5 : 0.28))
    ctx.addPath(rounded(r, radius))
    ctx.setFillColor(rgb(0xffffff, alpha))
    ctx.fillPath()
    ctx.restoreGState()
    guard front else { return }

    ctx.saveGState()
    ctx.addPath(rounded(r, radius))
    ctx.clip()
    let bar = r.height * 0.17
    let barRect = CGRect(x: r.minX, y: r.maxY - bar, width: r.width, height: bar)
    ctx.setFillColor(rgb(0xeceef6))
    ctx.fill(barRect)
    let d = bar * 0.36
    for (i, color) in [0xff5f57, 0xfebc2e, 0x28c840].enumerated() {
        let x = r.minX + bar * 0.42 + CGFloat(i) * d * 1.6
        ctx.setFillColor(rgb(UInt32(color)))
        ctx.fillEllipse(in: CGRect(x: x, y: barRect.midY - d / 2, width: d, height: d))
    }
    let inset = r.width * 0.1
    let line = r.height * 0.075
    for (i, w) in [0.8, 0.58, 0.68].enumerated() {
        let y = barRect.minY - inset * 0.9 - CGFloat(i) * line * 2 - line
        ctx.addPath(rounded(CGRect(x: r.minX + inset, y: y, width: (r.width - 2 * inset) * w, height: line), line / 2))
        ctx.setFillColor(rgb(0xd3d6e8))
        ctx.fillPath()
    }
    ctx.restoreGState()

    // The focus ring, in the colour of the lit icon in the strip.
    ctx.addPath(rounded(r.insetBy(dx: -10, dy: -10), radius + 10))
    ctx.setStrokeColor(focus)
    ctx.setLineWidth(12)
    ctx.strokePath()
}

func draw(_ ctx: CGContext) {
    // Tile with a soft drop shadow, the way macOS icons sit on the grid.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.3))
    ctx.addPath(squircle(tile))
    ctx.setFillColor(rgb(0x3b2fd0))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle(tile))
    ctx.clip()
    linear(ctx, [rgb(0x4f8dff), rgb(0x5b3df0), rgb(0x3a1fa8)], from: CGPoint(x: 0, y: tile.maxY), to: CGPoint(x: 0, y: tile.minY))
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [rgb(0xffffff, 0.22), rgb(0xffffff, 0)] as CFArray, locations: nil)!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 900), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 900), endRadius: 560, options: [])

    // The queue: windows receding behind the one in front.
    let front = CGRect(x: 330, y: 206, width: 500, height: 392)
    for depth in [2, 1] {
        let d = CGFloat(depth)
        let scale = 1 - d * 0.1
        let w = front.width * scale, h = front.height * scale
        let r = CGRect(x: front.midX - w / 2, y: front.maxY + d * 96 - h, width: w, height: h)
        window(ctx, r, alpha: 0.82 - d * 0.22, front: false)
    }
    window(ctx, front, alpha: 1, front: true)

    // The strip: one icon per window in the queue, the focused one lit, level with its window.
    let strip = CGRect(x: 166, y: 206, width: 108, height: 604)
    ctx.addPath(rounded(strip, 54))
    ctx.setFillColor(rgb(0xffffff, 0.16))
    ctx.fillPath()
    ctx.addPath(rounded(strip.insetBy(dx: 1.5, dy: 1.5), 52.5))
    ctx.setStrokeColor(rgb(0xffffff, 0.3))
    ctx.setLineWidth(3)
    ctx.strokePath()
    let icon: CGFloat = 68
    let spots = 4
    let pad = (strip.width - icon) / 2
    let gap = (strip.height - 2 * pad - CGFloat(spots) * icon) / CGFloat(spots - 1)
    for i in 0..<spots {
        let r = CGRect(x: strip.midX - icon / 2, y: strip.maxY - pad - icon - CGFloat(i) * (icon + gap), width: icon, height: icon)
        ctx.saveGState()
        let lit = i == spots - 1
        if lit { ctx.setShadow(offset: .zero, blur: 28, color: rgb(0xffd23f, 0.9)) }
        ctx.addPath(rounded(r, 20))
        ctx.setFillColor(lit ? focus : rgb(0xffffff, 0.3 + CGFloat(i) * 0.1))
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.restoreGState()
}

func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    draw(ctx)
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try render(points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
if CommandLine.arguments.count > 1 {
    let preview = URL(fileURLWithPath: CommandLine.arguments[1])
    try render(1024).write(to: preview.appendingPathComponent("icon-1024.png"))
    try render(64).write(to: preview.appendingPathComponent("icon-64.png"))
    try render(32).write(to: preview.appendingPathComponent("icon-32.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print("wrote Resources/AppIcon.icns")
