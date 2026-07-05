// The "terminal window" glyph for the dropdown group headers
// (menubar-design.html: a rounded line-drawn window frame + bold prompt ❯
// + the group's status character, ~24px, the same shape as the tray).
// This SwiftUI version renders correctly inside the dropdown window; the
// tray itself cannot use it — the MenuBarExtra label drops Shape strokes
// and flattens text layout — so the tray draws the same shape via
// `TrayIconRenderer` (NSImage) instead. Keep the two visually in sync when
// tuning either.
//
// `✳` is the plain U+2733 EIGHT SPOKED ASTERISK character (menubar-design.html
// implementation notes: must not be reshaped into the Anthropic sunburst
// logo). Exact stroke weights/spacing are subject to on-device (Retina)
// tuning per the same notes.

import ShiibarCcCore
import SwiftUI

struct WindowGlyphView: View {
    let glyph: TrayGlyph
    /// Overall glyph width in points (height follows the mock's 16:14 ratio).
    var size: CGFloat = 16

    private var glyphText: String {
        switch glyph {
        case .waiting: return "!"
        case .working: return "\u{2733}" // ✳ EIGHT SPOKED ASTERISK
        case .idle: return "_"
        case .none: return ""
        }
    }

    private var glyphWeight: Font.Weight {
        switch glyph {
        case .waiting: return .bold
        case .working: return .regular
        case .idle: return .light
        case .none: return .regular
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.19)
                .strokeBorder(lineWidth: max(1, size * 0.08))
            HStack(spacing: size * 0.04) {
                Text("\u{276F}") // ❯ — the prompt, kept toward the left edge
                    .font(.system(size: size * 0.42, weight: .bold, design: .monospaced))
                Text(glyphText.isEmpty ? " " : glyphText)
                    .font(.system(size: size * 0.40, weight: glyphWeight, design: .monospaced))
            }
        }
        .frame(width: size, height: size * 0.875)
    }
}
