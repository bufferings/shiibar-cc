import XCTest

@testable import ShiibarCcCore

/// Row composition for the unified list (M44 T1; DESIGN.md §4.5 "Running
/// rows" / "action buttons", §4.6 "History section" / "stars" / "search scope").
final class UnifiedListRowsTests: XCTestCase {
    // MARK: - Running line 1 fallback order (§4.5)

    func testRunningLine1FallbackOrder() {
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
            XCTAssertEqual(row?.line1, c.expected, c.name)
        }
    }

    func testRunningTitleComesFromTheMatchingSearchResult() {
        let agents = [UL.agent("t1", session: "s1", task: "task text")]
        let withTitle = UnifiedListBuilder.runningRows(
            agents: agents, results: [UL.summary("s1", title: "Indexed title")],
            isFiltered: false, now: UL.now, home: UL.home)
        XCTAssertEqual(withTitle.map(\.line1), ["Indexed title"])
        let nullTitle = UnifiedListBuilder.runningRows(
            agents: agents, results: [UL.summary("s1", title: nil)],
            isFiltered: false, now: UL.now, home: UL.home)
        XCTAssertEqual(nullTitle.map(\.line1), ["task text"])
        let noResults = UnifiedListBuilder.runningRows(
            agents: agents, results: nil, isFiltered: false, now: UL.now, home: UL.home)
        XCTAssertEqual(noResults.map(\.line1), ["task text"])
    }

    // MARK: - Line 2 / line 3

    func testLine3ReplacesNewlinesAndIsEmptyWithoutTask() {
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
            XCTAssertEqual(row?.lastPrompt, c.expected, String(describing: c.task))
        }
    }

    func testLine2AndHeader() {
        let running = UnifiedListBuilder.runningRow(
            agent: UL.agent("t", session: "s", since: UL.now - 240), title: "T", now: UL.now, home: UL.home)!
        XCTAssertEqual(running.line2, "demo/api \u{00B7} 4m")
        XCTAssertFalse(running.showsRunningMark)
        XCTAssertEqual(running.headerSubtitle, "~/demo/api \u{00B7} 4m ago")

        let live = UnifiedListBuilder.historyRow(
            summary: UL.summary("s", updatedAt: UL.now - 300, live: true), isStarred: false, now: UL.now, home: UL.home)
        XCTAssertEqual(live.line2, "demo/web \u{00B7} 5m \u{00B7} running")
        XCTAssertTrue(live.showsRunningMark)

        let noCwd = UnifiedListBuilder.historyRow(
            summary: UL.summary("s", cwd: nil, updatedAt: UL.now - 7200), isStarred: false, now: UL.now, home: UL.home)
        XCTAssertEqual(noCwd.headerSubtitle, "2h ago")
    }

    func testHistoryLinesAndTitleFallback() {
        let row = UnifiedListBuilder.historyRow(
            summary: UL.summary("s", title: nil, lastPrompt: "last thing I said"),
            isStarred: false, now: UL.now, home: UL.home)
        XCTAssertEqual(row.line1, "demo/web")
        XCTAssertEqual(row.headerTitle, "demo/web")
        XCTAssertEqual(row.lastPrompt, "last thing I said")
        XCTAssertEqual(row.leading, .star(isStarred: false))
        XCTAssertFalse(row.isLine1Bold)

        let noPrompt = UnifiedListBuilder.historyRow(
            summary: UL.summary("s", lastPrompt: nil), isStarred: true, now: UL.now, home: UL.home)
        XCTAssertNil(noPrompt.lastPrompt)
        XCTAssertEqual(noPrompt.leading, .star(isStarred: true))
        XCTAssertEqual(noPrompt.leading.tooltip, "Unstar")
        XCTAssertEqual(row.leading.tooltip, "Star")
    }

    func testRunningRowStatusAndUnreviewed() {
        let cases: [(AgentStatus, Bool, RowLeadingSlot?)] = [
            (.idle, false, .status(.idle, unreviewed: false)),
            (.working, false, .status(.working, unreviewed: false)),
            (.waiting, true, .status(.waiting, unreviewed: true)),
            (.unknown, false, nil),
        ]
        for (status, unreviewed, expected) in cases {
            let row = UnifiedListBuilder.runningRow(
                agent: UL.agent("t", status: status, session: "s", unreviewed: unreviewed),
                title: nil, now: UL.now, home: UL.home)
            XCTAssertEqual(row?.leading, expected, "\(status)")
            if let row { XCTAssertEqual(row.isLine1Bold, unreviewed) }
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
            "Permission", "an empty session_id shows the row's line 1 (§4.5)")
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

    func testHistoryExcludesRunningSessions() {
        let agents = [
            UL.agent("t1", session: "s1"),
            UL.agent("t2", session: ""),
            UL.agent("tu", status: .unknown, session: "s3"),
        ]
        let results = [UL.summary("s1"), UL.summary("s2"), UL.summary("s3")]
        let rows = UnifiedListBuilder.historyRows(results: results, agents: agents, stars: [], now: UL.now, home: UL.home)
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
        XCTAssertEqual(state.sections.map(\.title), ["Running", "History"])
        XCTAssertEqual(state.sections.map(\.count), [1, 2])

        // Browse: every Running row, including the empty session_id one.
        state.handle(.historyDelivered(results, isFiltered: false))
        XCTAssertEqual(state.sections.map(\.count), [3, 2])
        XCTAssertEqual(state.searchResultCount, 3)

        // A section with no rows is hidden, heading included.
        state.handle(.historyDelivered([UL.summary("s1")], isFiltered: true))
        XCTAssertEqual(state.sections.map(\.title), ["Running"])
        XCTAssertEqual(state.sections.map(\.count), [1])
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

    func testStarredRowsComeFirstKeepingResultOrder() {
        let results = [
            UL.summary("a", updatedAt: 50), UL.summary("b", updatedAt: 40),
            UL.summary("c", updatedAt: 30), UL.summary("d", updatedAt: 20),
        ]
        let rows = UnifiedListBuilder.historyRows(results: results, agents: [], stars: ["d", "b"], now: UL.now, home: UL.home)
        XCTAssertEqual(rows.map(\.sessionID), ["b", "d", "a", "c"])
        XCTAssertEqual(rows.map(\.leading), [
            .star(isStarred: true), .star(isStarred: true), .star(isStarred: false), .star(isStarred: false),
        ])
    }

    func testStarOnARunningConversationIsKeptButNotShown() {
        var state = UnifiedListState(home: UL.home, now: UL.now, stars: ["s1"])
        state.handle(.historyDelivered([UL.summary("h"), UL.summary("s1")], isFiltered: false))
        XCTAssertEqual(state.historyRows.first?.sessionID, "s1")
        state.handle(.agentsUpdated([UL.agent("t1", session: "s1")]))
        XCTAssertEqual(state.runningRows.first?.leading, .status(.idle, unreviewed: false))
        XCTAssertEqual(state.historyRows.map(\.sessionID), ["h"])
        XCTAssertEqual(state.stars, ["s1"], "the star is kept while running")
        state.handle(.agentsUpdated([]))
        XCTAssertEqual(state.historyRows.map(\.sessionID), ["s1", "h"], "back in the starred position")
    }

    func testStarSetRules() {
        XCTAssertEqual(StarredSessions.toggled(["a"], sessionID: "b"), ["a", "b"])
        XCTAssertEqual(StarredSessions.toggled(["a", "b"], sessionID: "a"), ["b"])
        XCTAssertEqual(
            StarredSessions.pruned(["a", "gone", "b"], browseResults: [UL.summary("a"), UL.summary("b"), UL.summary("c")]),
            ["a", "b"])
        XCTAssertEqual(StarredSessions.pruned(["a"], browseResults: []), [])
    }

    func testStarPruningOnlyOnBrowseResults() {
        var state = UnifiedListState(home: UL.home, now: UL.now, stars: ["a", "gone"])
        let filtered = state.handle(.historyDelivered([UL.summary("a")], isFiltered: true))
        XCTAssertEqual(state.stars, ["a", "gone"], "a filtered result never prunes")
        XCTAssertFalse(filtered.contains { if case .persistStars = $0 { return true } else { return false } })
        let browse = state.handle(.historyDelivered([UL.summary("a")], isFiltered: false))
        XCTAssertEqual(state.stars, ["a"])
        XCTAssertTrue(browse.contains(.persistStars(["a"])))
        let again = state.handle(.historyDelivered([UL.summary("a")], isFiltered: false))
        XCTAssertFalse(again.contains { if case .persistStars = $0 { return true } else { return false } },
                       "nothing to persist when unchanged")
    }

    func testStarPersistenceUsesInjectedDefaults() {
        let defaults = InMemoryDefaults()
        XCTAssertEqual(StarredSessions.load(from: defaults), [])
        StarredSessions.save(["b", "a"], to: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "cc.shiibar.starredSessionIDs"), ["a", "b"])
        XCTAssertEqual(StarredSessions.load(from: defaults), ["a", "b"])
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
