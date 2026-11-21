// AppKit renderer for the tray icon (the tray section of menubar-design.html,
// DESIGN.md §4.5 / M24 T1's "window + one glyph" geometry): draws the
// rounded window frame + one emblem-slot glyph (+ three dots while
// working, + the corner dot: orange while a session is waiting, else the
// accent color while one is unreviewed) into an NSImage, redrawn when what
// it depicts changes.
// Every state, `working` included, is a static image: each change of the
// status item's image makes AppKit re-snapshot the status item on the main
// thread at a fixed cost, so an animated icon would use CPU for as long as
// any session is working.
//
// Why an NSImage and not composed SwiftUI views: the MenuBarExtra label is
// not a normal rendering context. On-device it dropped Shape strokes and
// flattened the custom text layout to a bare menu-bar-styled glyph (while
// the identical view rendered fine inside a normal window). DESIGN.md
// §4.5 prescribes exactly this approach for the tray ("render by NSImage
// compositing, redrawn per state change"); a plain `Image` is the reliably
// supported label content.
//
// Two-layer rule (menubar-design.html implementation notes):
//   - no dot -> ONE template image (glyph only). Auto-tints to the menu
//               bar's foreground color; the dim level is baked into the
//               alpha channel, which template rendering preserves.
//   - dot    -> ONE non-template image: glyph drawn in a light/dark
//               appearance-matched monochrome + the colored dot with its
//               light halo. This is the spec's sanctioned fallback
//               (appearance-observed non-template compositing).
//
// The dot's color (`systemOrange` or `controlAccentColor`) arrives already
// resolved to sRGB components against the status item button's appearance
// (`TrayDotColor.resolve`): the drawing handler runs under whatever
// appearance is current when AppKit draws the image, so a dynamic color
// must not be resolved inside it (DESIGN.md §4.5 "visual source of
// truth").
//
// The emblem slot holds one glyph (top-left, x 6.4): idle/none show the static `✻` (plain U+273B, forced to text
// presentation with trailing U+FE0E so it never renders as a colored emoji
// glyph — it must not be reshaped toward the Anthropic sunburst logo
// either); working keeps the same static ✻ and adds three small filled
// dots below it; waiting swaps in a bold "!" at ~1.1x the emblem size.
// The emblem-slot glyph and the presence of the dots together show the
// rollup. All geometry lives in `TrayIconMetrics` below — single place to
// tweak after looking at the real menu bar. `emblemFontSize` is a starting
// point (M24 brief: 9.5, legibility outranks the exact number — bump back
// toward 10.5 on-device if the ✻ petals collapse on a real Retina menu
// bar).
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
    // idle/none/working draw the static ✻ (plain U+273B, forced text
    // presentation), waiting swaps in a bold "!" at `waitingBangScale`
    // times this size.
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

    // Working dots: three filled circles in a row below the ✻, drawn in
    // the same color as the frame and emblem. They are static, like every
    // other tray state, because each status-item image change has a fixed
    // AppKit cost.
    static let workingDotCenters = [
        NSPoint(x: 5.0, y: 4.0),
        NSPoint(x: 8.8, y: 4.0),
        NSPoint(x: 12.6, y: 4.0),
    ]
    static let workingDotRadius: CGFloat = 0.9

    // The corner dot, overhanging the frame's top-right corner, with a
    // light halo ring always drawn (invisible on light bars by design). The
    // position and size are the same for both colors. Radius 3.6: r 2.2 is
    // too small to register next to real menu bar neighbors. The center is
    // pulled slightly inward so dot + halo still fit the 18pt canvas.
    static let dotCenter = NSPoint(x: 15.6, y: 13.9)
    static let dotRadius: CGFloat = 3.6
    static let haloLineWidth: CGFloat = 0.9
    static let haloColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85)

    // Glyph monochrome for the non-template (dot) variant.
    static let lightAppearanceGlyph = NSColor.black.withAlphaComponent(0.9)
    static let darkAppearanceGlyph = NSColor.white.withAlphaComponent(0.95)
}

enum TrayIconRenderer {
    /// Render the tray image for `state`. `dotColor` is the corner dot's
    /// color, already resolved (nil = no dot: a template image).
    /// `darkMenuBar` only matters for the non-template (dot) variant; the
    /// template variant tints itself.
    static func render(state: TrayIconState, darkMenuBar: Bool, dotColor: ResolvedRGBA?) -> NSImage {
        let size = NSSize(width: TrayIconMetrics.canvasWidth, height: TrayIconMetrics.canvasHeight)
        let image = NSImage(size: size, flipped: false) { _ in
            draw(state: state, darkMenuBar: darkMenuBar, dotColor: dotColor)
            return true
        }
        image.isTemplate = dotColor == nil
        return image
    }

