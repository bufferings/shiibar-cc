import XCTest

@testable import ShiibarCcCore

/// Row composition for the unified list (DESIGN.md §4.5 "Running
/// rows" / "action buttons", §4.6 "Recent section" / "stars" / "search scope").
final class UnifiedListRowsTests: XCTestCase {
    // MARK: - Running card title fallback order (§4.5)

    func testRunningCardTitleFallbackOrder() {
        struct Case {
            let name: String
            let agent: Agent
            let title: String?
            let expected: String
        }
        let cases = [
            Case(name: "waiting shows message over title",
                 agent: UL.agent("t", status: .waiting, session: "s", task: "do it", message: "Claude needs your permission"),
                 title: "Conversation title", expected: "Claude needs your permission"),
            Case(name: "waiting without message falls back to title (assumption)",
                 agent: UL.agent("t", status: .waiting, session: "s", task: "do it", message: nil),
                 title: "Conversation title", expected: "Conversation title"),
            Case(name: "idle shows title, not message",
                 agent: UL.agent("t", status: .idle, session: "s", task: "do it", message: "stale message"),
                 title: "Conversation title", expected: "Conversation title"),
            Case(name: "working shows title",
                 agent: UL.agent("t", status: .working, session: "s", task: "do it"),
                 title: "Conversation title", expected: "Conversation title"),
            Case(name: "no title -> task",
                 agent: UL.agent("t", status: .idle, session: "s", task: "do it"),
                 title: nil, expected: "do it"),
            Case(name: "empty title -> task",
                 agent: UL.agent("t", status: .idle, session: "s", task: "do it"),
                 title: "", expected: "do it"),
            Case(name: "no title, no task -> label",
                 agent: UL.agent("t", status: .idle, session: "s", task: nil),
                 title: nil, expected: "demo/api"),
            Case(name: "task fallback is single-line",
                 agent: UL.agent("t", status: .idle, session: "s", task: "line one\nline two"),
                 title: nil, expected: "line one line two"),
        ]
        for c in cases {
            let row = UnifiedListBuilder.runningRow(agent: c.agent, title: c.title, now: UL.now, home: UL.home)
            XCTAssertEqual(row?.title, c.expected, c.name)
        }
    }

    func testRunningTitleComesFromTheMatchingSearchResult() {
        let agents = [UL.agent("t1", session: "s1", task: "task text")]
        let withTitle = UnifiedListBuilder.runningRows(
            agents: agents, results: [UL.summary("s1", title: "Indexed title")],
            isFiltered: false, now: UL.now, home: UL.home)
        XCTAssertEqual(withTitle.map(\.title), ["Indexed title"])
        let nullTitle = UnifiedListBuilder.runningRows(
            agents: agents, results: [UL.summary("s1", title: nil)],
            isFiltered: false, now: UL.now, home: UL.home)
        XCTAssertEqual(nullTitle.map(\.title), ["task text"])
        let noResults = UnifiedListBuilder.runningRows(
            agents: agents, results: nil, isFiltered: false, now: UL.now, home: UL.home)
        XCTAssertEqual(noResults.map(\.title), ["task text"])
    }

    // MARK: - Label line / last prompt

    func testLastPromptReplacesNewlinesAndIsEmptyWithoutTask() {
        struct Case {
            let task: String?
            let expected: String?
        }
        let cases = [
            Case(task: "first\nsecond", expected: "first second"),
            Case(task: "a\r\nb\rc", expected: "a b c"),
            Case(task: "plain", expected: "plain"),
            Case(task: nil, expected: nil),
            Case(task: "", expected: nil),
        ]
        for c in cases {
            let row = UnifiedListBuilder.runningRow(
                agent: UL.agent("t", session: "s", task: c.task), title: nil, now: UL.now, home: UL.home)
            // The whole last-prompt text: no marker in front of the prompt (§4.5).
            XCTAssertEqual(row?.lastPrompt, c.expected, String(describing: c.task))
        }
    }

