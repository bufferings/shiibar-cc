// Tray icon rendering (menubar-design.html "トレイ"): rounded window + ❯ +
// status glyph, two-layer composited — the window/prompt/glyph render as
// ordinary SwiftUI content inside the `MenuBarExtra` label (which NSStatusItem
// automatically tints to match the menu bar's foreground color, the same
// effect a template NSImage gets), with the red unreviewed dot drawn as a
// literal (non-tinted) color on top. See the M4 completion report for why
// this was chosen over manual NSImage template compositing.
//
// `✳` here is the plain U+2733 EIGHT SPOKED ASTERISK character (task brief
// M4 / menubar-design.html: must not be reshaped into the Anthropic
// sunburst logo).

import ShiibarCCCore
import SwiftUI

struct TrayIconView: View {
    let state: TrayIconState

    private var glyphText: String {
        switch state.glyph {
        case .waiting: return "!"
        case .working: return "\u{2733}" // ✳ EIGHT SPOKED ASTERISK
        case .idle: return "_"
        case .none: return ""
        }
    }

    private var glyphWeight: Font.Weight {
        switch state.glyph {
        case .waiting: return .bold
        case .working: return .regular
        case .idle: return .light
        case .none: return .regular
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 1) {
                Text("\u{276F}") // ❯
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                if !glyphText.isEmpty {
                    Text(glyphText)
                        .font(.system(size: 11, weight: glyphWeight, design: .monospaced))
                }
            }
            .opacity(state.dim)

            if state.hasUnreviewedDot {
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                    )
                    .offset(x: 4, y: -4)
            }
        }
        .frame(width: 26, height: 16)
    }
}