    private static func draw(state: TrayIconState, darkMenuBar: Bool, dotColor: ResolvedRGBA?) {
        let m = TrayIconMetrics.self
        let dim = CGFloat(state.dim)

        // Template images carry meaning only in the alpha channel, so the
        // dim level is applied as alpha either way.
        let base: NSColor = dotColor != nil
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

        // 2. Emblem slot, plus the working dots: waiting swaps in a bold
        // "!", working shows the static ✻ plus three dots, idle/none show
        // the static ✻. Core's Rollup
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
        case .working:
            drawGlyphText(m.emblemText, center: m.emblemCenter, size: m.emblemFontSize, weight: .regular, color: glyphColor)
            glyphColor.setFill()
            for center in m.workingDotCenters {
                NSBezierPath(ovalIn: NSRect(
                    x: center.x - m.workingDotRadius,
                    y: center.y - m.workingDotRadius,
                    width: m.workingDotRadius * 2,
                    height: m.workingDotRadius * 2
                )).fill()
            }
        case .idle, .none:
            drawGlyphText(m.emblemText, center: m.emblemCenter, size: m.emblemFontSize, weight: .regular, color: glyphColor)
        }

        // 3. The corner dot + halo (non-template variant only; also dimmed,
        // since the whole tray grays out together, menubar-design.html).
        if let dotColor {
            let dotRect = NSRect(
                x: m.dotCenter.x - m.dotRadius,
                y: m.dotCenter.y - m.dotRadius,
                width: m.dotRadius * 2,
                height: m.dotRadius * 2
            )
            let dot = NSBezierPath(ovalIn: dotRect)
            NSColor(
                srgbRed: CGFloat(dotColor.red), green: CGFloat(dotColor.green), blue: CGFloat(dotColor.blue),
                alpha: CGFloat(dotColor.alpha) * dim
            ).setFill()
            dot.fill()
            let halo = NSBezierPath(ovalIn: dotRect)
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

/// The corner dot's color (DESIGN.md §4.5 "visual source of truth", §9
/// "state colors"): `systemOrange` for waiting, `controlAccentColor` for
/// unreviewed, resolved to sRGB components under the status item button's
/// appearance before the image is made.
enum TrayDotColor {
    static func nsColor(for dot: StateDot) -> NSColor {
        switch dot {
        case .waiting: return SurfaceColors.waitingNSColor
        case .unreviewed: return SurfaceColors.unreviewedNSColor
        }
    }

    /// The dot's color resolved under `appearance` (nil = no dot).
    static func resolve(_ dot: StateDot?, appearance: NSAppearance) -> ResolvedRGBA? {
        guard let dot else { return nil }
        var resolved: ResolvedRGBA?
        appearance.performAsCurrentDrawingAppearance {
            // `usingColorSpace` resolves a dynamic system color against the
            // current drawing appearance.
            if let srgb = nsColor(for: dot).usingColorSpace(.sRGB) {
                resolved = ResolvedRGBA(
                    red: Double(srgb.redComponent), green: Double(srgb.greenComponent),
                    blue: Double(srgb.blueComponent), alpha: Double(srgb.alphaComponent))
            }
        }
        return resolved
    }
}

/// Sets the status item button's image (DESIGN.md §4.5 "visual source of
/// truth", §8.51): only when what the image depicts — the state, whether
/// the menu bar is dark, and the dot's resolved color — differs from the
/// last image set. The dot color is resolved once per refresh and that same
/// value is compared and drawn. A change of the system colors (the accent
/// color setting, `NSColor.systemColorsDidChangeNotification`) refreshes
/// too, so the dot follows the new accent color.
@MainActor
final class TrayImageUpdater {
    typealias Render = (TrayIconState, Bool, ResolvedRGBA?) -> NSImage

    private let state: () -> TrayIconState
    private let appearance: () -> NSAppearance?
    private let setImage: (NSImage) -> Void
    private let resolve: (StateDot?, NSAppearance) -> ResolvedRGBA?
    private let render: Render
    private let center: NotificationCenter
    private var gate = TrayImageGate()
    private var systemColorsObserver: NSObjectProtocol?

    init(
        state: @escaping () -> TrayIconState,
        appearance: @escaping () -> NSAppearance?,
        setImage: @escaping (NSImage) -> Void,
        resolve: @escaping (StateDot?, NSAppearance) -> ResolvedRGBA? = TrayDotColor.resolve,
        render: @escaping Render = TrayIconRenderer.render,
        center: NotificationCenter = .default
    ) {
        self.state = state
        self.appearance = appearance
        self.setImage = setImage
        self.resolve = resolve
        self.render = render
        self.center = center
        // No queue: AppKit posts the notification on the main thread.
        systemColorsObserver = center.addObserver(
            forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let systemColorsObserver { center.removeObserver(systemColorsObserver) }
    }

    func refresh() {
        guard let appearance = appearance() else { return }
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let icon = state()
        let dotColor = resolve(icon.dot, appearance)
        // Assign only when the depicted state, the menu bar appearance or the
        // dot's color changed: setting the image schedules a replicant
        // redraw that sets the button's appearance and re-fires the
        // appearance observation, so an unconditional assignment never stops
        // redrawing.
        guard gate.shouldRender(state: icon, darkMenuBar: dark, dotColor: dotColor) else { return }
        setImage(render(icon, dark, dotColor))
    }
}
