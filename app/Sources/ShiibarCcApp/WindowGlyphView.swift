// The "Claude window" glyph for the dropdown group headers
// (menubar-design.html's Grouped mock, the `gic2` icons): the same design
// language as the tray — a rounded full window frame + small ✳ emblem
// top-left + the group's status marker bottom-right. Waiting = bold `!`,
// working = three dots (lit, lit, faint 35%), idle = nothing extra.
// Static, template-style drawing: no animation in headers (only the tray
// itself animates its working dots, via `TrayIconRenderer`).
//
// This SwiftUI version renders correctly inside the dropdown window; the
// tray itself cannot use it — the MenuBarExtra label drops Shape strokes
// and flattens text layout — so the tray draws the same design via
// `TrayIconRenderer` (NSImage) instead. Keep the two visually in sync when
// tuning either.
//
// `✳` is the plain U+2733 EIGHT SPOKED ASTERISK character, forced to text
// presentation (trailing U+FE0E), and must not be reshaped into the
// Anthropic sunburst logo (menubar-design.html implementation notes).
// Geometry mirrors the mock's 16x16 viewBox (y-down, same as SwiftUI):
// frame rect (1,1,14,14) r3 sw1.2, ✳ 7px centered at x 4.6 baseline 7.4,
// `!` 8.5px bold centered at x 10.6 baseline 12.6, dots cy 11.6 /
// cx 8.2, 10.8, 13.4 / r 0.95. Exact values are subject to on-device
// (Retina) tuning per the same notes.

import ShiibarCcCore
import SwiftUI

struct WindowGlyphView: View {
    let glyph: TrayGlyph
    /// Overall glyph width in points (the mock's viewBox is square).
    var size: CGFloat = 16

    /// One mock-viewBox unit (the SVG coordinates below are /16).
    private var unit: CGFloat { size / 16 }

    var body: some View {
        ZStack {
            // Window frame: mock rect (1,1,14,14) r3, stroke 1.2, centered
            // on the path — `.padding(unit)` insets the rect to x/y = 1.
            RoundedRectangle(cornerRadius: 3 * unit)
                .stroke(lineWidth: 1.2 * unit)
                .padding(unit)

            // ✳ emblem, top-left. The mock's <text> y is an alphabetic
            // baseline; SwiftUI positions the glyph's center, so the y here
            // is baseline minus ~half the cap height (optical, tuned to
            // match the mock).
            Text("\u{2733}\u{FE0E}")
                .font(.system(size: 7 * unit, design: .monospaced))
                .position(x: 4.6 * unit, y: 5.0 * unit)

            statusMarker
        }
        .frame(width: size, height: size)
    }

    /// Bottom-right status marker. `.idle` and `.none` draw nothing extra
    /// (frame + emblem only — same "no glyph for idle" rule as the tray's
    /// M5 T8 design). `.working`'s animation frame is ignored: headers are
    /// static, always showing the mock's lit/lit/faint pose.
    @ViewBuilder
    private var statusMarker: some View {
        switch glyph {
        case .waiting:
            Text("!")
                .font(.system(size: 8.5 * unit, weight: .bold, design: .monospaced))
                .position(x: 10.6 * unit, y: 9.6 * unit)
        case .working:
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill()
                    .opacity(index == 2 ? 0.35 : 1)
                    .frame(width: 1.9 * unit, height: 1.9 * unit)
                    .position(x: (8.2 + CGFloat(index) * 2.6) * unit, y: 11.6 * unit)
            }
        case .idle, .none:
            EmptyView()
        }
    }
}