    /// §4.5 / §4.6: the label line is the label only (plus ` · running` on a
    /// live History row); the elapsed time goes to the symbol-and-time column.
    func testLabelLineAndHeader() {
        let running = UnifiedListBuilder.runningRow(
            agent: UL.agent("t", session: "s", since: UL.now - 240), title: "T", now: UL.now, home: UL.home)!
        XCTAssertEqual(running.labelLine, "demo/api")
        XCTAssertEqual(running.elapsedText, "4m")
        XCTAssertFalse(running.showsRunningMark)
        XCTAssertEqual(running.headerLabelAndElapsed, "demo/api \u{00B7} 4m ago")

        let live = UnifiedListBuilder.historyRow(
            summary: UL.summary("s", updatedAt: UL.now - 300, live: true), isStarred: false, now: UL.now, home: UL.home)
        XCTAssertEqual(live.labelLine, "demo/web \u{00B7} running")
        XCTAssertEqual(live.elapsedText, "5m")
        XCTAssertTrue(live.showsRunningMark)
        XCTAssertEqual(live.headerLabelAndElapsed, "demo/web \u{00B7} 5m ago", "no running mark in the header (§4.6)")

        let ended = UnifiedListBuilder.historyRow(
            summary: UL.summary("s", updatedAt: UL.now - 7200, live: false), isStarred: false, now: UL.now, home: UL.home)
        XCTAssertEqual(ended.labelLine, "demo/web")
        XCTAssertEqual(ended.elapsedText, "2h")
        XCTAssertFalse(ended.showsRunningMark)

        let noCwd = UnifiedListBuilder.historyRow(
            summary: UL.summary("s", cwd: nil, updatedAt: UL.now - 7200), isStarred: false, now: UL.now, home: UL.home)
        XCTAssertEqual(noCwd.headerLabelAndElapsed, "2h ago")
    }

    /// §4.6: the pane header's top line is the card's folder label (the last
    /// two path components — §4.5) and the elapsed time, never the full
    /// home-relative path, so the header and the card show the same text.
    func testHeaderTopLineIsTheCardLabelForDeepPaths() {
        let deepCwd = "/Users/example/work/clients/demo/menubar-app"
        let running = UnifiedListBuilder.runningRow(
            agent: UL.agent("t", session: "s", cwd: deepCwd, since: UL.now - 240), title: "T", now: UL.now, home: UL.home)!
        XCTAssertEqual(running.label, "demo/menubar-app")
        XCTAssertEqual(running.headerLabelAndElapsed, "demo/menubar-app \u{00B7} 4m ago")

        let history = UnifiedListBuilder.historyRow(
            summary: UL.summary("s", cwd: deepCwd, updatedAt: UL.now - 7200), isStarred: false, now: UL.now, home: UL.home)
        XCTAssertEqual(history.headerLabelAndElapsed, "demo/menubar-app \u{00B7} 2h ago")

        let outsideHome = UnifiedListBuilder.historyRow(
            summary: UL.summary("s", cwd: "/opt/build/demo/api", updatedAt: UL.now - 7200),
            isStarred: false, now: UL.now, home: UL.home)
        XCTAssertEqual(outsideHome.headerLabelAndElapsed, "demo/api \u{00B7} 2h ago")
    }

    func testHistoryLinesAndTitleFallback() {
        let row = UnifiedListBuilder.historyRow(
            summary: UL.summary("s", title: nil, lastPrompt: "last thing I said"),
            isStarred: false, now: UL.now, home: UL.home)
        XCTAssertEqual(row.title, "demo/web")
        XCTAssertEqual(row.headerTitle, "demo/web")
        XCTAssertEqual(row.lastPrompt, "last thing I said")
        XCTAssertEqual(row.symbol, .star(isStarred: false))

        let noPrompt = UnifiedListBuilder.historyRow(
            summary: UL.summary("s", lastPrompt: nil), isStarred: true, now: UL.now, home: UL.home)
        XCTAssertNil(noPrompt.lastPrompt)
        XCTAssertEqual(noPrompt.symbol, .star(isStarred: true))
        XCTAssertEqual(noPrompt.symbol.tooltip, "Unstar")
        XCTAssertEqual(row.symbol.tooltip, "Star")
    }

    func testRunningRowStatusAndUnreviewed() {
        let cases: [(AgentStatus, Bool, RowColumnSymbol?)] = [
            (.idle, false, .status(.idle, unreviewed: false)),
            (.working, false, .status(.working, unreviewed: false)),
            (.waiting, true, .status(.waiting, unreviewed: true)),
            (.unknown, false, nil),
        ]
        for (status, unreviewed, expected) in cases {
            let row = UnifiedListBuilder.runningRow(
                agent: UL.agent("t", status: status, session: "s", unreviewed: unreviewed),
                title: nil, now: UL.now, home: UL.home)
            XCTAssertEqual(row?.symbol, expected, "\(status)")
        }
    }

