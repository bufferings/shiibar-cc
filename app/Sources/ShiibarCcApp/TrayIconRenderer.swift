// AppKit renderer for the tray icon (the tray section of menubar-design.html,
// DESIGN.md §4.5 / M5.md T8's final geometry): draws the rounded window
// frame + ✳ emblem + rolled-up status indicator (+ red unreviewed dot) into
// an NSImage, redrawn on every state change (and, only while the rollup
// shows `working`, on every animation tick — see `TrayIconAnimator`).
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
// the M5 T8 redesign:
//   - no dot   -> ONE template image (glyph only). Auto-tints to the menu
//                 bar's foreground color; the dim level is baked into the
//                 alpha channel, which template rendering preserves.
//   - dot      -> ONE non-template image: glyph drawn in a light/dark
//                 appearance-matched monochrome + red dot with its light
//                 halo. This is the spec's sanctioned fallback
//                 (appearance-observed non-template compositing).
//
// `✳` is the plain U+2733 EIGHT SPOKED ASTERISK character, forced to text
// presentation (trailing U+FE0E) so it never renders as a colored emoji
// glyph — it must not be reshaped toward the Anthropic sunburst logo
// either. All geometry lives in `TrayIconMetrics` below — single place to
// tweak after looking at the real menu bar (M5.md T8: stroke weights,
// animation cadence (400-800ms) and faint-dot opacity (25-40%) are subject
// to on-device tuning; the values here are M5.md's specified starting
// point, not yet on-device-confirmed).
//
// Coordinates are y-up (CoreGraphics/AppKit convention, `flipped: false`
// below) — menubar-design.html's SVG mock shows the same shape y-flipped
// (M5.md T8).

import AppKit
import ShiibarCcCore

/// Every tunable constant for the tray drawing, in points, on a y-up canvas.
/// Values are M5.md T8's exact starting geometry for the final (✳ emblem +
/// frame) design.
enum TrayIconMetrics {
    static let canvasWidth: CGFloat = 20
    static let canvasHeight: CGFloat = 18

    // Full-height rounded window frame.
    static let frameRect = NSRect(x: 0.8, y: 0.8, width: 16, height: 16.2)
    static let frameCornerRadius: CGFloat = 3.5
    static let frameLineWidth: CGFloat = 1.4

    // ✳ emblem, top-left (plain U+2733, forced text presentation).
    static let emblemText = "\u{2733}\u{FE0E}"
    static let emblemCenter = NSPoint(x: 5.4, y: 11.4)
    static let emblemFontSize: CGFloat = 9.5

    // Status indicator, bottom-right. `waiting` and the working dots share
    // the same horizontal center as the mock.
    static let statusCenterX: CGFloat = 12

    static let waitingCenter = NSPoint(x: 12, y: 8.6)
    static let waitingFontSize: CGFloat = 10.5

    // Working: 3 dots on one row, lighting up left-to-right across the
    // 4-frame cycle (frame 0 = all faint, frame N = the first N lit; §9:
    // 500ms/frame).
    static let workingDotY: CGFloat = 5.0
    static let workingDotDx: CGFloat = 2.4
    static let workingDotRadius: CGFloat = 1.05
    static let workingDotFaintAlpha: CGFloat = 0.3

    // Red unreviewed dot, overhanging the frame's top-right corner, with a
    // light halo ring always drawn (invisible on light bars by design).
    static let dotCenter = NSPoint(x: 16.2, y: 15.2)
    static let dotRadius: CGFloat = 2.2
    static let haloLineWidth: CGFloat = 0.8
    static let dotColor = NSColor(srgbRed: 0.95, green: 0.30, blue: 0.32, alpha: 1)
    static let haloColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85)

    // Glyph monochrome for the non-template (dot) variant.
    static let lightAppearanceGlyph = NSColor.black.withAlphaComponent(0.9)
    static let darkAppearanceGlyph = NSColor.white.withAlphaComponent(0.95)
}

enum TrayIconRenderer {
    /// Render the tray image for `state`. `darkMenuBar` only matters for
    /// the non-template (dot) variant; the template variant tints itself.
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

        // 2. ✳ emblem — always drawn (dimmed with everything else); M5 T8
        // dropped the old ❯ prompt entirely.
        drawGlyphText(m.emblemText, center: m.emblemCenter, size: m.emblemFontSize, weight: .regular, color: glyphColor)

        // 3. Rolled-up status indicator, bottom-right. `idle`/`none` carry
        // no extra glyph at all now (M5 T8 dropped the idle `_` underscore
        // too) — they differ from each other only in `state.dim`.
        switch state.glyph {
        case .waiting:
            drawGlyphText("!", center: m.waitingCenter, size: m.waitingFontSize, weight: .bold, color: glyphColor)
        case .working(let frame):
            drawWorkingDots(litCount: frame, color: glyphColor)
        case .idle, .none:
            break
        }

        // 4. Red dot + halo (non-template variant only; also dimmed, since
        // the whole tray grays out together, menubar-design.html).
        if state.hasUnreviewedDot {
            let dotRect = NSRect(
                x: m.dotCenter.x - m.dotRadius,
                y: m.dotCenter.y - m.dotRadius,
                width: m.dotRadius * 2,
                height: m.dotRadius * 2
            )
            let dot = NSBezierPath(ovalIn: dotRect)
            m.dotColor.withAlphaComponent(m.dotColor.alphaComponent * dim).setFill()
            dot.fill()
            let halo = NSBezierPath(ovalIn: dotRect)
            halo.lineWidth = m.haloLineWidth
            m.haloColor.withAlphaComponent(m.haloColor.alphaComponent * dim).setStroke()
            halo.stroke()
        }
    }

    /// Draw the 3-dot working indicator: the leftmost `litCount` dots at
    /// full (already-dimmed) opacity, the rest at `workingDotFaintAlpha` of
    /// that (M5 T8: "all-faint -> 1 lit -> 2 lit -> 3 lit").
    private static func drawWorkingDots(litCount: Int, color: NSColor) {
        let m = TrayIconMetrics.self
        let xPositions = [
            m.statusCenterX - m.workingDotDx,
            m.statusCenterX,
            m.statusCenterX + m.workingDotDx,
        ]
        for (index, x) in xPositions.enumerated() {
            let lit = index < litCount
            let dotColor = lit ? color : color.withAlphaComponent(color.alphaComponent * m.workingDotFaintAlpha)
            let rect = NSRect(
                x: x - m.workingDotRadius,
                y: m.workingDotY - m.workingDotRadius,
                width: m.workingDotRadius * 2,
                height: m.workingDotRadius * 2
            )
            dotColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
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
