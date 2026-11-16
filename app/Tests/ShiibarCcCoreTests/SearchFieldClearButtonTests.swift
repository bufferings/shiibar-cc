import XCTest
@testable import ShiibarCcCore

/// DESIGN.md §4.6 "search field": the clear button shows only while the
/// field holds text, and never while the field is disabled.
final class SearchFieldClearButtonTests: XCTestCase {
    func testShownWhileTheEnabledFieldHoldsText() {
        XCTAssertTrue(SearchFieldClearButton.isShown(text: "tag", isEnabled: true))
        XCTAssertTrue(SearchFieldClearButton.isShown(text: "t", isEnabled: true))
        XCTAssertTrue(SearchFieldClearButton.isShown(text: " ", isEnabled: true))
    }

    func testHiddenWhileTheFieldIsEmpty() {
        XCTAssertFalse(SearchFieldClearButton.isShown(text: "", isEnabled: true))
    }

    func testHiddenWhileTheFieldIsDisabled() {
        XCTAssertFalse(SearchFieldClearButton.isShown(text: "tag", isEnabled: false))
        XCTAssertFalse(SearchFieldClearButton.isShown(text: "", isEnabled: false))
    }
}
