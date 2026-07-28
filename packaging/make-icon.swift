#!/usr/bin/env swift
// make-icon.swift — generate packaging/AppIcon.icns
//
// The app has no artwork of its own; the menu bar glyph is drawn in code and is
// 1-bit template art that reads as a smudge at icon sizes. So the Finder icon is
// drawn here instead, reusing the dashboard palette from DesignTokens.swift so
// the two look like the same product.
//
// Regenerate with:  swift packaging/make-icon.swift
// The resulting .icns is committed, so neither a normal build nor CI needs to
// run this.

import AppKit
import CoreGraphics
import Foundation

// Palette — kept in sync with Sources/MacTR/Rendering/DesignTokens.swift
func rgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
    CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
}
let bgTop = rgb(26, 30, 48)
let bgBot = rgb(10, 12, 20)
let cyan = rgb(34, 211, 238)
let green = rgb(52, 211, 153)
let orange = rgb(251, 191, 36)

/// Draw the icon into a square context of side `S`, in native (Y-up) coords.
func drawIcon(_ ctx: CGContext, _ S: CGFloat) {
    let u = S / 1024  // all geometry below is authored at 1024pt

    // Squircle plate. Apple's grid puts a "large" icon at 824/1024 with a
    // ~185pt corner, leaving the padding the system expects for drop shadows.
    let inset = 100 * u
    let plate = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 185 * u, cornerHeight: 185 * u,
                           transform: nil)

    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: [bgTop, bgBot] as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: plate.maxY),
                               end: CGPoint(x: 0, y: plate.minY), options: [])
    }
    ctx.restoreGState()

    // Hairline rim — without it the plate dissolves into a dark desktop.
    ctx.addPath(platePath)
    ctx.setStrokeColor(rgb(58, 66, 92))
    ctx.setLineWidth(4 * u)
    ctx.strokePath()

    // The LCD: a 16:9 screen, which is the actual aspect of the Trofeo panel.
    let sw = 560 * u
    let sh = sw * 9 / 16
    let screen = CGRect(x: (S - sw) / 2, y: (S - sh) / 2 + 46 * u, width: sw, height: sh)
    let screenPath = CGPath(roundedRect: screen, cornerWidth: 26 * u, cornerHeight: 26 * u,
                            transform: nil)
    ctx.addPath(screenPath)
    ctx.setFillColor(rgb(7, 9, 16))
    ctx.fillPath()
    ctx.addPath(screenPath)
    ctx.setStrokeColor(cyan)
    ctx.setLineWidth(14 * u)
    ctx.strokePath()

    // Three bars climbing left to right — the "it's a monitor" cue. Bar heights
    // are deliberately uneven so the shape still reads at 16pt, where the colors
    // blur together but the silhouette survives.
    let bars: [(CGFloat, CGColor)] = [(0.46, cyan), (0.70, green), (0.94, orange)]
    let barW = 84 * u
    let gap = 46 * u
    let totalW = barW * 3 + gap * 2
    let baseY = screen.minY + 54 * u
    let maxH = screen.height - 108 * u
    var bx = screen.midX - totalW / 2
    for (frac, color) in bars {
        let h = maxH * frac
        let r = CGRect(x: bx, y: baseY, width: barW, height: h)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: barW / 2, cornerHeight: barW / 2,
                           transform: nil))
        ctx.setFillColor(color)
        ctx.fillPath()
        bx += barW + gap
    }

    // Stand — neck plus foot, so the screen doesn't float.
    let neck = CGRect(x: S / 2 - 26 * u, y: screen.minY - 62 * u, width: 52 * u, height: 66 * u)
    ctx.addPath(CGPath(roundedRect: neck, cornerWidth: 10 * u, cornerHeight: 10 * u,
                       transform: nil))
    ctx.setFillColor(rgb(78, 88, 116))
    ctx.fillPath()

    let foot = CGRect(x: S / 2 - 132 * u, y: screen.minY - 92 * u, width: 264 * u, height: 34 * u)
    ctx.addPath(CGPath(roundedRect: foot, cornerWidth: 17 * u, cornerHeight: 17 * u,
                       transform: nil))
    ctx.setFillColor(rgb(96, 107, 138))
    ctx.fillPath()
}

func renderPNG(side: Int, to url: URL) throws {
    let S = CGFloat(side)
    guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw NSError(domain: "icon", code: 1) }
    ctx.setAllowsAntialiasing(true)
    drawIcon(ctx, S)
    guard let image = ctx.makeImage() else { throw NSError(domain: "icon", code: 2) }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: side, height: side)
    guard let data = rep.representation(using: .png, properties: [:])
    else { throw NSError(domain: "icon", code: 3) }
    try data.write(to: url)
}

// MARK: - Build the .iconset and hand it to iconutil

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconset = here.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// (point size, scale) → iconutil's required filename set
let variants: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                              (256, 1), (256, 2), (512, 1), (512, 2)]
for (pt, scale) in variants {
    let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
    try renderPNG(side: pt * scale, to: iconset.appendingPathComponent(name))
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset.path,
                  "-o", here.appendingPathComponent("AppIcon.icns").path]
try proc.run()
proc.waitUntilExit()
guard proc.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}
try? FileManager.default.removeItem(at: iconset)
print("wrote \(here.appendingPathComponent("AppIcon.icns").path)")
