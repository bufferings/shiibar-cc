#!/usr/bin/env swift
// Generates the ShiibarCC app icon iconset (docs/tasks/M5.md T10;
// DESIGN.md §4.5 "app icon"). Standalone script, run with the CLT's
// `swift`:
//
//   swift scripts/generate-app-icon.swift <output-dir>
//
// Writes <output-dir>/AppIcon.iconset/*.png (the standard 10-file iconset
// naming: icon_{16,32,128,256,512}x{same}[@2x].png). The caller
// (scripts/install.sh) runs `iconutil -c icns` on that directory to produce
// AppIcon.icns — this script does not shell out to iconutil itself.
//
// Geometry is expressed in a 100-unit logical space, y-down, scaled to each
// target pixel size (docs/tasks/M5.md T10). This file is the geometry's
// source of truth (DESIGN.md §4.5: "the generator script is the source of truth for geometry").
//
// Any failure here exits non-zero with a message on stderr — no silent
// fallback. The caller (install.sh) is expected to treat that as a hard
// install failure.

import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - CLI

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift generate-app-icon.swift <output-dir>\n".utf8))
    exit(1)
}

let outputDir = URL(fileURLWithPath: arguments[1], isDirectory: true)
let iconsetDir = outputDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)

// MARK: - Palette (DESIGN.md §4.5 / M5.md T10)

func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255
    let g = CGFloat((hex >> 8) & 0xFF) / 255
    let b = CGFloat(hex & 0xFF) / 255
    return CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
}

let tileColor = rgb(0x1b1b1e)
let foregroundColor = rgb(0xf2f0ec)
let badgeColor = rgb(0xf2464d)
let haloColor = rgb(0xffffff, alpha: 0.9)

// MARK: - Iconset file list (standard Apple iconutil naming)

struct IconEntry {
    let filename: String
    let pixels: Int
}

let entries: [IconEntry] = [
    IconEntry(filename: "icon_16x16.png", pixels: 16),
    IconEntry(filename: "icon_16x16@2x.png", pixels: 32),
    IconEntry(filename: "icon_32x32.png", pixels: 32),
    IconEntry(filename: "icon_32x32@2x.png", pixels: 64),
    IconEntry(filename: "icon_128x128.png", pixels: 128),
    IconEntry(filename: "icon_128x128@2x.png", pixels: 256),
    IconEntry(filename: "icon_256x256.png", pixels: 256),
    IconEntry(filename: "icon_256x256@2x.png", pixels: 512),
    IconEntry(filename: "icon_512x512.png", pixels: 512),
    IconEntry(filename: "icon_512x512@2x.png", pixels: 1024),
]

// Sizes at or below this many pixels use the simplified tile+asterisk-only
// variant (M5.md T10: "at 32px and below, the simplified ✳-only variant") — the state-symbol column
// and badge are too fine to read at that resolution.
let simplifiedThreshold = 32

// U+2733 EIGHT SPOKED ASTERISK with VS15 (U+FE0E) to force the text
// presentation (M5.md T10: "bare U+2733 (text presentation)") instead of a
// possible color-emoji glyph.
let asterisk = "\u{2733}\u{FE0E}"

// MARK: - Text helpers (CoreText, drawn directly into the CGContext)

func ctFont(size: CGFloat, bold: Bool = false) -> CTFont {
    let font = NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    return font as CTFont
}

func makeLine(_ text: String, font: CTFont, color: CGColor) -> CTLine {
    let attrs: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: color,
    ]
    let attrString = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
    return CTLineCreateWithAttributedString(attrString)
}

/// Draws `text` with an explicit baseline point, optionally centered on x
/// around that point (used where the spec pins an exact baseline, e.g. the
/// full-size ✳).
func drawBaselineText(_ ctx: CGContext, text: String, font: CTFont, color: CGColor, baseline: CGPoint, centerX: Bool) {
    let line = makeLine(text, font: font, color: color)
    var origin = baseline
    if centerX {
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        origin.x -= width / 2
    }
    ctx.textPosition = origin
    CTLineDraw(line, ctx)
}

/// Draws `text` optically centered (both axes) on `center` (used where the
/// spec gives a center point / font size but no baseline, e.g. the
/// simplified ✳ and the state-column "!").
func drawCenteredText(_ ctx: CGContext, text: String, font: CTFont, color: CGColor, center: CGPoint) {
    let line = makeLine(text, font: font, color: color)
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
    let origin = CGPoint(x: center.x - width / 2, y: center.y - (ascent - descent) / 2)
    ctx.textPosition = origin
    CTLineDraw(line, ctx)
}

// MARK: - Drawing

func drawTile(_ ctx: CGContext, margin: CGFloat, tileSize: CGFloat) {
    let rect = CGRect(x: margin, y: margin, width: tileSize, height: tileSize)
    // Rounded-rect approximation of a Big Sur squircle (M5.md T10 explicitly
    // accepts this). ~22.4% corner radius matches the squircle's visual
    // roundness closely enough at icon sizes.
    let cornerRadius = tileSize * 0.224
    let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(path)
    ctx.setFillColor(tileColor)
    ctx.fillPath()
}

