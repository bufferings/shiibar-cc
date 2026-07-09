import XCTest
@testable import ShiibarCcCore

final class DropdownPanelPlacementTests: XCTestCase {
    func testFittingPlacementKeepsTheIconAnchor() {
        // §4.5: while extending right fits, the OS placement (panel.minX ==
        // icon.minX, measured on-device) stays untouched.
        let x = DropdownPanelPlacement.clampedX(
            iconMinX: 500, panelWidth: 340, visibleMinX: 0, visibleMaxX: 1440
        )
        XCTAssertEqual(x, 500)
    }

    func testNearTheRightEdgeThePanelRightAlignsToTheVisibleArea() {
        // §4.5: no flip — shift the whole panel left so its right edge is
        // flush with the visible area's right edge.
        let x = DropdownPanelPlacement.clampedX(
            iconMinX: 1300, panelWidth: 340, visibleMinX: 0, visibleMaxX: 1440
        )
        XCTAssertEqual(x, 1440 - 340)
    }

    func testExactFitIsNotShifted() {
        let x = DropdownPanelPlacement.clampedX(
            iconMinX: 1100, panelWidth: 340, visibleMinX: 0, visibleMaxX: 1440
        )
        XCTAssertEqual(x, 1100, "icon.minX + width == visibleMaxX fits exactly")
    }

    func testNarrowDisplayClampsToTheLeftEdgeAsALastResort() {
        // Visible area narrower than the panel: keeping the left edge
        // on-screen wins over right-edge alignment and the icon anchor.
        let x = DropdownPanelPlacement.clampedX(
            iconMinX: 100, panelWidth: 340, visibleMinX: 50, visibleMaxX: 300
        )
        XCTAssertEqual(x, 50)
    }

    func testToleranceOnlyAbsorbsFloatNoise() {
        // Measured on-device: the OS's fitting placement lands EXACTLY on
        // icon.minX, so anything beyond float noise is a real difference.
        XCTAssertEqual(DropdownPanelPlacement.tolerance, 0.5)
    }
}
