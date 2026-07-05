// Dropdown row leading status symbol (menubar-design.html's dropdown
// section, DESIGN.md §4.5, M5 T9): empty circle (55% stroke) = idle / circle
// + bold "!" = waiting / rotating spinner (open arc, 1.7s/rev) =
// working. Unreviewed rows get a red badge (with a light halo, same
// two-layer idea as the tray's unreviewed dot) on the symbol's top-right
// shoulder, REPLACING the old row-right red dot entirely.
//
// Unlike the tray (`TrayIconRenderer`), SwiftUI shapes render correctly
// inside the dropdown's own window — see `WindowGlyphView`'s header comment
// for why the tray alone needs the NSImage-compositing workaround. This
// view mirrors that same "renders fine here" precedent.
//
// `AgentStatus -> RowSymbolKind` selection is the pure, tested part
// (`RowSymbol` in ShiibarCcCore); this view is purely the drawing.

import ShiibarCcCore
import SwiftUI

struct RowSymbolView: View {
    let kind: RowSymbolKind
    let unreviewed: Bool
    /// Only `true` while both the dropdown is open AND this row is
    /// `.working` (menubar-design.html: "the spinner turns only while the
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
            Circle()
                .strokeBorder(Color.primary.opacity(0.55), lineWidth: size * 0.095)
        case .waiting:
            ZStack {
                Circle().strokeBorder(lineWidth: size * 0.095)
                Text("!")
                    .font(.system(size: size * 0.56, weight: .heavy, design: .rounded))
            }
        case .working:
            SpinnerGlyph(lineWidth: size * 0.095)
                .rotationEffect(spinAngle)
                .animation(
                    spinning ? .linear(duration: 1.7).repeatForever(autoreverses: false) : .default,
                    value: spinning
                )
        }
    }

    /// `rotationEffect` needs a changing value to animate toward; toggling
    /// between 0 and a full turn with a linear repeat-forever animation
    /// (keyed on `spinning` above) reads as continuous rotation while
    /// `spinning` is true, and freezes in place the instant it flips false
    /// (no half-finished spin — matches "animates only while the dropdown
    /// is open").
    private var spinAngle: Angle {
        spinning ? .degrees(360) : .degrees(0)
    }

    private var badge: some View {
        ZStack {
            Circle().fill(Color.red)
            Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1)
        }
        .frame(width: size * 0.44, height: size * 0.44)
    }
}

/// The working spinner glyph: an open arc rotating as one unit (the gap
/// itself reads as motion; menubar-design.html).
private struct SpinnerGlyph: View {
    var lineWidth: CGFloat
    var body: some View {
        SpinnerArc(lineWidth: lineWidth)
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .foregroundStyle(.primary)
    }
}

/// ~250° open arc (the gap marks the leading end). The stroke's OUTER edge
/// fills the view frame, matching how the circle symbols use
/// `strokeBorder` — all three symbols share the same outer diameter.
private struct SpinnerArc: Shape {
    var lineWidth: CGFloat
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - lineWidth / 2
        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: .degrees(-90), endAngle: .degrees(160), clockwise: false)
        return path
    }
}

