// AppKit renderer for the tray icon (the tray section of menubar-design.html,
// DESIGN.md §4.5): draws the rounded window + ❯ + rolled-up status character
// (+ red unreviewed dot) into an NSImage, redrawn on every state change.
//
// Why an NSImage and not composed SwiftUI views: the MenuBarExtra label is
// not a normal rendering context. On-device it dropped Shape strokes and
// flattened the custom text layout to a bare menu-bar-styled "❯" (while the
// identical view rendered fine inside the dropdown window). DESIGN.md §4.5
// prescribes exactly this approach for the tray ("render by NSImage
// compositing, redrawn per state change"); a plain `Image` is the reliably
// supported label content.
//
// Two-layer rule (menubar-design.html implementation notes): a single
// template image would erase the red dot (template rendering keeps only the
// alpha channel), and a SwiftUI overlay is the kind of shape the label just
// demonstrated it drops. So:
//   - no dot   -> ONE template image (glyph only). Auto-tints to the menu
//                 bar's foreground color; the dim level is baked into the
//                 alpha channel, which template rendering preserves.
//   - dot      -> ONE non-template image: glyph drawn in a light/dark
//                 appearance-matched monochrome + red dot with its light
//                 halo. This is the spec's sanctioned fallback
//                 (appearance-observed non-template compositing).
//
// `✳` is the plain U+2733 EIGHT SPOKED ASTERISK character (must not be
// reshaped toward the Anthropic sunburst logo). All geometry lives in
// `TrayIconMetrics` below — single place to tweak after looking at the real
// menu bar (menubar-design.html: stroke weights/spacing are finalized
// on-device).

import AppKit
import ShiibarCCCore

/// Every tunable constant for the tray drawing, in points, on a y-up canvas.
/// Derived from the mock's 16x16 viewBox (window rect (1.2,1.8) 13.6x12.4
/// r3, prompt polyline (3.1,5.5)-(5.7,8)-(3.1,10.5) width 2, dot at
/// (14.2,2.3) r2) scaled ~1.1x, y-flipped, with head-room for the dot
/// overhang.
enum TrayIconMetrics {
    static let canvasWidth: CGFloat = 20
    static let canvasHeight: CGFloat = 18

    // Rounded window frame.
    static let frameRect = NSRect(x: 1.0, y: 1.0, width: 15.0, height: 13.5)
    static let frameCornerRadius: CGFloat = 3.2
    static let frameLineWidth: CGFloat = 1.3

    // Prompt ❯ (drawn as a path, not text — the mock's two-segment chevron).
    static let promptPoints: [NSPoint] = [
        NSPoint(x: 3.4, y: 11.0),
        NSPoint(x: 6.2, y: 7.75),
        NSPoint(x: 3.4, y: 4.5),
    ]
    static let promptLineWidth: CGFloat = 2.0

    // Status character (text glyphs, centered right of the prompt).
    static let statusCenter = NSPoint(x: 11.4, y: 7.75)
    /// Optical vertical correction for text glyphs; tune on-device.
    static let statusYOffset: CGFloat = 0
    static let waitingFontSize: CGFloat = 9
    static let workingFontSize: CGFloat = 8.5

    // Idle `_` (drawn as a low horizontal line, like the mock, rather than
    // a text underscore whose vertical position is font-dependent).
    static let idleLineFrom = NSPoint(x: 9.2, y: 4.6)
    static let idleLineTo = NSPoint(x: 13.2, y: 4.6)
    static let idleLineWidth: CGFloat = 1.3

    // Red unreviewed dot, overhanging the frame's top-right corner, with a
    // light halo ring always drawn (invisible on light bars by design).
    static let dotCenter = NSPoint(x: 16.6, y: 15.2)
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

        // 2. Prompt ❯.
        let prompt = NSBezierPath()
        prompt.lineWidth = m.promptLineWidth
        prompt.lineCapStyle = .round
        prompt.lineJoinStyle = .round
        prompt.move(to: m.promptPoints[0])
        for point in m.promptPoints.dropFirst() {
            prompt.line(to: point)
        }
        prompt.stroke()

        // 3. Rolled-up status character.
        switch state.glyph {
        case .waiting:
            drawStatusText("!", size: m.waitingFontSize, weight: .bold, color: glyphColor)
        case .working:
            drawStatusText("\u{2733}", size: m.workingFontSize, weight: .regular, color: glyphColor)
        case .idle:
            let line = NSBezierPath()
            line.lineWidth = m.idleLineWidth
            line.lineCapStyle = .round
            line.move(to: m.idleLineFrom)
            line.line(to: m.idleLineTo)
            line.stroke()
        case .none:
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

    private static func drawStatusText(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let m = TrayIconMetrics.self
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let bounds = string.size()
        string.draw(at: NSPoint(
            x: m.statusCenter.x - bounds.width / 2,
            y: m.statusCenter.y - bounds.height / 2 + m.statusYOffset
        ))
    }
}
