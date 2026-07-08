#!/usr/bin/env swift
// Generates the ShiibarCC app icon iconset (docs/tasks/M5.md T10;
// DESIGN.md §4.5 "app icon"). Standalone script, run with the CLT's
// `swift`:
//
//   swift scripts/generate-app-icon.swift <output-dir>
//
// Writes <output-dir>/AppIcon.iconset/*.png (the standard 10-file iconset
// naming: icon_{16,32,128,256,512}x{same}[@2x].png). The caller
// (scripts/dev-install.sh) runs `iconutil -c icns` on that directory to produce
// AppIcon.icns — this script does not shell out to iconutil itself.
//
// Geometry is expressed in a 100-unit logical space, y-down, scaled to each
// target pixel size (docs/tasks/M5.md T10). This file is the geometry's
// source of truth (DESIGN.md §4.5: "the generator script is the source of truth for geometry").
//
// Any failure here exits non-zero with a message on stderr — no silent
// fallback. The caller (dev-install.sh) is expected to treat that as a hard
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
// variant (M24 T2: "at 32px and below, the simplified ✻-only variant") — the
// badge is too fine to read at that resolution.
let simplifiedThreshold = 32

// U+273B TEARDROP-SPOKED ASTERISK with VS15 (U+FE0E) to force the text
// presentation (M24 T2: "bare U+273B (text presentation)") instead of a
// possible color-emoji glyph — same character as the tray emblem
// (TrayIconMetrics.emblemText) and the dropdown row symbol's idle glyph.
let asterisk = "\u{273B}\u{FE0E}"

// MARK: - Text helpers (CoreText, drawn directly into the CGContext)

func ctFont(size: CGFloat) -> CTFont {
    let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
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

/// Draws `text` optically centered (both axes) on `center` (used for both
/// the simplified and normal ✻: M24 T2 drops the old exact-baseline
/// placement in favor of optical centering for both variants).
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

/// Red unreviewed badge with a white halo (M24 T2: same two-layer drawing
/// as the pre-M24 badge this replaces — a filled circle plus a stroked
/// halo ring of the same radius). `center` and `r` are in the 100-unit
/// logical space; `length` converts to pixels.
func drawBadge(_ ctx: CGContext, center: CGPoint, r: CGFloat, length: (CGFloat) -> CGFloat) {
    let radius = length(r)
    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    ctx.setFillColor(badgeColor)
    ctx.fillEllipse(in: rect)
    ctx.setStrokeColor(haloColor)
    ctx.setLineWidth(length(r * 0.22))
    ctx.strokeEllipse(in: rect)
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
        // Simplified variant: tile + centered ✻ only, 60pt, no badge (M24
        // T2) — too fine a resolution for a badge to read.
        let font = ctFont(size: length(60))
        drawCenteredText(ctx, text: asterisk, font: font, color: foregroundColor, center: point(50, 50))
    } else {
        // Normal variant: tile + ✻ optically centered at (30, 30), 56pt +
        // red badge at (78, 22), r 7 (M24 T2 — replaces the old baseline-
        // pinned ✳ + state-symbol column entirely).
        let font = ctFont(size: length(56))
        drawCenteredText(ctx, text: asterisk, font: font, color: foregroundColor, center: point(30, 30))
        drawBadge(ctx, center: point(78, 22), r: 7, length: length)
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
