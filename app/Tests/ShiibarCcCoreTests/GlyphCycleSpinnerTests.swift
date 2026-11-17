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
        // array — the spinner view indexes straight into
        // `glyphs` with this value.
        var t: TimeInterval = 0
        while t < GlyphCycleSpinner.periodSeconds * 3 {
            let index = GlyphCycleSpinner.frameIndex(atReferenceTime: t)
            XCTAssertTrue((0..<GlyphCycleSpinner.glyphs.count).contains(index), "index \(index) out of bounds at t=\(t)")
            t += 0.01
        }
    }

    // MARK: - Keyframes for the Core Animation spinner (DESIGN.md §4.5, §9)

    func testKeyframesHaveTheShapeADiscreteKeyframeAnimationRequires() {
        // A discrete CAKeyframeAnimation needs one more key time than
        // values, starting at 0 and ending at 1, in ascending order.
        let keyframes = GlyphCycleSpinner.keyframes
        XCTAssertEqual(keyframes.keyTimes.count, keyframes.frameIndices.count + 1)
        XCTAssertEqual(keyframes.keyTimes.first, 0)
        XCTAssertEqual(keyframes.keyTimes.last, 1)
        for i in 1..<keyframes.keyTimes.count {
            XCTAssertLessThan(keyframes.keyTimes[i - 1], keyframes.keyTimes[i], "key times must ascend at \(i)")
        }
        for index in keyframes.frameIndices {
            XCTAssertTrue((0..<GlyphCycleSpinner.glyphs.count).contains(index))
        }
    }

    func testKeyframesSweepUpToTheLastGlyphAndBackOncePerPeriod() {
        // The cosine sweep visits every glyph in order up to the last one,
        // then back down to the first, within one period (DESIGN.md §9).
        XCTAssertEqual(GlyphCycleSpinner.keyframes.frameIndices, [0, 1, 2, 3, 4, 5, 4, 3, 2, 1, 0])
    }

    func testKeyframesAgreeWithTheFormulaInsideEveryInterval() {
        // The animation must show the glyph the formula gives at every
        // time; compare at several instants strictly inside each interval,
        // over more than one period and on both sides of zero.
        let keyframes = GlyphCycleSpinner.keyframes
        let period = GlyphCycleSpinner.periodSeconds
        for periodStart in [-2 * period, 0, period, 1000 * period] {
            for i in 0..<keyframes.frameIndices.count {
                let start = keyframes.keyTimes[i]
                let end = keyframes.keyTimes[i + 1]
                for fraction in [0.01, 0.25, 0.5, 0.75, 0.99] {
                    let t = periodStart + (start + (end - start) * fraction) * period
                    XCTAssertEqual(
                        GlyphCycleSpinner.frameIndex(atReferenceTime: t),
                        keyframes.frameIndices[i],
                        "interval \(i) at t=\(t)"
                    )
                }
            }
        }
    }

    func testEveryInnerKeyTimeIsWhereTheFormulaChangesValue() {
        // The switch happens when the formula's value changes, not up to a
        // redraw tick later (DESIGN.md §9): just before and just after each
        // inner key time the formula gives different frames.
        let keyframes = GlyphCycleSpinner.keyframes
        let period = GlyphCycleSpinner.periodSeconds
        let epsilon = 1e-6
        for i in 1..<(keyframes.keyTimes.count - 1) {
            let t = keyframes.keyTimes[i] * period
            XCTAssertEqual(GlyphCycleSpinner.frameIndex(atReferenceTime: t - epsilon), keyframes.frameIndices[i - 1], "before key time \(i)")
            XCTAssertEqual(GlyphCycleSpinner.frameIndex(atReferenceTime: t + epsilon), keyframes.frameIndices[i], "after key time \(i)")
        }
    }

    func testPeriodStartIsTheLastMultipleOfThePeriodNotAfterT() {
        // Rows anchor their animation to this instant on the shared clock,
        // so a row that appears later is in phase with the others.
        let period = GlyphCycleSpinner.periodSeconds
        XCTAssertEqual(GlyphCycleSpinner.periodStart(atOrBefore: 0), 0)
        XCTAssertEqual(GlyphCycleSpinner.periodStart(atOrBefore: period), period)
        XCTAssertEqual(GlyphCycleSpinner.periodStart(atOrBefore: period * 3.7), period * 3)
        XCTAssertEqual(GlyphCycleSpinner.periodStart(atOrBefore: 12_345.678), 12_344)
        XCTAssertEqual(GlyphCycleSpinner.periodStart(atOrBefore: -0.5), -period)
    }

    func testRowsStartedAtDifferentTimesShareTheSamePeriodBoundaries() {
        // Two rows starting in different periods anchor to boundaries that
        // differ by whole periods, so both show the same frame at any time.
        let a = GlyphCycleSpinner.periodStart(atOrBefore: 100.3)
        let b = GlyphCycleSpinner.periodStart(atOrBefore: 107.9)
        let periods = (b - a) / GlyphCycleSpinner.periodSeconds
        XCTAssertEqual(periods, periods.rounded())
    }
}
