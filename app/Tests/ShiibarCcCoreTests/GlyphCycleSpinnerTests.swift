import XCTest
@testable import ShiibarCcCore

final class GlyphCycleSpinnerTests: XCTestCase {
    func testSixFramesInTheTUIsOwnOrder() {
        // DESIGN.md §9 / M22 brief: · ✢ ✳ ✶ ✻ ✽, read from claude CLI
        // 2.1.204, each forced to text presentation with U+FE0E.
        XCTAssertEqual(GlyphCycleSpinner.glyphs, [
            "\u{00B7}\u{FE0E}",
            "\u{2722}\u{FE0E}",
            "\u{2733}\u{FE0E}",
            "\u{2736}\u{FE0E}",
            "\u{273B}\u{FE0E}",
            "\u{273D}\u{FE0E}",
        ])
    }

    func testFrameZeroAtTheStartOfThePeriod() {
        // t=0: cos(0)=1, eased=0 -> the first glyph.
        XCTAssertEqual(GlyphCycleSpinner.frameIndex(atReferenceTime: 0), 0)
    }

    func testFrameZeroAgainAtOnePeriodLater() {
        // The cycle repeats every `periodSeconds` (DESIGN.md §9: 2s).
        XCTAssertEqual(GlyphCycleSpinner.frameIndex(atReferenceTime: GlyphCycleSpinner.periodSeconds), 0)
    }

    func testLastFrameAtHalfAPeriod() {
        // t=period/2: cos(pi)=-1, eased=1 -> the last glyph. The cosine
        // easing dwells on the endpoints and sweeps quickly through the
        // middle (M22 brief) rather than stepping uniformly.
        let halfPeriod = GlyphCycleSpinner.periodSeconds / 2
        XCTAssertEqual(GlyphCycleSpinner.frameIndex(atReferenceTime: halfPeriod), GlyphCycleSpinner.glyphs.count - 1)
    }

    func testGlyphAtReferenceTimeIndexesIntoGlyphs() {
        XCTAssertEqual(GlyphCycleSpinner.glyph(atReferenceTime: 0), GlyphCycleSpinner.glyphs[0])
    }

    func testFrameIndexStaysInBoundsAcrossASweptRangeOfTimes() {
        // A cheap sanity check that the formula never rounds outside the
        // array — every reader (RowSymbolView, TrayIconRenderer) indexes
        // straight into `glyphs` with this value.
        var t: TimeInterval = 0
        while t < GlyphCycleSpinner.periodSeconds * 3 {
            let index = GlyphCycleSpinner.frameIndex(atReferenceTime: t)
            XCTAssertTrue((0..<GlyphCycleSpinner.glyphs.count).contains(index), "index \(index) out of bounds at t=\(t)")
            t += 0.01
        }
    }
}
