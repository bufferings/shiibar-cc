import XCTest
@testable import ShiibarCcCore

final class PeriodicReconcileTests: XCTestCase {
    func testIntervalMatchesDesignConstant() {
        // DESIGN.md §9: reconcile periodic interval ~60 seconds.
        XCTAssertEqual(PeriodicReconcile.intervalSeconds, 60)
    }

    func testToleranceMatchesDesignConstant() {
        // DESIGN.md §9: NSBackgroundActivityScheduler tolerance = 30 seconds.
        XCTAssertEqual(PeriodicReconcile.toleranceSeconds, 30)
    }
}
