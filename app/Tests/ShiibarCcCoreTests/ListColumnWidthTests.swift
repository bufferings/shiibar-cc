import XCTest

@testable import ShiibarCcCore

/// The two-column list column width and the boundary drag (DESIGN.md §4.5
/// "switching by width" / "column boundary drag", §8.53, §9).
final class ListColumnWidthTests: XCTestCase {
    // MARK: - §9 constants

    func testConstantsMatchSection9() {
        XCTAssertEqual(ListColumnWidth.minimum, 280)
        XCTAssertEqual(ListColumnWidth.paneMinimum, 360)
        XCTAssertEqual(ListColumnWidth.dragAreaWidth, 8)
        XCTAssertEqual(ListColumnWidth.defaultWidth(textSize: .default), 420)
        XCTAssertEqual(MainSurfaceDefaultsKeys.listColumnWidth, "cc.shiibar.listColumnWidth")
    }

    // MARK: - Shown width

    func testNoRememberedWidthShowsTheDefault() {
        XCTAssertEqual(ListColumnWidth.shown(remembered: nil, windowWidth: 1400, textSize: .default), 420)
        XCTAssertEqual(ListColumnWidth.shown(remembered: nil, windowWidth: 780, textSize: .default), 420)
    }

    func testRememberedWidthIsShownInsideTheRange() {
        XCTAssertEqual(ListColumnWidth.shown(remembered: 300, windowWidth: 1400, textSize: .default), 300)
        XCTAssertEqual(ListColumnWidth.shown(remembered: 280, windowWidth: 1400, textSize: .default), 280)
        XCTAssertEqual(ListColumnWidth.shown(remembered: 600, windowWidth: 1400, textSize: .default), 600)
    }

    func testRememberedWidthBelowTheMinimumShowsTheMinimum() {
        XCTAssertEqual(ListColumnWidth.shown(remembered: 100, windowWidth: 1400, textSize: .default), 280)
        XCTAssertEqual(ListColumnWidth.shown(remembered: 279, windowWidth: 1400, textSize: .default), 280)
    }

    func testNarrowWindowKeepsThePaneMinimum() {
        // 700 + 360 > 1000: the list column gives way, the right column
        // (the 1pt line included) keeps 360.
        XCTAssertEqual(ListColumnWidth.shown(remembered: 700, windowWidth: 1000, textSize: .default), 640)
        XCTAssertEqual(ListColumnWidth.shown(remembered: 700, windowWidth: 780, textSize: .default), 420)
        // Exactly fitting is shown as is.
        XCTAssertEqual(ListColumnWidth.shown(remembered: 640, windowWidth: 1000, textSize: .default), 640)
    }

    func testShownWidthDoesNotRewriteTheRememberedWidth() {
        let remembered = 700.0
        XCTAssertEqual(ListColumnWidth.shown(remembered: remembered, windowWidth: 1000, textSize: .default), 640)
        // Widening the window again shows the remembered width.
        XCTAssertEqual(ListColumnWidth.shown(remembered: remembered, windowWidth: 1400, textSize: .default), 700)
    }

    func testTextSizeMovesOnlyTheDefaultWidth() {
        let small = TextSize(clamping: 9)
        let large = TextSize(clamping: 18)
        // No remembered width: follows the text size (rounded, §4.5).
        XCTAssertEqual(ListColumnWidth.shown(remembered: nil, windowWidth: 1600, textSize: small), small.listColumnWidth)
        XCTAssertEqual(ListColumnWidth.shown(remembered: nil, windowWidth: 1600, textSize: large), large.listColumnWidth)
        XCTAssertNotEqual(small.listColumnWidth, large.listColumnWidth)
        // A remembered width stays whatever the text size.
        for size in [small, .default, large] {
            XCTAssertEqual(ListColumnWidth.shown(remembered: 500, windowWidth: 1600, textSize: size), 500, "\(size.points)")
        }
    }

    func testTwoColumnThresholdIgnoresTheRememberedWidth() {
        // §8.53: the threshold comes from the default width only. The
        // column mode takes no remembered width, so a remembered list column
        // (wide or narrow) cannot move it.
        let cases: [(Int, Double)] = [(9, 651), (13, 780), (18, 942)]
        for (points, threshold) in cases {
            let size = TextSize(clamping: points)
            XCTAssertEqual(size.twoColumnMinimumWidth, threshold, "\(points)")
            XCTAssertEqual(ColumnMode.forWindowWidth(threshold, textSize: size), .two, "\(points)")
            XCTAssertEqual(ColumnMode.forWindowWidth(threshold - 1, textSize: size), .one, "\(points)")
            // At the threshold, a wider remembered width shows the default
            // width: the column cannot be wider than the default there.
            XCTAssertEqual(ListColumnWidth.shown(remembered: 900, windowWidth: threshold, textSize: size), size.listColumnWidth, "\(points)")
        }
    }

    func testMinimumWinsWhenTheRangeIsEmpty() {
        // 600 − 360 = 240 < 280.
        XCTAssertEqual(ListColumnWidth.clamp(500, windowWidth: 600), 280)
        XCTAssertEqual(ListColumnWidth.clamp(100, windowWidth: 600), 280)
        XCTAssertEqual(ListColumnWidth.shown(remembered: 500, windowWidth: 600, textSize: .default), 280)
    }

    // MARK: - Stored value

