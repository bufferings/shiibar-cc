// Dropdown row leading status symbol (menubar-design.html's dropdown
// section, DESIGN.md §3.1/§4.5, M22): dim static ✻ = idle / glyph-cycle
// spinner at full opacity = working (the Claude Code TUI's own
// · ✢ ✳ ✶ ✻ ✽ cycle — the "blinking Claude" counterpart of the still,
// dim idle ✻) / outlined speech bubble + bold "!" = waiting. Unreviewed
// rows get a red badge (with a light halo, same two-layer idea as the
// tray's unreviewed dot) on the symbol's top-right shoulder, REPLACING the
// old row-right red dot entirely.
//
// M22 replaced the original M5 geometry (empty circle / circle+"!" /
// rotating open-arc spinner) with the ✻ / bubble-! vocabulary — see
// menubar-design.html's dropdown mock SVGs, the source of the glyph and
// path coordinates below.
//
// Unlike the tray (`TrayIconRenderer`, which needs NSImage compositing
// because the MenuBarExtra label drops SwiftUI shapes), SwiftUI shapes
// render correctly inside the dropdown's own window.
//
// `AgentStatus -> RowSymbolKind` selection is the pure, tested part
// (`RowSymbol` in ShiibarCcCore); this view is purely the drawing.

import ShiibarCcCore
import SwiftUI

struct RowSymbolView: View {
    let kind: RowSymbolKind
    let unreviewed: Bool
    /// Only `true` while both the dropdown is open AND this row is
    /// `.working` (menubar-design.html: "the spinner cycles only while the
    /// dropdown is open" — callers gate this, this view just obeys it).
    var spinning: Bool = false
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            symbolBody
                .frame(width: size, height: size)
            if unreviewed {
                badge
                    .offset(x: size * 0.32, y: -size * 0.32)
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var symbolBody: some View {
        switch kind {
        case .idle:
            // Static, dim (mock: fill-opacity 0.5) — the "still Claude"
            // counterpart of the working glyph-cycle spinner.
            statusGlyph("\u{273B}\u{FE0E}")
                .foregroundStyle(Color.primary.opacity(0.5))
        case .waiting:
            ZStack {
                SpeechBubbleShape()
                    .stroke(Color.primary, style: StrokeStyle(lineWidth: size * Self.waitingLineWidthRatio, lineJoin: .round))
                Text("!")
                    .font(.system(size: size * Self.waitingBangSizeRatio, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.primary)
            }
        case .working:
            // Glyph-cycle spinner at full opacity, same frame size as the
            // idle ✻. Clock-driven frames (TimelineView) instead of a
            // repeat-forever animation or a Timer: SwiftUI cancels
            // in-flight implicit animations when the row's frame changes
            // (e.g. a sort-mode switch reorders the list), which froze the
            // old arc spinner. Deriving the frame from wall-clock time has
            // no animation state to cancel — and all rows stay in phase
            // for free. 50ms ticks are enough to catch the fast mid-sweep
            // frame changes of the cosine easing below.
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !spinning)) { context in
                statusGlyph(Self.workingGlyph(at: context.date))
                    .foregroundStyle(Color.primary)
            }
        }
    }

    /// One status glyph (the idle ✻ or a working spinner frame) at the
    /// shared glyph size — idle and working differ only in opacity and
    /// motion. Every glyph string carries a trailing U+FE0E (VARIATION
    /// SELECTOR-15) forcing text presentation so it renders as the plain
    /// glyph instead of a colored emoji — same technique as the tray's ✳
    /// emblem (TrayIconRenderer.emblemText). Verify on-device (T2) that
    /// none of them turn into a color glyph.
    private func statusGlyph(_ glyph: String) -> some View {
        Text(glyph)
            .font(.system(size: size * Self.glyphSizeRatio))
    }

