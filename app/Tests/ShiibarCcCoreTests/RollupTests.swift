import XCTest
@testable import ShiibarCcCore

final class RollupTests: XCTestCase {
    func testWaitingBeatsWorkingAndIdle() {
        let state = Rollup.icon(statuses: [.idle, .working, .waiting], hasUnreviewed: false, daemonConnected: true)
        XCTAssertEqual(state.glyph, .waiting)
        XCTAssertEqual(state.dim, Rollup.normalDim)
    }

    func testWorkingBeatsIdleWhenNoWaiting() {
        let state = Rollup.icon(statuses: [.idle, .working], hasUnreviewed: false, daemonConnected: true)
        XCTAssertEqual(state.glyph, .working(frame: 0))
        XCTAssertEqual(state.dim, Rollup.normalDim)
    }

    func testWorkingFrameIsPassedThroughFromTheCaller() {
        // M5 T8: the animation frame is driven by an app-layer timer, not
        // computed here — `Rollup.icon` just carries whatever it's given.
        let state = Rollup.icon(statuses: [.working], hasUnreviewed: false, daemonConnected: true, workingFrame: 2)
        XCTAssertEqual(state.glyph, .working(frame: 2))
    }

    func testAllIdleIsDimmedIdleTier() {
        let state = Rollup.icon(statuses: [.idle, .idle], hasUnreviewed: false, daemonConnected: true)
        XCTAssertEqual(state.glyph, .idle)
        XCTAssertEqual(state.dim, Rollup.idleDim)
    }

    func testNoAgentsIsMoreDimmedThanIdle() {
        let state = Rollup.icon(statuses: [], hasUnreviewed: false, daemonConnected: true)
        XCTAssertEqual(state.glyph, .none)
        XCTAssertEqual(state.dim, Rollup.noAgentsDim)
        XCTAssertLessThan(Rollup.noAgentsDim, Rollup.idleDim)
    }

    func testDisconnectedForcesNoAgentsDimEvenWithLiveWaitingAgents() {
        // DESIGN.md §4.5: a stale rollup must not be shown as current while
        // reconnecting, so disconnected always dims like "no agents" no
        // matter what the last-known statuses were.
        let state = Rollup.icon(statuses: [.waiting], hasUnreviewed: false, daemonConnected: false)
        XCTAssertEqual(state.glyph, .none)
        XCTAssertEqual(state.dim, Rollup.noAgentsDim)
    }

    func testUnreviewedDotIsIndependentOfGlyphAndDisconnectedState() {
        XCTAssertTrue(Rollup.icon(statuses: [], hasUnreviewed: true, daemonConnected: true).hasUnreviewedDot)
        XCTAssertTrue(Rollup.icon(statuses: [.idle], hasUnreviewed: true, daemonConnected: false).hasUnreviewedDot)
        XCTAssertFalse(Rollup.icon(statuses: [.waiting], hasUnreviewed: false, daemonConnected: true).hasUnreviewedDot)
    }

    func testUnknownStatusIsIgnoredInTheRollup() {
        // DESIGN.md §4.2/§4.5: clients ignore unknown statuses — they don't
        // participate in the rollup at all.
        let state = Rollup.icon(statuses: [.unknown, .idle], hasUnreviewed: false, daemonConnected: true)
        XCTAssertEqual(state.glyph, .idle)
        XCTAssertEqual(state.dim, Rollup.idleDim)
    }

    func testAllUnknownStatusesShowTheNoAgentsGlyph() {
        let state = Rollup.icon(statuses: [.unknown, .unknown], hasUnreviewed: false, daemonConnected: true)
        XCTAssertEqual(state.glyph, .none)
        XCTAssertEqual(state.dim, Rollup.noAgentsDim)
    }
}
