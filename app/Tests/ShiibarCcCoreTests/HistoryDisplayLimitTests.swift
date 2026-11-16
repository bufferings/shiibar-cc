import XCTest

@testable import ShiibarCcCore

/// The History row cap (DESIGN.md §4.6 "History section": rows shown are the
/// head of the order up to the §9 limit; §9 "History row limit" = 100, not
/// applied to Running; window-design.html "hidden conversation count").
final class HistoryDisplayLimitTests: XCTestCase {
    /// `count` summaries `c0`, `c1`, … in search order (updated_at descending).
    private func results(_ count: Int, prefix: String = "c") -> [ConversationSummary] {
        (0..<count).map { UL.summary("\(prefix)\($0)", updatedAt: Int64(9_000 - $0)) }
    }

    private func state(
        results: [ConversationSummary],
        isFiltered: Bool = false,
        agents: [Agent] = [],
        stars: Set<String> = [],
        columns: ColumnMode = .one
    ) -> UnifiedListState {
        var state = UnifiedListState(home: UL.home, now: UL.now, stars: stars)
        state.handle(.columnsChanged(columns))
        if !agents.isEmpty {
            state.handle(.agentsUpdated(agents))
        }
        state.handle(.historyDelivered(results, isFiltered: isFiltered))
        return state
    }

    // MARK: - Row count, hidden count and trailer text

    func testRowCountHiddenCountAndTrailer() {
        struct Case {
            let name: String
            let resultCount: Int
            let isFiltered: Bool
            let runningSessions: [String]
            let expectedRows: Int
            let expectedHidden: Int
            let expectedText: String?
        }
        let cases: [Case] = [
            Case(name: "fewer than the cap", resultCount: 3, isFiltered: false, runningSessions: [],
                 expectedRows: 3, expectedHidden: 0, expectedText: nil),
            Case(name: "exactly 100", resultCount: 100, isFiltered: false, runningSessions: [],
                 expectedRows: 100, expectedHidden: 0, expectedText: nil),
            Case(name: "101 browse", resultCount: 101, isFiltered: false, runningSessions: [],
                 expectedRows: 100, expectedHidden: 1, expectedText: "1 more \u{2014} search to narrow down"),
            Case(name: "250 browse", resultCount: 250, isFiltered: false, runningSessions: [],
                 expectedRows: 100, expectedHidden: 150, expectedText: "150 more \u{2014} search to narrow down"),
            Case(name: "250 filtered", resultCount: 250, isFiltered: true, runningSessions: [],
                 expectedRows: 100, expectedHidden: 150, expectedText: "150 more \u{2014} refine your search"),
            Case(name: "101 with 1 running: exclusion before the cut", resultCount: 101, isFiltered: false,
                 runningSessions: ["c50"], expectedRows: 100, expectedHidden: 0, expectedText: nil),
            Case(name: "102 with 1 running", resultCount: 102, isFiltered: true,
                 runningSessions: ["c0"], expectedRows: 100, expectedHidden: 1,
                 expectedText: "1 more \u{2014} refine your search"),
        ]
        for c in cases {
            let agents = c.runningSessions.enumerated().map { UL.agent("t\($0.offset)", session: $0.element) }
            let s = state(results: results(c.resultCount), isFiltered: c.isFiltered, agents: agents)
            XCTAssertEqual(s.historyRows.count, c.expectedRows, c.name)
            XCTAssertEqual(s.hiddenHistoryCount, c.expectedHidden, c.name)
            XCTAssertEqual(s.hiddenHistoryText, c.expectedText, c.name)
            let historySection = s.sections.first { $0.section == .history }
            XCTAssertEqual(historySection?.count, c.expectedRows, "\(c.name): heading counts shown rows")
            XCTAssertEqual(s.visibleRows.count, c.runningSessions.count + c.expectedRows, c.name)
            XCTAssertEqual(s.runningRows.count, c.runningSessions.count, "\(c.name): Running is never capped")
            XCTAssertEqual(s.searchResultCount, c.resultCount, "\(c.name): result count is the full result")
        }
    }

    func testRunningSectionIsNeverCapped() {
        let all = results(150)
        let agents = (0..<120).map { UL.agent("t\($0)", session: "c\($0)") }
        let s = state(results: all, agents: agents)
        XCTAssertEqual(s.runningRows.count, 120)
        XCTAssertEqual(s.historyRows.map(\.sessionID), (120..<150).map { "c\($0)" })
        XCTAssertNil(s.hiddenHistoryText)
    }

    func testNoTrailerBeforeAnyResultOrDuringFullBuild() {
        XCTAssertNil(UnifiedListState(home: UL.home, now: UL.now).hiddenHistoryText)
        var s = state(results: results(150))
        XCTAssertNotNil(s.hiddenHistoryText)
        s.handle(.fullBuildChanged(true))
        XCTAssertEqual(s.hiddenHistoryCount, 0)
        XCTAssertNil(s.hiddenHistoryText)
    }