    /// §4.5: unreviewed is shown only by the badge on the status symbol; the
    /// card's text is the same whether the row is unreviewed or not.
    func testUnreviewedChangesOnlyTheSymbolBadge() {
        for status in [AgentStatus.idle, .working, .waiting] {
            let reviewed = UnifiedListBuilder.runningRow(
                agent: UL.agent("t", status: status, session: "s", task: "task", message: "Permission",
                                unreviewed: false),
                title: "Title", now: UL.now, home: UL.home)!
            let unreviewed = UnifiedListBuilder.runningRow(
                agent: UL.agent("t", status: status, session: "s", task: "task", message: "Permission",
                                unreviewed: true),
                title: "Title", now: UL.now, home: UL.home)!
            XCTAssertEqual(unreviewed.title, reviewed.title, "\(status)")
            XCTAssertEqual(unreviewed.labelLine, reviewed.labelLine, "\(status)")
            XCTAssertEqual(unreviewed.lastPrompt, reviewed.lastPrompt, "\(status)")
            XCTAssertNotEqual(unreviewed.symbol, reviewed.symbol, "\(status)")
        }
    }

    func testHeaderTitleOfRunningRows() {
        let waiting = UL.agent("t", status: .waiting, session: "s", task: "task", message: "Permission")
        XCTAssertEqual(
            UnifiedListBuilder.runningRow(agent: waiting, title: "Title", now: UL.now, home: UL.home)?.headerTitle,
            "Title", "the header shows the title, not the waiting message")
        let noSession = UL.agent("t", status: .waiting, session: "", task: "task", message: "Permission")
        XCTAssertEqual(
            UnifiedListBuilder.runningRow(agent: noSession, title: nil, now: UL.now, home: UL.home)?.headerTitle,
            "Permission", "an empty session_id shows the row's card title (§4.5)")
    }

    // MARK: - Ordering, exclusion, search scope

    func testRunningRowsAreNewestSessionFirst() {
        let agents = [
            UL.agent("a", session: "sa", createdAt: 10),
            UL.agent("b", session: "sb", createdAt: 30),
            UL.agent("c", session: "sc", createdAt: 20),
            UL.agent("d", session: "sd", createdAt: 20),
            UL.agent("u", status: .unknown, session: "su", createdAt: 99),
        ]
        let rows = UnifiedListBuilder.runningRows(agents: agents, results: nil, isFiltered: false, now: UL.now, home: UL.home)
        XCTAssertEqual(rows.map(\.id), [.running(target: "b"), .running(target: "c"), .running(target: "d"), .running(target: "a")])
    }

    func testRecentExcludesRunningSessions() {
        let agents = [
            UL.agent("t1", session: "s1"),
            UL.agent("t2", session: ""),
            UL.agent("tu", status: .unknown, session: "s3"),
        ]
        let results = [UL.summary("s1"), UL.summary("s2"), UL.summary("s3")]
        let rows = UnifiedListBuilder.conversationRows(results: results, agents: agents, stars: [], now: UL.now, home: UL.home).recent
        // s1 is running; an empty agent session_id excludes nothing; an
        // unknown-status agent has no Running row so it excludes nothing.
        XCTAssertEqual(rows.map(\.sessionID), ["s2", "s3"])
    }

    func testSearchScopeFiltersRunningAndCountsShownRows() {
        let agents = [
            UL.agent("t1", session: "s1", createdAt: 3),
            UL.agent("t2", session: "s2", createdAt: 2),
            UL.agent("t3", session: "", createdAt: 1),
        ]
        let results = [UL.summary("s2"), UL.summary("h1"), UL.summary("h2")]

        var state = UnifiedListState(home: UL.home, now: UL.now)
        state.handle(.agentsUpdated(agents))
        state.handle(.historyDelivered(results, isFiltered: true))
        XCTAssertEqual(state.runningRows.map(\.id), [.running(target: "t2")])
        XCTAssertEqual(state.headings.map(\.title), ["Running", "History"])
        XCTAssertEqual(state.headings.map(\.countText), ["1", "2"])

        // Browse: every Running row, including the empty session_id one.
        state.handle(.historyDelivered(results, isFiltered: false))
        XCTAssertEqual(state.headings.map(\.countText), ["3", "2"])

        // A section with no rows is hidden, heading included.
        state.handle(.historyDelivered([UL.summary("s1")], isFiltered: true))
        XCTAssertEqual(state.headings.map(\.title), ["Running"])
        XCTAssertEqual(state.headings.map(\.countText), ["1"])
    }