    func testStoredValueInterpretation() {
        let cases: [(String, Any?, Double?)] = [
            ("missing", nil, nil),
            ("double", 512.5, 512.5),
            ("integer", 300, 300),
            ("below the minimum is still remembered", 100.0, 100),
            ("279 is remembered as is", 279.0, 279),
            ("280", 280.0, 280),
            ("small positive", 0.5, 0.5),
            ("zero", 0.0, nil),
            ("negative", -20.0, nil),
            ("string", "300", nil),
            ("boolean", true, nil),
            ("array", [300.0], nil),
            ("infinity", Double.infinity, nil),
            ("nan", Double.nan, nil),
        ]
        for (name, stored, expected) in cases {
            XCTAssertEqual(ListColumnWidth.fromStored(stored), expected, name)
        }
    }

    // MARK: - Drag

    func testDragFollowsTheDeltaFromTheStartWidth() {
        var drag = ListColumnWidthDrag(startWidth: 420)
        drag.update(dragDelta: 35.5, windowWidth: 1400)
        XCTAssertEqual(drag.width, 455.5)
        drag.update(dragDelta: -80, windowWidth: 1400)
        XCTAssertEqual(drag.width, 340, "every update is measured from mouse-down")
    }

    func testDragStopsAtBothEnds() {
        var drag = ListColumnWidthDrag(startWidth: 420)
        drag.update(dragDelta: -500, windowWidth: 1400)
        XCTAssertEqual(drag.width, 280, "minimum")
        drag.update(dragDelta: -140, windowWidth: 1400)
        XCTAssertEqual(drag.width, 280, "exactly the minimum")
        drag.update(dragDelta: -100, windowWidth: 1400)
        XCTAssertEqual(drag.width, 320, "after overshooting, the boundary follows the pointer again")
        drag.update(dragDelta: 2000, windowWidth: 1400)
        XCTAssertEqual(drag.width, 1040, "window width minus the right column minimum")
        drag.update(dragDelta: 620, windowWidth: 1400)
        XCTAssertEqual(drag.width, 1040, "exactly the maximum")
        drag.update(dragDelta: 400, windowWidth: 1400)
        XCTAssertEqual(drag.width, 820, "after overshooting, the boundary follows the pointer again")
    }

    func testDragRangeUsesTheWindowWidthOfThatMoment() {
        var drag = ListColumnWidthDrag(startWidth: 420)
        drag.update(dragDelta: 300, windowWidth: 1400)
        XCTAssertEqual(drag.width, 720)
        drag.update(dragDelta: 300, windowWidth: 1000)
        XCTAssertEqual(drag.width, 640)
    }

    func testDragStartingFromAClampedShownWidth() {
        // Remembered 700 in a 900pt window shows 540; the drag starts there,
        // not at the remembered value.
        let shown = ListColumnWidth.shown(remembered: 700, windowWidth: 900, textSize: .default)
        var drag = ListColumnWidthDrag(startWidth: shown)
        XCTAssertEqual(drag.width, 540)
        XCTAssertNil(drag.widthToPersist, "a click on a clamped column does not store the clamped value")
        drag.update(dragDelta: -40, windowWidth: 900)
        XCTAssertEqual(drag.width, 500)
        XCTAssertEqual(drag.widthToPersist, 500)
        drag.update(dragDelta: 10, windowWidth: 900)
        XCTAssertEqual(drag.width, 540, "held at the maximum")
        XCTAssertNil(drag.widthToPersist, "ending where it began stores nothing")
    }

    func testWidthToPersist() {
        let click = ListColumnWidthDrag(startWidth: 420)
        XCTAssertNil(click.widthToPersist, "a click without movement remembers nothing")

        var back = ListColumnWidthDrag(startWidth: 420)
        back.update(dragDelta: 30, windowWidth: 1400)
        back.update(dragDelta: 0, windowWidth: 1400)
        XCTAssertNil(back.widthToPersist, "a drag that ends where it began remembers nothing")

        var pinned = ListColumnWidthDrag(startWidth: 280)
        pinned.update(dragDelta: -50, windowWidth: 1400)
        XCTAssertNil(pinned.widthToPersist, "a drag held at the minimum changed nothing")

        var moved = ListColumnWidthDrag(startWidth: 420)
        moved.update(dragDelta: 60, windowWidth: 1400)
        XCTAssertEqual(moved.widthToPersist, 480)

        var fraction = ListColumnWidthDrag(startWidth: 420)
        fraction.update(dragDelta: 35.5, windowWidth: 1400)
        XCTAssertEqual(fraction.widthToPersist, 456, "rounded to a whole point, half away from zero")
        fraction.update(dragDelta: 35.4, windowWidth: 1400)
        XCTAssertEqual(fraction.widthToPersist, 455)

        var tiny = ListColumnWidthDrag(startWidth: 420)
        tiny.update(dragDelta: 0.3, windowWidth: 1400)
        XCTAssertEqual(tiny.width, 420.3, "the shown width still follows the pointer")
        XCTAssertNil(tiny.widthToPersist, "under half a point rounds back to the start: nothing is remembered")
        tiny.update(dragDelta: -0.4, windowWidth: 1400)
        XCTAssertNil(tiny.widthToPersist)

        // The start compares after rounding too: a clamped fractional shown
        // width (window 900.4 gives a maximum of 540.4) ending 0.2pt lower.
        var clamped = ListColumnWidthDrag(startWidth: 540.4)
        clamped.update(dragDelta: -0.2, windowWidth: 900.4)
        XCTAssertNil(clamped.widthToPersist)
        clamped.update(dragDelta: -1, windowWidth: 900.4)
        XCTAssertEqual(clamped.widthToPersist, 539)
    }
}
