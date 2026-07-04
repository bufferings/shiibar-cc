import XCTest
@testable import ShiibarCCCore

final class ReconnectBackoffTests: XCTestCase {
    func testSequenceDoublesFromOneAndCapsAtThirty() {
        XCTAssertEqual(ReconnectBackoff.sequence(count: 8), [1, 2, 4, 8, 16, 30, 30, 30])
    }

    func testNegativeAttemptDefensivelyReturnsOneSecond() {
        XCTAssertEqual(ReconnectBackoff.delay(forAttempt: -1), 1)
    }
}