    func testEmptyStateText() {
        var state = UnifiedListState(home: UL.home, now: UL.now)
        XCTAssertNil(state.emptyStateText, "nothing before the first search result after launch")
        state.handle(.historyFetchFailed)
        XCTAssertNil(state.emptyStateText, "a failed first fetch delivers no result")
        state.handle(.historyDelivered([], isFiltered: false))
        XCTAssertEqual(state.emptyStateText, "No conversations")
        state.handle(.historyDelivered([], isFiltered: true))
        XCTAssertEqual(state.emptyStateText, "No matching conversations")
        state.handle(.fullBuildChanged(true))
        XCTAssertNil(state.emptyStateText, "suppressed during a full build")
        state.handle(.fullBuildChanged(false))
        XCTAssertNil(state.emptyStateText, "after a full build, nothing until the search delivers")
        state.handle(.historyDelivered([], isFiltered: false))
        XCTAssertEqual(state.emptyStateText, "No conversations")
        state.handle(.agentsUpdated([UL.agent("t", session: "s")]))
        XCTAssertNil(state.emptyStateText, "a Running row is enough")
    }

    // MARK: - Stars

    /// §4.6 "Starred section" / "Recent section": starred conversations
    /// form Starred in the stars' order; Recent keeps the rest newest
    /// first. A Starred row has the filled star (`Unstar`), a Recent row
    /// the hover star (`Star`).
    func testStarredAndRecentRowsSplitByTheStars() {
        let results = [
            UL.summary("a", updatedAt: 50), UL.summary("b", updatedAt: 40),
            UL.summary("c", updatedAt: 30), UL.summary("d", updatedAt: 20),
        ]
        let rows = UnifiedListBuilder.conversationRows(
            results: results, agents: [], stars: ["d", "b"], now: UL.now, home: UL.home)
        XCTAssertEqual(rows.starred.map(\.sessionID), ["d", "b"], "the stars' order, not the newest first")
        XCTAssertEqual(rows.recent.map(\.sessionID), ["a", "c"])
        XCTAssertEqual(rows.starred.map(\.section), [.starred, .starred])
        XCTAssertEqual(rows.recent.map(\.section), [.recent, .recent])
        XCTAssertEqual(rows.starred.map(\.symbol), [.star(isStarred: true), .star(isStarred: true)])
        XCTAssertEqual(rows.starred.first?.symbol.tooltip, "Unstar")
        XCTAssertEqual(rows.recent.first?.symbol.tooltip, "Star")
        XCTAssertEqual(rows.starred.first?.id, .conversation(sessionID: "d"), "Starred and Recent share the key")
    }

    func testStarredRowsHaveTheRecentRowsContentAndButtons() {
        let summary = UL.summary("s", cwd: nil, updatedAt: UL.now - 300, live: true, lastPrompt: "hi")
        let starred = UnifiedListBuilder.historyRow(summary: summary, isStarred: true, now: UL.now, home: UL.home)
        let recent = UnifiedListBuilder.historyRow(summary: summary, isStarred: false, now: UL.now, home: UL.home)
        XCTAssertEqual(starred.labelLine, recent.labelLine)
        XCTAssertTrue(starred.showsRunningMark)
        XCTAssertEqual(starred.lastPrompt, recent.lastPrompt)
        XCTAssertEqual(starred.primaryButton, recent.primaryButton)
        XCTAssertEqual(starred.branchButton, recent.branchButton)
        XCTAssertFalse(starred.branchButton.isEnabled, "no cwd: Branch disabled")
    }

    func testStarOnARunningConversationShowsOnlyInRunning() {
        // §4.6 "stars": while running, only in Running; the star and its
        // place in the list are kept, and it returns there when it ends.
        var state = UnifiedListState(home: UL.home, now: UL.now, stars: ["x", "s1", "y"])
        state.handle(.historyDelivered([UL.summary("h"), UL.summary("y"), UL.summary("s1"), UL.summary("x")],
                                       isFiltered: false))
        XCTAssertEqual(state.starredRows.map(\.sessionID), ["x", "s1", "y"])
        state.handle(.agentsUpdated([UL.agent("t1", session: "s1")]))
        XCTAssertEqual(state.runningRows.first?.symbol, .status(.idle, unreviewed: false))
        XCTAssertEqual(state.starredRows.map(\.sessionID), ["x", "y"])
        XCTAssertEqual(state.recentRows.map(\.sessionID), ["h"])
        XCTAssertEqual(state.stars, ["x", "s1", "y"], "the star and its place are kept while running")
        state.handle(.agentsUpdated([]))
        XCTAssertEqual(state.starredRows.map(\.sessionID), ["x", "s1", "y"], "back at its place in the list")
    }

    // MARK: - Buttons (§4.5 "action buttons", §4.6)

