import XCTest
@testable import ShiibarCcCore

/// DESIGN.md §3.1: one dot standing for several sessions is orange when any
/// is waiting, else the accent color when any is unreviewed, else absent.
final class StateDotTests: XCTestCase {
    func testWaitingTakesPriorityOverUnreviewed() {
        let cases: [(hasWaiting: Bool, hasUnreviewed: Bool, expected: StateDot?)] = [
            (true, true, .waiting),
            (true, false, .waiting),
            (false, true, .unreviewed),
            (false, false, nil),
        ]
        for c in cases {
            XCTAssertEqual(StateDot.of(hasWaiting: c.hasWaiting, hasUnreviewed: c.hasUnreviewed), c.expected, "\(c)")
        }
    }
}
