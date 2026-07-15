import XCTest
@testable import ShiibarCcCore

/// Text-size rules for the Conversations right pane (DESIGN.md §4.6/§9):
/// range 10-20pt, default 13pt, code blocks at body -1.5pt, one-point steps
/// clamped at the edges.
final class ConversationsTextSizeTests: XCTestCase {
    func testConstantsMatchSpec() {
        // §9: default 13pt, range 10-20pt, code at body -1.5pt.
        XCTAssertEqual(ConversationsTextSize.defaultSize, 13)
        XCTAssertEqual(ConversationsTextSize.minimum, 10)
        XCTAssertEqual(ConversationsTextSize.maximum, 20)
        XCTAssertEqual(ConversationsTextSize.codeDelta, -1.5)
        XCTAssertEqual(ConversationsTextSize.step, 1)
    }

    func testClampKeepsValuesInsideRange() {
        XCTAssertEqual(ConversationsTextSize.clamp(9), 10)
        XCTAssertEqual(ConversationsTextSize.clamp(10), 10)
        XCTAssertEqual(ConversationsTextSize.clamp(14.5), 14.5)
        XCTAssertEqual(ConversationsTextSize.clamp(20), 20)
        XCTAssertEqual(ConversationsTextSize.clamp(25), 20)
    }

    func testStepsClampAtTheEdges() {
        XCTAssertEqual(ConversationsTextSize.increased(13), 14)
        XCTAssertEqual(ConversationsTextSize.increased(20), 20)
        XCTAssertEqual(ConversationsTextSize.decreased(13), 12)
        XCTAssertEqual(ConversationsTextSize.decreased(10), 10)
    }
}
