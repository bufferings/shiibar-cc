import XCTest

@testable import ShiibarCcCore

/// The Recent row cap (DESIGN.md §4.6 "Recent section": rows shown are the
/// head of the order up to the §9 limit, counted over Recent's rows only;
/// §9 Recent row limit = 100, not applied to Running or Starred).
final class RecentDisplayLimitTests: XCTestCase {
    /// `count` summaries `c0`, `c1`, … in search order (updated_at descending).
    private func results(_ count: Int, prefix: String = "c") -> [ConversationSummary] {
        (0..<count).map { UL.summary("\(prefix)\($0)", updatedAt: Int64(9_000 - $0)) }
    }

    private func state(
        results: [ConversationSummary],
        isFiltered: Bool = false,
        agents: [Agent] = [],
        stars: StarredList = [],
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
            XCTAssertEqual(s.recentRows.count, c.expectedRows, c.name)
            XCTAssertEqual(s.hiddenRecentCount, c.expectedHidden, c.name)
            XCTAssertEqual(s.hiddenRecentText, c.expectedText, c.name)
            // Without Starred rows the History heading stands for the
            // Recent heading and shows its count.
            let historyHeading = s.headings.first { $0.heading == .history }
            XCTAssertEqual(historyHeading?.countText, c.expectedHidden > 0 ? "first 100" : "\(c.expectedRows)",
                           "\(c.name): heading counts shown rows")
            XCTAssertEqual(s.visibleRows.count, c.runningSessions.count + c.expectedRows, c.name)
            XCTAssertEqual(s.runningRows.count, c.runningSessions.count, "\(c.name): Running is never capped")
        }
    }

    /// §4.6 "Recent section" / §8.56: while the cap leaves conversations
    /// out, the Recent count is `first 100` (from the §9 cap) in place of
    /// the row count, for a browse or a filtered result; at or under the cap
    /// it is the row count. Without Starred rows the History heading shows
    /// it (`History first 100`). Running's heading always shows its row
    /// count.
    func testRecentCountText() {
        struct Case {
            let name: String
            let resultCount: Int
            let isFiltered: Bool
            let runningSessions: [String]
            let expectedText: String
        }
        let cases = [
            Case(name: "under the cap", resultCount: 42, isFiltered: false, runningSessions: [],
                 expectedText: "42"),
            Case(name: "exactly the cap", resultCount: 100, isFiltered: false, runningSessions: [],
                 expectedText: "100"),
            Case(name: "over the cap, browsing", resultCount: 101, isFiltered: false, runningSessions: [],
                 expectedText: "first 100"),
            Case(name: "over the cap, searching", resultCount: 250, isFiltered: true, runningSessions: [],
                 expectedText: "first 100"),
            Case(name: "searching, narrowed under the cap", resultCount: 7, isFiltered: true, runningSessions: [],
                 expectedText: "7"),
            Case(name: "101 with 1 running: nothing left out", resultCount: 101, isFiltered: false,
                 runningSessions: ["c50"], expectedText: "100"),
            Case(name: "102 with 1 running", resultCount: 102, isFiltered: false,
                 runningSessions: ["c0"], expectedText: "first 100"),
        ]
        for c in cases {
            let agents = c.runningSessions.enumerated().map { UL.agent("t\($0.offset)", session: $0.element) }
            let s = state(results: results(c.resultCount), isFiltered: c.isFiltered, agents: agents)
            XCTAssertEqual(s.recentCountText, c.expectedText, c.name)
            XCTAssertEqual(s.headings.first { $0.heading == .history }?.countText, c.expectedText, c.name)
            if !c.runningSessions.isEmpty {
                XCTAssertEqual(s.headings.first { $0.heading == .running }?.countText,
                               "\(c.runningSessions.count)", "\(c.name): Running shows its row count")
            }
        }
    }

    func testRunningSectionIsNeverCapped() {
        let all = results(150)
        let agents = (0..<120).map { UL.agent("t\($0)", session: "c\($0)") }
        let s = state(results: all, agents: agents)
        XCTAssertEqual(s.runningRows.count, 120)
        XCTAssertEqual(s.recentRows.map(\.sessionID), (120..<150).map { "c\($0)" })
        XCTAssertNil(s.hiddenRecentText)
    }

    func testNoTrailerBeforeAnyResultOrDuringFullBuild() {
        XCTAssertNil(UnifiedListState(home: UL.home, now: UL.now).hiddenRecentText)
        var s = state(results: results(150))
        XCTAssertNotNil(s.hiddenRecentText)
        s.handle(.fullBuildChanged(true))
        XCTAssertEqual(s.hiddenRecentCount, 0)
        XCTAssertNil(s.hiddenRecentText)
    }

    // MARK: - Starred is outside the cap

    /// §4.6 "Recent section" / "Starred section": starred conversations
    /// leave Recent, so the cap, `first 100` and `N more` count Recent's
    /// own rows; Starred shows every starred conversation, however old.
    func testStarredRowsAreNotCountedByTheCap() {
        let s = state(results: results(150), stars: ["c149", "c120"])
        XCTAssertEqual(s.starredRows.map(\.sessionID), ["c149", "c120"], "Starred is never capped")
        XCTAssertEqual(s.recentRows.map(\.sessionID), (0..<100).map { "c\($0)" })
        XCTAssertEqual(s.hiddenRecentCount, 48)
        XCTAssertEqual(s.hiddenRecentText, "48 more \u{2014} search to narrow down")
        XCTAssertEqual(s.headings.map(\.heading), [.history, .starred, .recent])
        XCTAssertEqual(s.headings.map(\.countText), [nil, "2", "first 100"],
                       "with Starred rows the History heading shows no count")
    }

    func testStarringARowFreesItsPlaceUnderTheCap() {
        var s = state(results: results(101))
        XCTAssertEqual(s.headings.first { $0.heading == .history }?.countText, "first 100")
        s.handle(.starToggled(sessionID: "c3"))
        XCTAssertEqual(s.starredRows.map(\.sessionID), ["c3"])
        XCTAssertEqual(s.recentRows.count, 100)
        XCTAssertEqual(s.recentRows.last?.sessionID, "c100", "the row beyond the cap comes in")
        XCTAssertEqual(s.hiddenRecentCount, 0)
        XCTAssertNil(s.hiddenRecentText)
        XCTAssertEqual(s.headings.first { $0.heading == .recent }?.countText, "100")
        XCTAssertEqual(s.headings.first { $0.heading == .history }?.countText, nil)
    }

    func testUnstarredRowBeyondTheCapIsNotShown() {
        // §4.6 "stars": an unstarred conversation goes to its newest-first
        // place in Recent; beyond the cap it is not shown.
        var s = state(results: results(150), stars: ["c140"])
        s.handle(.starToggled(sessionID: "c140"))
        XCTAssertEqual(s.starredRows, [])
        XCTAssertFalse(s.recentRows.contains { $0.sessionID == "c140" })
        XCTAssertEqual(s.hiddenRecentCount, 50)
    }

    func testUnstarringTheSelectedRowBeyondTheCapDeselects() {
        var s = state(results: results(150), stars: ["c140"])
        s.handle(.rowClicked(.conversation(sessionID: "c140")))
        XCTAssertNotNil(s.selection)
        s.handle(.starToggled(sessionID: "c140"))
        XCTAssertNil(s.selection, "its conversation is not shown in Recent")
    }

    // MARK: - Movement and position

    func testMovementStopsAtTheHundredthRow() {
        var s = state(results: results(250))
        s.handle(.rowClicked(.conversation(sessionID: "c98")))
        XCTAssertEqual(s.handle(.moveDown), [.scrollSelectionIntoView])
        XCTAssertEqual(s.selection?.key, .conversation(sessionID: "c99"))
        XCTAssertEqual(s.handle(.moveDown), [], "the 100th row is the bottom edge")
        XCTAssertEqual(s.selection?.key, .conversation(sessionID: "c99"))
    }

    func testPositionTextCountsShownRowsOnly() {
        var s = state(results: results(250), agents: [UL.agent("t1", session: "c0")])
        s.openDetailPage(.conversation(sessionID: "c100"))
        guard case .conversation(let pane) = s.paneContent else {
            return XCTFail("expected the detail page")
        }
        // 1 Running row + 100 Recent rows (c1…c100).
        XCTAssertEqual(pane.positionText, "101 / 101")
        XCTAssertFalse(pane.canGoNext)
        XCTAssertTrue(pane.canGoPrevious)
    }

    func testRowBeyondTheCapCannotBeClicked() {
        var s = state(results: results(150))
        s.handle(.rowClicked(.conversation(sessionID: "c120")))
        XCTAssertNil(s.selection)
    }

    // MARK: - Selection reconciliation

    func testSelectedRowPushedOutByNewerResultsDeselects() {
        var s = state(results: results(100), columns: .two)
        s.handle(.rowClicked(.conversation(sessionID: "c99")))
        XCTAssertEqual(s.selection?.key, .conversation(sessionID: "c99"))
        let newer = results(5, prefix: "n").map { UL.summary($0.sessionID, updatedAt: 9_500) }
        s.handle(.historyDelivered(newer + results(100), isFiltered: false))
        XCTAssertNil(s.selection, "§4.5: a selected row no longer listed deselects")
        XCTAssertEqual(s.paneContent, .noSelection)
        XCTAssertEqual(s.hiddenRecentCount, 5)
    }

    func testSelectedRowStillInsideTheCapStaysSelected() {
        var s = state(results: results(100), columns: .two)
        s.handle(.rowClicked(.conversation(sessionID: "c10")))
        s.handle(.historyDelivered([UL.summary("n0", updatedAt: 9_500)] + results(100), isFiltered: false))
        XCTAssertEqual(s.selection?.key, .conversation(sessionID: "c10"))
    }

    // MARK: - Display only: pruning and titles see the full result

    func testStarPruningSeesTheWholeResult() {
        // Stars on conversations Recent would not show (beyond the cap)
        // are in the result: a browse delivery keeps them and prunes only
        // the missing session, the others keeping their order.
        let starred = (100..<150).reversed().map { "c\($0)" }
        var s = UnifiedListState(home: UL.home, now: UL.now, stars: StarredList(["gone"] + starred))
        let effects = s.handle(.historyDelivered(results(150), isFiltered: false))
        XCTAssertEqual(effects, [.persistStars(starred)])
        XCTAssertEqual(s.stars.sessionIDs, starred)
        XCTAssertEqual(s.starredRows.map(\.sessionID), starred)
        XCTAssertEqual(s.recentRows.map(\.sessionID), (0..<100).map { "c\($0)" })
        XCTAssertEqual(s.hiddenRecentCount, 0)
    }

    func testRunningTitleLookupSeesResultsBeyondTheCap() {
        var all = results(250)
        all[200] = UL.summary("c200", title: "Deep title", updatedAt: all[200].updatedAt)
        let s = state(results: all, agents: [UL.agent("t1", session: "c200")])
        XCTAssertEqual(s.runningRows.first?.title, "Deep title")
        XCTAssertEqual(s.recentRows.count, 100)
        XCTAssertEqual(s.hiddenRecentCount, 149)
    }
}