/// Waiting symbol: circle + bold "!" + red badge with a white halo on the
/// upper-right shoulder (M5.md T10). The exact vertical placement of "!"
/// inside the circle isn't pinned by the spec beyond its font size — it's
/// drawn optically centered.
func drawWaitingSymbol(_ ctx: CGContext, center: CGPoint, r: CGFloat, length: (CGFloat) -> CGFloat, strokeWidth: CGFloat) {
    let radius = length(r)
    ctx.setStrokeColor(foregroundColor)
    ctx.setLineWidth(strokeWidth)
    ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))

    let font = ctFont(size: length(r * 1.75), bold: true)
    drawCenteredText(ctx, text: "!", font: font, color: foregroundColor, center: center)

    // Badge offset (+0.74r, -0.74r) in the spec's y-down logical space means
    // right and up; `center` here is already in CG's y-up pixel space, so up
    // is +y.
    let badgeCenter = CGPoint(x: center.x + length(r * 0.74), y: center.y + length(r * 0.74))
    let badgeRadius = length(4.2)
    let badgeRect = CGRect(x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius, width: badgeRadius * 2, height: badgeRadius * 2)
    ctx.setFillColor(badgeColor)
    ctx.fillEllipse(in: badgeRect)
    ctx.setStrokeColor(haloColor)
    ctx.setLineWidth(length(4.2 * 0.22))
    ctx.strokeEllipse(in: badgeRect)
}

/// Working symbol: an open 270° arc, round caps, no arrowhead (M5.md T10).
/// The spec doesn't pin the gap's rotation for the icon; the gap is placed
/// in the north-west quadrant to match the existing "working" spinner glyph
/// (docs/menubar-design.html, `.spin` path: starts due north, sweeps
/// clockwise on-screen through east/south to due west).
func drawWorkingSymbol(_ ctx: CGContext, center: CGPoint, r: CGFloat, length: (CGFloat) -> CGFloat, strokeWidth: CGFloat) {
    ctx.setStrokeColor(foregroundColor)
    ctx.setLineWidth(strokeWidth)
    ctx.setLineCap(.round)
    let radius = length(r)
    let startAngle = CGFloat.pi / 2 // due north
    let endAngle = startAngle - (3 * .pi / 2) // 270 degrees, clockwise on-screen
    ctx.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
    ctx.strokePath()
}

/// Idle symbol: empty circle at 50% stroke opacity (M5.md T10).
func drawIdleSymbol(_ ctx: CGContext, center: CGPoint, r: CGFloat, length: (CGFloat) -> CGFloat, strokeWidth: CGFloat) {
    ctx.setStrokeColor(foregroundColor.copy(alpha: 0.5) ?? foregroundColor)
    ctx.setLineWidth(strokeWidth)
    let radius = length(r)
    ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
}

func drawStateColumn(_ ctx: CGContext, point: (CGFloat, CGFloat) -> CGPoint, length: (CGFloat) -> CGFloat) {
    let columnX: CGFloat = 72
    let r: CGFloat = 8
    let strokeWidth = length(2.6)

    drawWaitingSymbol(ctx, center: point(columnX, 26), r: r, length: length, strokeWidth: strokeWidth)
    drawWorkingSymbol(ctx, center: point(columnX, 52), r: r, length: length, strokeWidth: strokeWidth)
    drawIdleSymbol(ctx, center: point(columnX, 78), r: r, length: length, strokeWidth: strokeWidth)
}

func renderIcon(pixels: Int) -> CGImage {
    let canvas = CGFloat(pixels)
    guard let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("failed to create bitmap context for \(pixels)px icon")
    }
    ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))

    // Apple's icon grid: the tile doesn't fill the canvas edge to edge — it
    // sits inset, the way other macOS app icons (e.g. iTerm2's) read at the
    // same visual size as their neighbors in Finder/Dock. 8.5% margin per
    // side is a hardcoded, deliberately chosen inset (M5.md T10 asks for "a
    // sensible inset" without pinning an exact number).
    let marginFraction: CGFloat = 0.085
    let margin = canvas * marginFraction
    let tileSize = canvas - margin * 2
    let scale = tileSize / 100.0 // pixels per logical unit

    // Logical space is y-down (M5.md T10); CGContext's bitmap space is
    // y-up. `py` does the flip so every other helper can work in plain
    // spec coordinates.
    func px(_ x: CGFloat) -> CGFloat { margin + x * scale }
    func py(_ y: CGFloat) -> CGFloat { canvas - (margin + y * scale) }
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: px(x), y: py(y)) }
    func length(_ units: CGFloat) -> CGFloat { units * scale }

    drawTile(ctx, margin: margin, tileSize: tileSize)

    if pixels <= simplifiedThreshold {
        // Simplified variant: tile + ✳ only, centered, 60 units (M5.md T10).
        let font = ctFont(size: length(60))
        drawCenteredText(ctx, text: asterisk, font: font, color: foregroundColor, center: point(50, 50))
    } else {
        let font = ctFont(size: length(46))
        drawBaselineText(ctx, text: asterisk, font: font, color: foregroundColor, baseline: point(32, 49), centerX: true)
        drawStateColumn(ctx, point: point, length: length)
    }

    guard let image = ctx.makeImage() else {
        fatalError("failed to snapshot rendered \(pixels)px icon")
    }
    return image
}

// MARK: - Main

do {
    try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write(Data("error: failed to create iconset directory \(iconsetDir.path): \(error)\n".utf8))
    exit(1)
}

for entry in entries {
    let image = renderIcon(pixels: entry.pixels)
    let fileURL = iconsetDir.appendingPathComponent(entry.filename)
    guard let destination = CGImageDestinationCreateWithURL(fileURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write(Data("error: failed to create PNG destination for \(entry.filename)\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        FileHandle.standardError.write(Data("error: failed to write \(fileURL.path)\n".utf8))
        exit(1)
    }
}

print("Wrote \(entries.count) PNGs to \(iconsetDir.path)")
