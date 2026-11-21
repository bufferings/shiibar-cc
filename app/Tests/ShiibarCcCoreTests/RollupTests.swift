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
        XCTAssertEqual(state.glyph, .working)
        XCTAssertEqual(state.dim, Rollup.normalDim)
    }

    func testAllWorkingIsFullOpacityWorking() {
        let state = Rollup.icon(statuses: [.working, .working], hasUnreviewed: true, daemonConnected: true)
        XCTAssertEqual(state.glyph, .working)
        XCTAssertEqual(state.dim, Rollup.normalDim)
        XCTAssertEqual(state.dot, .unreviewed)
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

    /// DESIGN.md §4.5 "visual source of truth": the corner dot is orange
    /// while any agent is waiting, else the accent color while any agent is
    /// unreviewed, else absent — whatever the glyph.
    func testCornerDotPrefersWaitingOverUnreviewed() {
        struct Case {
            let statuses: [AgentStatus]
            let hasUnreviewed: Bool
            let expected: StateDot?
        }
        let cases: [Case] = [
            Case(statuses: [.waiting], hasUnreviewed: false, expected: .waiting),
            Case(statuses: [.waiting], hasUnreviewed: true, expected: .waiting),
            Case(statuses: [.waiting, .idle], hasUnreviewed: true, expected: .waiting),
            Case(statuses: [.idle], hasUnreviewed: true, expected: .unreviewed),
            Case(statuses: [.working, .idle], hasUnreviewed: true, expected: .unreviewed),
            Case(statuses: [.working, .idle], hasUnreviewed: false, expected: nil),
            Case(statuses: [.unknown], hasUnreviewed: false, expected: nil),
        ]
        for c in cases {
            XCTAssertEqual(Rollup.icon(statuses: c.statuses, hasUnreviewed: c.hasUnreviewed, daemonConnected: true).dot,
                           c.expected, "\(c.statuses) unreviewed=\(c.hasUnreviewed)")
        }
    }

    /// With no agents there is no dot.
    func testNoAgentsHasNoDot() {
        XCTAssertNil(Rollup.icon(statuses: [], hasUnreviewed: false, daemonConnected: true).dot)
        XCTAssertNil(Rollup.icon(statuses: [], hasUnreviewed: false, daemonConnected: false).dot)
    }

    /// While disconnected the glyph is the no-agents glyph, but the dot is
    /// decided from the last list received (drawn dimmed with the rest).
    func testDisconnectedDecidesTheDotFromTheLastList() {
        let waiting = Rollup.icon(statuses: [.waiting, .idle], hasUnreviewed: true, daemonConnected: false)
        XCTAssertEqual(waiting.glyph, .none)
        XCTAssertEqual(waiting.dim, Rollup.noAgentsDim)
        XCTAssertEqual(waiting.dot, .waiting)
        XCTAssertEqual(Rollup.icon(statuses: [.idle], hasUnreviewed: true, daemonConnected: false).dot, .unreviewed)
        XCTAssertNil(Rollup.icon(statuses: [.idle], hasUnreviewed: false, daemonConnected: false).dot)
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
