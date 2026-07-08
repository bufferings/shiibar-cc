// AppKit renderer for the tray icon (the tray section of menubar-design.html,
// DESIGN.md §4.5 / M24 T1's "window + one glyph" geometry): draws the
// rounded window frame + one emblem-slot glyph carrying the whole rollup
// (+ red unreviewed badge) into an NSImage, redrawn on every state change
// (and, only while the rollup shows `working`, on every animation tick —
// see `AppState`'s working-animation timer).
//
// Why an NSImage and not composed SwiftUI views: the MenuBarExtra label is
// not a normal rendering context. On-device it dropped Shape strokes and
// flattened the custom text layout to a bare menu-bar-styled glyph (while
// the identical view rendered fine inside the dropdown window). DESIGN.md
// §4.5 prescribes exactly this approach for the tray ("render by NSImage
// compositing, redrawn per state change"); a plain `Image` is the reliably
// supported label content.
//
// Two-layer rule (menubar-design.html implementation notes) — unchanged by
// the M24 T1 redesign:
//   - no badge -> ONE template image (glyph only). Auto-tints to the menu
//                 bar's foreground color; the dim level is baked into the
//                 alpha channel, which template rendering preserves.
//   - badge    -> ONE non-template image: glyph drawn in a light/dark
//                 appearance-matched monochrome + red badge with its light
//                 halo. This is the spec's sanctioned fallback
//                 (appearance-observed non-template compositing).
//
// M24 T1 unified the tray's whole rollup into ONE emblem-slot glyph (top-
// left, x 6.4): idle/none show the static `✻` (plain U+273B, forced to text
// presentation with trailing U+FE0E so it never renders as a colored emoji
// glyph — it must not be reshaped toward the Anthropic sunburst logo
// either); working swaps in the same `GlyphCycleSpinner` cycle
// (ShiibarCcCore) the dropdown row symbol animates (§9); waiting swaps in a
// bold "!" at ~1.1x the emblem size. The old bottom-right lit-dot working
// indicator and bottom-right "!" are gone — the emblem slot IS the rollup
// now. All geometry lives in `TrayIconMetrics` below — single place to
// tweak after looking at the real menu bar. `emblemFontSize` is a starting
// point (M24 brief: 9.5, legibility outranks the exact number — bump back
// toward 10.5 on-device if the ✻ petals collapse on a real Retina menu
// bar). Badge size/position are unchanged from the pre-M24 on-device round.
//
// Coordinates are y-up (CoreGraphics/AppKit convention, `flipped: false`
// below) — menubar-design.html's SVG mock shows the same shape y-flipped.

import AppKit
import ShiibarCcCore

/// Every tunable constant for the tray drawing, in points, on a y-up canvas.
/// Values are M24 T1's "window + one glyph" geometry.
enum TrayIconMetrics {
    static let canvasWidth: CGFloat = 20
    static let canvasHeight: CGFloat = 18

    // Full-height rounded window frame.
    static let frameRect = NSRect(x: 0.8, y: 0.8, width: 16, height: 16.2)
    static let frameCornerRadius: CGFloat = 3.5
    static let frameLineWidth: CGFloat = 1.4

    // Emblem slot, top-left — the ENTIRE rollup lives here now (M24 T1):
    // idle/none draw the static ✻ (plain U+273B, forced text presentation),
    // working cycles GlyphCycleSpinner's frames, waiting swaps in a bold "!"
    // at `waitingBangScale` times this size.
    static let emblemText = "\u{273B}\u{FE0E}"
    static let emblemCenter = NSPoint(x: 6.4, y: 11.2)
    // M24 brief starting point: 9.5 ("legibility outranks the number" — the
    // brief permits bumping back up to 10.5 on-device if the ✻ petals
    // collapse on a real Retina menu bar). Supersedes the pre-M24 12pt,
    // which was sized for the old always-plus-a-separate-status-glyph
    // layout this design replaces.
    static let emblemFontSize: CGFloat = 9.5

    // Waiting "!": swapped into the emblem slot in place of the ✻, ~1.1x
    // its size (M24 brief), heavy weight.
    static let waitingBangScale: CGFloat = 1.1

