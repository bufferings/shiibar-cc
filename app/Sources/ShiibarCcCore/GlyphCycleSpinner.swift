// The Claude Code TUI's own working-glyph cycle (DESIGN.md §9, M22 brief,
// read from claude CLI 2.1.204): frames `· ✢ ✳ ✶ ✻ ✽`, selected by a
// cosine-eased sweep over clock time. The Running row symbol
// (`RowSymbolView`) is the only user of this cycle; the tray shows a
// static working image (`TrayIconRenderer`).
//
// The row symbol hands the switching to a Core Animation keyframe
// animation so that no main-thread redraw runs per frame (DESIGN.md §4.5
// "updates while visible", §8.57). `keyframes` is the pure description of
// one period that animation plays: the times at which the formula's value
// changes and the frame shown in each interval.

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

    /// Frame index (0..<glyphs.count) at `t` seconds on a clock shared by
    /// every caller in the process (so all rows stay in phase) — the
    /// formula `round((1 - cos(2*pi*t/period)) / 2 * (count-1))`
    /// (DESIGN.md §9): a cosine sweep that dwells on the first and last
    /// glyphs and passes quickly through the middle ones (NOT uniform
    /// stepping).
    public static func frameIndex(atReferenceTime t: TimeInterval) -> Int {
        let eased = (1 - cos(2 * .pi * t / periodSeconds)) / 2
        return Int((eased * Double(glyphs.count - 1)).rounded())
    }

    /// The glyph at `t` seconds — see `frameIndex(atReferenceTime:)`.
    public static func glyph(atReferenceTime t: TimeInterval) -> String {
        glyphs[frameIndex(atReferenceTime: t)]
    }

    /// One period of the cycle as discrete keyframes, in the shape a
    /// discrete `CAKeyframeAnimation` takes: `keyTimes` are fractions of
    /// the period, start at 0, end at 1, and have one more entry than
    /// `frameIndices`; interval `i` (from `keyTimes[i]` up to
    /// `keyTimes[i + 1]`) shows `frameIndices[i]`. Every inner key time is
    /// an instant at which `frameIndex(atReferenceTime:)` changes value,
    /// so the animation switches exactly when the formula does
    /// (DESIGN.md §9).
    public struct Keyframes: Equatable, Sendable {
        public let keyTimes: [Double]
        public let frameIndices: [Int]
    }

    /// See `Keyframes`. The period starts at a multiple of `periodSeconds`
    /// (formula value 0, the first glyph).
    public static let keyframes: Keyframes = {
        let steps = glyphs.count - 1
        // Rising half: the rounded value goes from k to k + 1 where the
        // eased value crosses (k + 0.5) / steps, i.e. at
        // t = period / (2 pi) * acos(1 - 2 (k + 0.5) / steps).
        let rising: [Double] = (0..<steps).map { k in
            let eased = (Double(k) + 0.5) / Double(steps)
            return acos(1 - 2 * eased) / (2 * .pi)
        }
        // Falling half: the cosine is symmetric about half a period.
        let falling = rising.reversed().map { 1 - $0 }
        let keyTimes = [0] + rising + falling + [1]
        let frameIndices = Array(0...steps) + Array((0..<steps).reversed())
        return Keyframes(keyTimes: keyTimes, frameIndices: frameIndices)
    }()

    /// The start of the period that contains `t` (the largest multiple of
    /// `periodSeconds` not after `t`). Anchoring every row's animation to
    /// this instant on the shared clock keeps all rows in phase, including
    /// a row that appears later.
    public static func periodStart(atOrBefore t: TimeInterval) -> TimeInterval {
        (t / periodSeconds).rounded(.down) * periodSeconds
    }
}
