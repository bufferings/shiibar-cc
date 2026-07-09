import XCTest
@testable import ShiibarCcCore

final class AgentListWindowRefreshTests: XCTestCase {
    func testIntervalMatchesDesignConstant() {
        // DESIGN.md §4.5 "the agent list window": re-take the elapsed-time
        // base every 60 seconds while visible.
        XCTAssertEqual(AgentListWindowRefresh.intervalSeconds, 60)
    }
}
