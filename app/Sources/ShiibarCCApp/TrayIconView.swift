// Tray icon rendering (the tray section of menubar-design.html): the shared
// window glyph (`WindowGlyphView`: rounded window + ❯ + status character),
// two-layer composited — the glyph renders as ordinary SwiftUI content
// inside the `MenuBarExtra` label (which NSStatusItem automatically tints
// to match the menu bar's foreground color, the same effect a template
// NSImage gets), with the red unreviewed dot drawn as a literal
// (non-tinted) color overhanging the top-right corner, with a light halo
// ring (menubar-design.html: halo always drawn; invisible on light bars by
// design, since a template image can't know the bar color).
//
// The dim level applies to the WHOLE composition, red dot included
// (menubar-design.html: while disconnected the entire tray grays out).

import ShiibarCCCore
import SwiftUI

struct TrayIconView: View {
    let state: TrayIconState

    var body: some View {
        ZStack(alignment: .topTrailing) {
            WindowGlyphView(glyph: state.glyph, size: 16)
                .padding(.top, 2)

            if state.hasUnreviewedDot {
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                    )
                    .offset(x: 3, y: -2)
            }
        }
        .opacity(state.dim)
        .frame(width: 22, height: 18)
    }
}
