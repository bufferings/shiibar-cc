import AppKit
import ShiibarCcCore
import XCTest
@testable import ShiibarCcApp

/// The tray image keeps the window frame horizontally centered in every
/// state and reserves the corner dot's room on both sides, so the frame does
/// not shift and the status item's width does not change when the dot
/// appears (`TrayIconMetrics`).
final class TrayIconMetricsTests: XCTestCase {
    private let accuracy: CGFloat = 1e-9

    func testFrameIsHorizontallyCenteredInTheCanvas() {
        let m = TrayIconMetrics.self
        XCTAssertEqual(m.frameRect.midX, m.canvasWidth / 2, accuracy: accuracy)
        XCTAssertEqual(m.frameRect.minX, m.canvasWidth - m.frameRect.maxX, accuracy: accuracy)
    }

    func testCornerDotAndHaloFitInsideTheCanvas() {
        let m = TrayIconMetrics.self
        XCTAssertLessThanOrEqual(m.dotCenter.x + m.dotRadius + m.haloLineWidth / 2, m.canvasWidth)
        XCTAssertLessThanOrEqual(m.dotCenter.y + m.dotRadius + m.haloLineWidth / 2, m.canvasHeight)
    }

    func testGeometryValues() {
        let m = TrayIconMetrics.self
        XCTAssertEqual(m.canvasWidth, 22.4, accuracy: accuracy)
        XCTAssertEqual(m.canvasHeight, 18)
        XCTAssertEqual(m.frameRect.minX, 3.2, accuracy: accuracy)
        XCTAssertEqual(m.frameRect.width, 16)
        XCTAssertEqual(m.emblemCenter.x, 8.8, accuracy: accuracy)
        assertValues(m.workingDotCenters.map(\.x), [7.4, 11.2, 15.0], accuracy: accuracy)
        XCTAssertEqual(m.dotCenter.x, 18.0, accuracy: accuracy)
    }

    func testImageSizeIsTheSameWithAndWithoutTheDot() {
        let dotColor = ResolvedRGBA(red: 1, green: 0.58, blue: 0, alpha: 1)
        let plain = TrayIconRenderer.render(
            state: TrayIconState(glyph: .idle, dim: Rollup.idleDim, dot: nil),
            darkMenuBar: false, dotColor: nil)
        let dotted = TrayIconRenderer.render(
            state: TrayIconState(glyph: .waiting, dim: Rollup.normalDim, dot: .waiting),
            darkMenuBar: false, dotColor: dotColor)
        let expected = NSSize(width: TrayIconMetrics.canvasWidth, height: TrayIconMetrics.canvasHeight)
        XCTAssertEqual(plain.size, expected)
        XCTAssertEqual(dotted.size, expected)
    }
}

private func assertValues(
    _ actual: [CGFloat], _ expected: [CGFloat], accuracy: CGFloat,
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertEqual(actual.count, expected.count, file: file, line: line)
    for (a, e) in zip(actual, expected) {
        XCTAssertEqual(a, e, accuracy: accuracy, file: file, line: line)
    }
}