    // Red unreviewed badge, overhanging the frame's top-right corner, with a
    // light halo ring always drawn (invisible on light bars by design).
    // Unchanged by M24 T1 (pre-M24 on-device round 2026-07-05: r 2.2 was too
    // small to register as a badge next to real menu bar neighbors; grown
    // and pulled slightly inward so dot + halo still fit the 18pt canvas).
    static let badgeCenter = NSPoint(x: 15.6, y: 13.9)
    static let badgeRadius: CGFloat = 3.6
    static let haloLineWidth: CGFloat = 0.9
    static let badgeColor = NSColor(srgbRed: 0.95, green: 0.30, blue: 0.32, alpha: 1)
    static let haloColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85)

    // Glyph monochrome for the non-template (badge) variant.
    static let lightAppearanceGlyph = NSColor.black.withAlphaComponent(0.9)
    static let darkAppearanceGlyph = NSColor.white.withAlphaComponent(0.95)
}

enum TrayIconRenderer {
    /// Render the tray image for `state`. `darkMenuBar` only matters for
    /// the non-template (badge) variant; the template variant tints itself.
    static func render(state: TrayIconState, darkMenuBar: Bool) -> NSImage {
        let size = NSSize(width: TrayIconMetrics.canvasWidth, height: TrayIconMetrics.canvasHeight)
        let image = NSImage(size: size, flipped: false) { _ in
            draw(state: state, darkMenuBar: darkMenuBar)
            return true
        }
        image.isTemplate = !state.hasUnreviewedDot
        return image
    }

    private static func draw(state: TrayIconState, darkMenuBar: Bool) {
        let m = TrayIconMetrics.self
        let dim = CGFloat(state.dim)

        // Template images carry meaning only in the alpha channel, so the
        // dim level is applied as alpha either way.
        let base: NSColor = state.hasUnreviewedDot
            ? (darkMenuBar ? m.darkAppearanceGlyph : m.lightAppearanceGlyph)
            : .black
        let glyphColor = base.withAlphaComponent(base.alphaComponent * dim)
        glyphColor.setStroke()
        glyphColor.setFill()

        // 1. Rounded window frame.
        let frame = NSBezierPath(
            roundedRect: m.frameRect,
            xRadius: m.frameCornerRadius,
            yRadius: m.frameCornerRadius
        )
        frame.lineWidth = m.frameLineWidth
        frame.stroke()

        // 2. Emblem slot — the ENTIRE rollup lives here now (M24 T1):
        // waiting swaps in a bold "!", working cycles the same glyph-cycle
        // spinner as the dropdown row symbol (`GlyphCycleSpinner`,
        // ShiibarCcCore), idle/none show the static ✻. Core's Rollup
        // priority (waiting > working > idle) is untouched — this switch
        // only picks which glyph represents the priority `state.glyph`
        // already carries.
        switch state.glyph {
        case .waiting:
            drawGlyphText(
                "!",
                center: m.emblemCenter,
                size: m.emblemFontSize * m.waitingBangScale,
                weight: .heavy,
                color: glyphColor
            )
        case .working(let frame):
            let glyph = GlyphCycleSpinner.glyphs[frame % GlyphCycleSpinner.glyphs.count]
            drawGlyphText(glyph, center: m.emblemCenter, size: m.emblemFontSize, weight: .regular, color: glyphColor)
        case .idle, .none:
            drawGlyphText(m.emblemText, center: m.emblemCenter, size: m.emblemFontSize, weight: .regular, color: glyphColor)
        }

        // 3. Red badge + halo (non-template variant only; also dimmed,
        // since the whole tray grays out together, menubar-design.html).
        // Unchanged by M24 T1.
        if state.hasUnreviewedDot {
            let badgeRect = NSRect(
                x: m.badgeCenter.x - m.badgeRadius,
                y: m.badgeCenter.y - m.badgeRadius,
                width: m.badgeRadius * 2,
                height: m.badgeRadius * 2
            )
            let badge = NSBezierPath(ovalIn: badgeRect)
            m.badgeColor.withAlphaComponent(m.badgeColor.alphaComponent * dim).setFill()
            badge.fill()
            let halo = NSBezierPath(ovalIn: badgeRect)
            halo.lineWidth = m.haloLineWidth
            m.haloColor.withAlphaComponent(m.haloColor.alphaComponent * dim).setStroke()
            halo.stroke()
        }
    }

    private static func drawGlyphText(_ text: String, center: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let bounds = string.size()
        string.draw(at: NSPoint(
            x: center.x - bounds.width / 2,
            y: center.y - bounds.height / 2
        ))
    }
}