    // MARK: - Starred-first order before the cut

    func testStarsBeyondTheCapArePulledIntoTheShownRows() {
        let s = state(results: results(150), stars: ["c120", "c149"])
        XCTAssertEqual(s.historyRows.count, 100)
        XCTAssertEqual(Array(s.historyRows.prefix(2).map(\.sessionID)), ["c120", "c149"])
        XCTAssertEqual(Array(s.historyRows.dropFirst(2).map(\.sessionID)), (0..<98).map { "c\($0)" })
        XCTAssertEqual(s.hiddenHistoryCount, 50)
    }

    func testStarTogglePullsARowInAndPushesTheLastOneOut() {
        var s = state(results: results(101))
        XCTAssertEqual(s.historyRows.last?.sessionID, "c99")
        s.handle(.starToggled(sessionID: "c100"))
        XCTAssertEqual(s.historyRows.first?.sessionID, "c100")
        XCTAssertEqual(s.historyRows.last?.sessionID, "c98")
        XCTAssertEqual(s.hiddenHistoryCount, 1)
    }

    // MARK: - Movement and position

    func testMovementStopsAtTheHundredthRow() {
        var s = state(results: results(250))
        s.handle(.rowClicked(.history(sessionID: "c98")))
        XCTAssertEqual(s.handle(.moveDown), [.scrollSelectionIntoView])
        XCTAssertEqual(s.selection?.key, .history(sessionID: "c99"))
        XCTAssertEqual(s.handle(.moveDown), [], "the 100th row is the bottom edge")
        XCTAssertEqual(s.selection?.key, .history(sessionID: "c99"))
    }

    func testPositionTextCountsShownRowsOnly() {
        var s = state(results: results(250), agents: [UL.agent("t1", session: "c0")])
        s.handle(.rowOpenClicked(.history(sessionID: "c100")))
        guard case .conversation(let pane) = s.paneContent else {
            return XCTFail("expected the detail page")
        }
        // 1 Running row + 100 History rows (c1…c100).
        XCTAssertEqual(pane.positionText, "101 / 101")
        XCTAssertFalse(pane.canGoNext)
        XCTAssertTrue(pane.canGoPrevious)
    }

    func testRowBeyondTheCapCannotBeClicked() {
        var s = state(results: results(150))
        s.handle(.rowClicked(.history(sessionID: "c120")))
        XCTAssertNil(s.selection)
    }

    // MARK: - Selection reconciliation

    func testSelectedRowPushedOutByNewerResultsDeselects() {
        var s = state(results: results(100), columns: .two)
        s.handle(.rowClicked(.history(sessionID: "c99")))
        XCTAssertEqual(s.selection?.key, .history(sessionID: "c99"))
        let newer = results(5, prefix: "n").map { UL.summary($0.sessionID, updatedAt: 9_500) }
        s.handle(.historyDelivered(newer + results(100), isFiltered: false))
        XCTAssertNil(s.selection, "§4.5: a selected row no longer listed deselects")
        XCTAssertEqual(s.paneContent, .noSelection)
        XCTAssertEqual(s.hiddenHistoryCount, 5)
    }

    func testSelectedRowStillInsideTheCapStaysSelected() {
        var s = state(results: results(100), columns: .two)
        s.handle(.rowClicked(.history(sessionID: "c10")))
        s.handle(.historyDelivered([UL.summary("n0", updatedAt: 9_500)] + results(100), isFiltered: false))
        XCTAssertEqual(s.selection?.key, .history(sessionID: "c10"))
    }

    // MARK: - Display only: pruning and titles see the full result

    func testStarPruningSeesRowsBeyondTheCap() {
        // 120 starred conversations: stars c100…c119 sit beyond the cap even
        // in the starred-first order. A browse delivery must keep them (they
        // are in the result) and prune only the missing session.
        let starred = Set((0..<120).map { "c\($0)" })
        var s = UnifiedListState(home: UL.home, now: UL.now, stars: starred.union(["gone"]))
        let effects = s.handle(.historyDelivered(results(150), isFiltered: false))
        XCTAssertEqual(effects, [.persistStars(starred)])
        XCTAssertEqual(s.stars, starred)
        XCTAssertEqual(s.historyRows.map(\.sessionID), (0..<100).map { "c\($0)" })
        XCTAssertEqual(s.hiddenHistoryCount, 50)
    }

    func testRunningTitleLookupSeesResultsBeyondTheCap() {
        var all = results(250)
        all[200] = UL.summary("c200", title: "Deep title", updatedAt: all[200].updatedAt)
        let s = state(results: all, agents: [UL.agent("t1", session: "c200")])
        XCTAssertEqual(s.runningRows.first?.line1, "Deep title")
        XCTAssertEqual(s.historyRows.count, 100)
        XCTAssertEqual(s.hiddenHistoryCount, 149)
    }
}
