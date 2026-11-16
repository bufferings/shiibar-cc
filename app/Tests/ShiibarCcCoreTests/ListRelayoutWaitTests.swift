import XCTest
@testable import ShiibarCcCore

/// The list's wait for new row frames after a text size change (DESIGN.md
/// §4.5 "text size"): released by a rows change or by the fallback, never
/// armed without rows.
final class ListRelayoutWaitTests: XCTestCase {
    func testReleasedByARowsChange() {
        var wait = ListRelayoutWait()
        let generation = wait.arm(hasRows: true)
        XCTAssertNotNil(generation)
        XCTAssertTrue(wait.isWaiting)
        wait.rowsChanged()
        XCTAssertFalse(wait.isWaiting)
        XCTAssertFalse(wait.fallbackFired(generation: generation ?? 0), "the rows already released it")
    }

    func testReleasedByTheFallbackWhenTheRowsDoNotChange() {
        var wait = ListRelayoutWait()
        let generation = wait.arm(hasRows: true) ?? 0
        XCTAssertTrue(wait.fallbackFired(generation: generation))
        XCTAssertFalse(wait.isWaiting)
    }

    func testAnOlderFallbackDoesNotReleaseANewerWait() {
        var wait = ListRelayoutWait()
        let first = wait.arm(hasRows: true) ?? 0
        let second = wait.arm(hasRows: true) ?? 0
        XCTAssertFalse(wait.fallbackFired(generation: first))
        XCTAssertTrue(wait.isWaiting)
        XCTAssertTrue(wait.fallbackFired(generation: second))
        XCTAssertFalse(wait.isWaiting)
    }

    func testNothingArmedWithoutRows() {
        var wait = ListRelayoutWait()
        XCTAssertNil(wait.arm(hasRows: false))
        XCTAssertFalse(wait.isWaiting)
    }

    func testFallbackDelay() {
        XCTAssertEqual(ListRelayoutWait.fallbackSeconds, 0.25)
    }
}