    func testButtonStates() {
        struct Case {
            let name: String
            let row: UnifiedListRow
            let primary: RowButton
            let branch: RowButton
        }
        let cwd = "/Users/example/demo/api"
        let untracked = RowButton.untrackedRunningTooltip
        func running(_ session: String, cwd: String) -> UnifiedListRow {
            UnifiedListBuilder.runningRow(agent: UL.agent("iterm2:w1t1p1", session: session, cwd: cwd),
                                          title: nil, now: UL.now, home: UL.home)!
        }
        func history(_ summary: ConversationSummary) -> UnifiedListRow {
            UnifiedListBuilder.historyRow(summary: summary, isStarred: false, now: UL.now, home: UL.home)
        }
        let cases = [
            Case(name: "running: Jump + Branch",
                 row: running("s", cwd: cwd),
                 primary: RowButton(kind: .jump, invocation: .jump(target: "iterm2:w1t1p1"), tooltip: "Jump"),
                 branch: RowButton(kind: .branch, invocation: .branch(sessionID: "s", cwd: cwd), tooltip: "Branch")),
            Case(name: "running with empty session_id: Branch disabled",
                 row: running("", cwd: cwd),
                 primary: RowButton(kind: .jump, invocation: .jump(target: "iterm2:w1t1p1"), tooltip: "Jump"),
                 branch: RowButton(kind: .branch, invocation: nil, tooltip: "Branch")),
            Case(name: "running with empty cwd: Branch disabled",
                 row: running("s", cwd: ""),
                 primary: RowButton(kind: .jump, invocation: .jump(target: "iterm2:w1t1p1"), tooltip: "Jump"),
                 branch: RowButton(kind: .branch, invocation: nil, tooltip: "Branch")),
            Case(name: "history: Resume + Branch",
                 row: history(UL.summary("s", cwd: cwd)),
                 primary: RowButton(kind: .resume, invocation: .resume(sessionID: "s", cwd: cwd), tooltip: "Resume"),
                 branch: RowButton(kind: .branch, invocation: .branch(sessionID: "s", cwd: cwd), tooltip: "Branch")),
            Case(name: "history without cwd: both disabled, tooltips unchanged",
                 row: history(UL.summary("s", cwd: nil)),
                 primary: RowButton(kind: .resume, invocation: nil, tooltip: "Resume"),
                 branch: RowButton(kind: .branch, invocation: nil, tooltip: "Branch")),
            Case(name: "history with empty cwd: both disabled",
                 row: history(UL.summary("s", cwd: "")),
                 primary: RowButton(kind: .resume, invocation: nil, tooltip: "Resume"),
                 branch: RowButton(kind: .branch, invocation: nil, tooltip: "Branch")),
            Case(name: "history live (untracked terminal): disabled Jump, Branch enabled",
                 row: history(UL.summary("s", cwd: cwd, live: true)),
                 primary: RowButton(kind: .jump, invocation: nil, tooltip: untracked),
                 branch: RowButton(kind: .branch, invocation: .branch(sessionID: "s", cwd: cwd), tooltip: "Branch")),
            Case(name: "history live without cwd: disabled Jump and Branch",
                 row: history(UL.summary("s", cwd: nil, live: true)),
                 primary: RowButton(kind: .jump, invocation: nil, tooltip: untracked),
                 branch: RowButton(kind: .branch, invocation: nil, tooltip: "Branch")),
        ]
        for c in cases {
            XCTAssertEqual(c.row.primaryButton, c.primary, c.name)
            XCTAssertEqual(c.row.branchButton, c.branch, c.name)
            XCTAssertEqual(c.row.primaryButton.isEnabled, c.primary.invocation != nil, c.name)
        }
    }

    func testConversationActionRunningDerive() {
        let agent = UL.agent("apple-terminal:abc", session: "s")
        XCTAssertEqual(ConversationAction.derive(forRunningAgent: agent), .jump(target: "apple-terminal:abc"))
    }

    // MARK: - last_prompt decoding (§4.4)

    func testSearchResultDecodesLastPrompt() throws {
        let present = try XCTUnwrap(ConversationSearchResult.decode(
            #"{"conversations":[{"session_id":"s","cwd":"/Users/example/a","title":"T","updated_at":5,"live":false,"last_prompt":"hello"}]}"#))
        XCTAssertEqual(present.conversations.first?.lastPrompt, "hello")
        let null = try XCTUnwrap(ConversationSearchResult.decode(
            #"{"conversations":[{"session_id":"s","cwd":null,"title":null,"updated_at":5,"live":true,"last_prompt":null}]}"#))
        XCTAssertNil(null.conversations.first?.lastPrompt)
        let missing = try XCTUnwrap(ConversationSearchResult.decode(
            #"{"conversations":[{"session_id":"s","cwd":null,"title":null,"updated_at":5,"live":true}]}"#))
        XCTAssertNil(missing.conversations.first?.lastPrompt)
    }
}