    /// menubar-design.html row mock: ✻ font-size 15.5 on a 20-unit box
    /// (the brief's 15-16px-at-20px range). Starting value only; the three
    /// symbols' optical weight wants a final on-device pass, same idea as
    /// `TrayIconMetrics`. If the smaller-faced spinner frames (✳ ✶)
    /// visibly shrink mid-cycle on device, a per-frame scale table is the
    /// sanctioned fix (M22 brief) — left uniform until the owner judges.
    private static let glyphSizeRatio: CGFloat = 15.5 / 20
    /// menubar-design.html waiting mock: stroke-width 1.7 on a 20-unit box.
    private static let waitingLineWidthRatio: CGFloat = 1.7 / 20
    /// menubar-design.html waiting mock: "!" font-size 10.5 on a 20-unit box.
    private static let waitingBangSizeRatio: CGFloat = 10.5 / 20

    /// Working spinner frames — the Claude Code TUI's own glyph cycle
    /// (M22 brief, read from claude CLI 2.1.204), each forced to text
    /// presentation with U+FE0E.
    private static let workingGlyphs: [String] = [
        "\u{00B7}\u{FE0E}", // ·
        "\u{2722}\u{FE0E}", // ✢
        "\u{2733}\u{FE0E}", // ✳
        "\u{2736}\u{FE0E}", // ✶
        "\u{273B}\u{FE0E}", // ✻
        "\u{273D}\u{FE0E}", // ✽
    ]

    /// Spinner cycle period (M22 brief: the TUI's 2-second cosine easing).
    private static let workingPeriod: TimeInterval = 2.0

    /// Frame for the working spinner at `date`: the brief's formula
    /// `round((1 - cos(2*pi*t/2)) / 2 * 5)` — a cosine sweep that dwells
    /// on the first and last glyphs and passes quickly through the middle
    /// ones (NOT uniform stepping). Phase is shared by every working row
    /// because the frame is a pure function of wall-clock time.
    static func workingGlyph(at date: Date) -> String {
        let t = date.timeIntervalSinceReferenceDate
        let eased = (1 - cos(2 * .pi * t / workingPeriod)) / 2
        let index = Int((eased * Double(workingGlyphs.count - 1)).rounded())
        return workingGlyphs[index]
    }

    private var badge: some View {
        ZStack {
            Circle().fill(Color.red)
            Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1)
        }
        .frame(width: size * 0.44, height: size * 0.44)
    }
}

/// Outlined speech-bubble tail-down-left path, traced from
/// menubar-design.html's waiting mock SVG path (a 20-unit-box rounded rect,
/// corner radius 2.6, with the bottom-left corner replaced by a tail down
/// to (5.1, 18.4)). The mock's own tiny tail-tip rounding (r 0.62) is
/// approximated here by the stroke's round line join rather than a fifth
/// arc — close enough at row-symbol scale; a starting point per the M22
/// brief, not a pixel-exact trace.
private struct SpeechBubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 20
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }
        let r = 2.6 * scale

        var path = Path()
        path.move(to: p(3.2, 1.6))
        path.addLine(to: p(16.8, 1.6))
        // Top-right corner.
        path.addRelativeArc(center: p(16.8, 4.2), radius: r, startAngle: .degrees(-90), delta: .degrees(90))
        path.addLine(to: p(19.4, 12.4))
        // Bottom-right corner.
        path.addRelativeArc(center: p(16.8, 12.4), radius: r, startAngle: .degrees(0), delta: .degrees(90))
        path.addLine(to: p(8.7, 15.0))
        // Tail, down to the tip and back up to the bottom-left corner.
        path.addLine(to: p(5.1, 18.4))
        path.addLine(to: p(4.05, 15.0))
        path.addLine(to: p(3.2, 15.0))
        // Bottom-left corner.
        path.addRelativeArc(center: p(3.2, 12.4), radius: r, startAngle: .degrees(90), delta: .degrees(90))
        path.addLine(to: p(0.6, 4.2))
        // Top-left corner, closing back to the start point.
        path.addRelativeArc(center: p(3.2, 4.2), radius: r, startAngle: .degrees(180), delta: .degrees(90))
        path.closeSubpath()
        return path
    }
}
