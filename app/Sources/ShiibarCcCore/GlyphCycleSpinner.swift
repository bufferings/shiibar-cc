// The Claude Code TUI's own working-glyph cycle (DESIGN.md §9, M22 brief,
// read from claude CLI 2.1.204): frames `· ✢ ✳ ✶ ✻ ✽`, selected by a
// cosine-eased sweep over wall-clock time. Shared by every "working"
// indicator in the app — the dropdown row symbol (`RowSymbolView`) and the
// tray emblem slot (`TrayIconRenderer`, M24 T1) — so they always show the
// same frame at the same instant instead of drifting apart.

import Foundation

public enum GlyphCycleSpinner {
    /// Frames, each forced to text presentation (trailing U+FE0E) so none
    /// render as a colored emoji glyph.
    public static let glyphs: [String] = [
        "\u{00B7}\u{FE0E}", // ·
        "\u{2722}\u{FE0E}", // ✢
        "\u{2733}\u{FE0E}", // ✳
        "\u{2736}\u{FE0E}", // ✶
        "\u{273B}\u{FE0E}", // ✻
        "\u{273D}\u{FE0E}", // ✽
    ]

    /// Cosine-eased cycle period (DESIGN.md §9: 2 seconds, the TUI's own
    /// rhythm).
    public static let periodSeconds: TimeInterval = 2.0

    /// Redraw tick interval while spinning (DESIGN.md §9: 50ms — fine enough
    /// to catch the fast mid-sweep frame changes of the cosine easing
    /// below).
    public static let tickIntervalSeconds: TimeInterval = 0.05

    /// Frame index (0..<glyphs.count) at `t` seconds on some monotonic
    /// clock (callers pass `Date.timeIntervalSinceReferenceDate` so every
    /// caller in the process stays in phase for free) — the brief's formula
    /// `round((1 - cos(2*pi*t/period)) / 2 * (count-1))`: a cosine sweep
    /// that dwells on the first and last glyphs and passes quickly through
    /// the middle ones (NOT uniform stepping).
    public static func frameIndex(atReferenceTime t: TimeInterval) -> Int {
        let eased = (1 - cos(2 * .pi * t / periodSeconds)) / 2
        return Int((eased * Double(glyphs.count - 1)).rounded())
    }

    /// The glyph at `t` seconds — see `frameIndex(atReferenceTime:)`.
    public static func glyph(atReferenceTime t: TimeInterval) -> String {
        glyphs[frameIndex(atReferenceTime: t)]
    }
}
