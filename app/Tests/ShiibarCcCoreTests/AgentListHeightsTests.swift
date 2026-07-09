import XCTest
@testable import ShiibarCcCore

final class AgentListHeightsTests: XCTestCase {
    // MARK: Dropdown cap (§4.5/§8.32: the whole dropdown fits the display)

    func testDropdownCapIsVisibleHeightMinusChromeAndMargin() {
        let cap = AgentListHeights.dropdownListCap(visibleFrameHeight: 1000, chromeHeight: 44)
        XCTAssertEqual(cap, 1000 - 44 - AgentListHeights.dropdownBottomMargin)
    }

    func testDropdownBottomMarginIsWithinTheSpecRange() {
        // M29 brief: a small bottom margin, on-device range 8–16pt.
        XCTAssertGreaterThanOrEqual(AgentListHeights.dropdownBottomMargin, 8)
        XCTAssertLessThanOrEqual(AgentListHeights.dropdownBottomMargin, 16)
    }

    func testDropdownCapNeverDropsBelowTheOneRowFloor() {
        let cap = AgentListHeights.dropdownListCap(visibleFrameHeight: 50, chromeHeight: 44)
        XCTAssertEqual(cap, AgentListHeights.dropdownListCapFloor)
    }

    func testPanelContentHeightIsNaturalListPlusChromeBelowTheCap() {
        let height = AgentListHeights.dropdownPanelContentHeight(
            naturalListHeight: 143, listCap: 900, chromeHeight: 44
        )
        XCTAssertEqual(height, 143 + 44)
    }

    func testPanelContentHeightIsCappedListPlusChromeAboveTheCap() {
        let height = AgentListHeights.dropdownPanelContentHeight(
            naturalListHeight: 1199, listCap: 900, chromeHeight: 44
        )
        XCTAssertEqual(height, 900 + 44)
    }

    // MARK: Agents window height application (§4.5: remembered, else natural)

    func testStoredHeightWinsWhenPresent() {
        let height = AgentListHeights.agentsWindowHeightToApply(
            stored: 500, firstOpenFallback: 300, minimum: 178, maximum: 900
        )
        XCTAssertEqual(height, 500)
    }

    func testFirstOpenFallsBackToTheNaturalHeightWhenNothingIsStored() {
        // "Nothing stored" arrives as 0 (`UserDefaults.double(forKey:)`'s
        // absent-value result); negative garbage must behave the same.
        for stored: Double in [0, -5] {
            let height = AgentListHeights.agentsWindowHeightToApply(
                stored: stored, firstOpenFallback: 300, minimum: 178, maximum: 900
            )
            XCTAssertEqual(height, 300)
        }
    }

    func testAppliedHeightIsClampedToMinimumAndMaximum() {
        XCTAssertEqual(
            AgentListHeights.agentsWindowHeightToApply(
                stored: 50, firstOpenFallback: 300, minimum: 178, maximum: 900
            ),
            178,
            "below the window minimum: clamp up"
        )
        XCTAssertEqual(
            AgentListHeights.agentsWindowHeightToApply(
                stored: 5000, firstOpenFallback: 300, minimum: 178, maximum: 900
            ),
            900,
            "taller than the display's visible height: clamp down"
        )
    }

    func testFittingTheDisplayWinsWhenMaximumIsBelowMinimum() {
        // Pathological display smaller than the window minimum: prefer
        // fitting the screen over honoring the minimum.
        let height = AgentListHeights.agentsWindowHeightToApply(
            stored: 500, firstOpenFallback: 300, minimum: 178, maximum: 120
        )
        XCTAssertEqual(height, 120)
    }
}
