// The shared "terminal window" glyph (menubar-design.html): a rounded
// line-drawn window frame + bold prompt ❯ + a status character. Used at
// two sizes — the tray icon (with the red unreviewed dot overlaid by
// `TrayIconView`) and the dropdown group headers (~24px per the mock).
// Factoring it here keeps the tray and the headers the same shape, as the
// design requires ("group heading: window icon of the same shape as the
// tray").
//
// `✳` is the plain U+2733 EIGHT SPOKED ASTERISK character (menubar-design.html
// implementation notes: must not be reshaped into the Anthropic sunburst
// logo). Exact stroke weights/spacing are subject to on-device (Retina)
// tuning per the same notes.

import ShiibarCCCore
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
