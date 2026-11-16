import XCTest
@testable import ShiibarCcCore

/// The text size of the popover and the window (DESIGN.md §4.5 "text size",
/// §8.52, §9): range 9-18, default 13, ratio = value / 13, the stored-value
/// interpretation, the key steps, the Settings field's parsing, and the
/// widths that follow the ratio.
final class TextSizeTests: XCTestCase {
    func testRangeAndDefaultMatchSection9() {
        XCTAssertEqual(TextSize.minimum, 9)
        XCTAssertEqual(TextSize.maximum, 18)
        XCTAssertEqual(TextSize.base, 13)
        XCTAssertEqual(TextSize.default.points, 13)
        XCTAssertEqual(TextSize.surfaceWidthAtBase, 420)
        XCTAssertEqual(TextSize.twoColumnPaneAllowance, 460)
    }

    func testRatio() {
        XCTAssertEqual(TextSize(clamping: 9).ratio, 9.0 / 13.0)
        XCTAssertEqual(TextSize(clamping: 13).ratio, 1)
        XCTAssertEqual(TextSize(clamping: 18).ratio, 18.0 / 13.0)
        XCTAssertEqual(TextSize.ratio(forPoints: 13), 1)
        XCTAssertEqual(TextSize.ratio(forPoints: 18), 18.0 / 13.0)
    }

    func testClampingInit() {
        XCTAssertEqual(TextSize(clamping: 3).points, 9)
        XCTAssertEqual(TextSize(clamping: 9).points, 9)
        XCTAssertEqual(TextSize(clamping: 18).points, 18)
        XCTAssertEqual(TextSize(clamping: 40).points, 18)
    }

    func testStoredValueInterpretation() {
        let cases: [(String, Double?, Int)] = [
            ("missing -> default", nil, 13),
            ("integer in range", 15, 15),
            ("fraction rounds down", 14.4, 14),
            ("fraction rounds half up", 14.5, 15),
            ("fraction rounds up", 14.6, 15),
            ("below range -> minimum", 4, 9),
            ("just below range rounds into it", 8.5, 9),
            ("above range -> maximum", 20, 18),
            ("previous range end 19 -> maximum", 19, 18),
            ("not finite -> default", .nan, 13),
            ("infinite -> default", .infinity, 13),
        ]
        for (name, stored, expected) in cases {
            XCTAssertEqual(TextSize.fromStored(stored).points, expected, name)
        }
    }

    func testKeySteps() {
        XCTAssertEqual(TextSize(clamping: 13).larger, TextSize(clamping: 14))
        XCTAssertEqual(TextSize(clamping: 17).larger, TextSize(clamping: 18))
        XCTAssertNil(TextSize(clamping: 18).larger, "⌘= at the maximum does nothing")
        XCTAssertEqual(TextSize(clamping: 13).smaller, TextSize(clamping: 12))
        XCTAssertEqual(TextSize(clamping: 10).smaller, TextSize(clamping: 9))
        XCTAssertNil(TextSize(clamping: 9).smaller, "⌘− at the minimum does nothing")
        XCTAssertEqual(TextSize(clamping: 9).reset, .default)
        XCTAssertEqual(TextSize(clamping: 18).reset, .default)
        XCTAssertNil(TextSize(clamping: 13).reset, "⌘0 at 13 does nothing")
    }

    func testFieldParsing() {
        let cases: [(String, Result<TextSize, TextSize.InputError>)] = [
            ("15", .success(TextSize(clamping: 15))),
            ("  9 ", .success(TextSize(clamping: 9))),
            ("\t18\n", .success(TextSize(clamping: 18))),
            ("+12", .failure(.notWholeNumber)),
            ("13", .success(.default)),
            ("abc", .failure(.notWholeNumber)),
            ("", .failure(.notWholeNumber)),
            ("   ", .failure(.notWholeNumber)),
            ("12.5", .failure(.notWholeNumber)),
            ("12.0", .failure(.notWholeNumber)),
            ("1 2", .failure(.notWholeNumber)),
            ("-", .failure(.notWholeNumber)),
            ("\u{FF11}\u{FF12}", .failure(.notWholeNumber)), // full-width digits
            ("8", .failure(.outOfRange)),
            ("19", .failure(.outOfRange)),
            ("0", .failure(.outOfRange)),
            ("-3", .failure(.notWholeNumber)),
            ("99999999999999999999999", .failure(.outOfRange)),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(TextSize.parse(text), expected, "\"\(text)\"")
        }
    }

    func testErrorMessages() {
        XCTAssertEqual(TextSize.InputError.notWholeNumber.message, "Enter a whole number")
        XCTAssertEqual(TextSize.InputError.outOfRange.message, "Enter a number from 9 to 18")
    }

    func testPopoverAndListColumnWidths() {
        // 420 × ratio, rounded: 290.77 -> 291, 420, 581.54 -> 582.
        let cases: [(Int, Double)] = [(9, 291), (13, 420), (18, 582)]
        for (points, width) in cases {
            let size = TextSize(clamping: points)
            XCTAssertEqual(size.popoverWidth, width, "\(points)")
            XCTAssertEqual(size.listColumnWidth, width, "\(points)")
            XCTAssertEqual(size.twoColumnMinimumWidth, width + 460, "\(points)")
        }
    }

    func testTwoColumnThresholdBoundaries() {
        let cases: [(Int, Double, ColumnMode)] = [
            (13, 879.5, .one), (13, 880, .two),
            (18, 1041.5, .one), (18, 1042, .two),
            (9, 750.5, .one), (9, 751, .two),
        ]
        for (points, width, mode) in cases {
            XCTAssertEqual(ColumnMode.forWindowWidth(width, textSize: TextSize(clamping: points)), mode, "\(points) at \(width)")
        }
    }
}
