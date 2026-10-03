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

/// A window card: a plain rounded rectangle with a soft shadow under it.
func card(_ ctx: CGContext, _ r: CGRect, _ color: CGColor, shadow: CGFloat) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: rgb(0x000000, shadow))
    ctx.addPath(rounded(r, r.width * 0.09))
    ctx.setFillColor(color)
    ctx.fillPath()
    ctx.restoreGState()
}

func draw(_ ctx: CGContext) {
    // Graphite tile with a soft drop shadow, the way macOS icons sit on the grid.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.3))
    ctx.addPath(squircle(tile))
    ctx.setFillColor(rgb(0x1b1c20))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle(tile))
    ctx.clip()
    linear(ctx, [rgb(0x4a4e57), rgb(0x1b1c20)], from: CGPoint(x: 0, y: tile.maxY), to: CGPoint(x: 0, y: tile.minY))

    // The queue: the window in front, two more waiting behind it.
    let front = CGRect(x: 222, y: 222, width: 580, height: 420)
    for depth in [2, 1] {
        let d = CGFloat(depth)
        let w = front.width * (1 - d * 0.12), h = front.height * (1 - d * 0.12)
        let r = CGRect(x: front.midX - w / 2, y: front.maxY + d * 96 - h, width: w, height: h)
        card(ctx, r, rgb(0xffffff, 0.9 - d * 0.25), shadow: 0.25)
    }
    card(ctx, front, rgb(0xffffff), shadow: 0.5)
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
