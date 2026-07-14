import XCTest
@testable import ShiibarCcCore

/// Text-size rules for the Conversations right pane (DESIGN.md §4.6/§9):
/// range 11-18pt, default 13pt, code blocks at body -1.5pt, one-point steps
/// clamped at the edges.
final class ConversationsTextSizeTests: XCTestCase {
    func testConstantsMatchSpec() {
        // §9: default 13pt, range 11-18pt, code at body -1.5pt.
        XCTAssertEqual(ConversationsTextSize.defaultSize, 13)
        XCTAssertEqual(ConversationsTextSize.minimum, 11)
        XCTAssertEqual(ConversationsTextSize.maximum, 18)
        XCTAssertEqual(ConversationsTextSize.codeDelta, -1.5)
        XCTAssertEqual(ConversationsTextSize.step, 1)
    }

    func testClampKeepsValuesInsideRange() {
        XCTAssertEqual(ConversationsTextSize.clamp(10), 11)
        XCTAssertEqual(ConversationsTextSize.clamp(11), 11)
        XCTAssertEqual(ConversationsTextSize.clamp(14.5), 14.5)
        XCTAssertEqual(ConversationsTextSize.clamp(18), 18)
        XCTAssertEqual(ConversationsTextSize.clamp(25), 18)
    }

    func testStepsClampAtTheEdges() {
        XCTAssertEqual(ConversationsTextSize.increased(13), 14)
        XCTAssertEqual(ConversationsTextSize.increased(18), 18)
        XCTAssertEqual(ConversationsTextSize.decreased(13), 12)
        XCTAssertEqual(ConversationsTextSize.decreased(11), 11)
    }
}
