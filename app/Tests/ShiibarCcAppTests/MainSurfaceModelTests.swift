import ShiibarCcCore
import XCTest
@testable import ShiibarCcApp

/// The shared model of the popover and the window (M44; DESIGN.md §4.5 /
/// §4.6): the search pipeline (debounce, NFC, stale results, ⟳), index on
/// open, the row verbs and their outcomes, keys, stars, the pin, and the
/// message line. Every outward action is a spy — no real subprocess,
/// pasteboard, browser, state dir, or `UserDefaults.standard`. CJK fixture
/// text is written as unicode escapes (repo language rule).
@MainActor
final class MainSurfaceModelTests: XCTestCase {
    private struct Dispatched {
        let arguments: [String]
        let completion: @MainActor (CLIRunResult) -> Void
    }

    private final class Spy {
        var searches: [Dispatched] = []
        var shows: [Dispatched] = []
        var indexLines: [@MainActor (String) -> Void] = []
        var indexCompletions: [@MainActor (Int32) -> Void] = []
        var commands: [(arguments: [String], completion: @MainActor (Int32) -> Void)] = []
        var closePopoverCount = 0
        var permissionDeniedCount = 0
        var keepOnTopChanges: [Bool] = []
        var surfaceShownCount = 0
        /// `onFocusList` calls (the AppKit layer resigns the search field).
        var focusListSurfaces: [MainSurface] = []
        /// Delayed actions handed to the injected scheduler (never run by
        /// the clock — a test fires them explicitly).
        var scheduled: [(seconds: Double, action: @MainActor () -> Void)] = []
    }

    private var spy = Spy()
    private var defaults = InMemoryDefaults()

    override func setUp() {
        super.setUp()
        defaults = InMemoryDefaults()
    }

    private func makeModel() -> MainSurfaceModel {
        spy = Spy()
        let spy = self.spy
        let launchers = ConversationsLaunchers(
            search: { arguments, _, completion in
                spy.searches.append(Dispatched(arguments: arguments, completion: completion))
                return ConversationsProcess(process: Process())
            },
            show: { arguments, _, completion in
                spy.shows.append(Dispatched(arguments: arguments, completion: completion))
                return ConversationsProcess(process: Process())
            },
            index: { _, _, onLine, completion in
                spy.indexLines.append(onLine)
                spy.indexCompletions.append(completion)
                return ConversationsProcess(process: Process())
            }
        )
        let model = MainSurfaceModel(
            home: "/Users/example",
            defaults: defaults,
            textSize: ConversationsTextSizeStore(defaults: defaults),
            launchers: launchers,
            runCommand: { arguments, completion in
                spy.commands.append((arguments: arguments, completion: completion))
            },
            resumeTerminal: { "apple-terminal" },
            schedule: { seconds, action in spy.scheduled.append((seconds: seconds, action: action)) }
        )
        model.onClosePopover = { spy.closePopoverCount += 1 }
        model.onPermissionDenied = { spy.permissionDeniedCount += 1 }
        model.onKeepOnTopChanged = { spy.keepOnTopChanges.append($0) }
        model.onSurfaceShown = { spy.surfaceShownCount += 1 }
        model.onFocusList = { spy.focusListSurfaces.append($0) }
        return model
    }

    private func summaryJSON(_ id: String, live: Bool = false, cwd: String? = "/Users/example/demo") -> String {
        let cwdValue = cwd.map { "\"\($0)\"" } ?? "null"
        return #"{"session_id":"\#(id)","cwd":\#(cwdValue),"title":"title \#(id)","updated_at":1,"live":\#(live),"last_prompt":null}"#
    }

    private func resultJSON(_ ids: [String]) -> String {
        #"{"conversations":[\#(ids.map { summaryJSON($0) }.joined(separator: ","))]}"#
    }

    private func ok(_ stdout: String) -> CLIRunResult {
        CLIRunResult(exitCode: 0, stdout: stdout, stderr: "")
    }

    private func pump(until condition: () -> Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func waitForSearches(_ count: Int) {
        pump(until: { spy.searches.count >= count })
    }

    /// Show the popover with a warm index and deliver `ids` as History.
    private func openPopover(_ model: MainSurfaceModel, delivering ids: [String]) {
        model.surfaceDidShow(.popover)
        XCTAssertEqual(spy.indexCompletions.count, 1, "showing runs the index once")
        spy.indexCompletions.last?(0)
        XCTAssertEqual(spy.searches.count, 1, "the index is followed by a search")
        spy.searches[0].completion(ok(resultJSON(ids)))
    }

    private func agent(_ target: String, session: String) -> Agent {
        Agent(target: target, status: .idle, unreviewed: false, sessionId: session,
              cwd: "/Users/example/demo", task: nil, message: nil, createdAt: 1, since: 0, lastSeen: 0)
    }

    // "left-navi" in katakana; NFD writes hi (U+30D2) + combining dakuten.
    private let navNFD = "\u{30EC}\u{30D5}\u{30C8}\u{30CA}\u{30D2}\u{3099}"
    private let navNFC = "\u{30EC}\u{30D5}\u{30C8}\u{30CA}\u{30D3}"

    // MARK: - Search pipeline (§4.6)

    func testDecomposedQueryDispatchesComposed() {
        let model = makeModel()
        model.query = navNFD
        waitForSearches(1)
        XCTAssertEqual(spy.searches.first?.arguments, ["conversations", "search", navNFC, "--json"])
    }

    func testRapidTransitionsDispatchOnlyTheFinalQuery() {
        let model = makeModel()
        for step in ["\u{30EC}", "\u{30EC}\u{30D5}", "\u{30EC}\u{30D5}\u{30C8}", navNFC] {
            model.query = step
        }
        waitForSearches(1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(spy.searches.count, 1, "keystrokes inside the debounce collapse to one search")
        XCTAssertEqual(spy.searches[0].arguments, ["conversations", "search", navNFC, "--json"])
        spy.searches[0].completion(ok(resultJSON(["hit"])))
        XCTAssertEqual(model.list.historyRows.map(\.sessionID), ["hit"])
    }

    func testOneCharacterQueryBrowses() {
        let model = makeModel()
        model.query = "a"
        waitForSearches(1)
        XCTAssertEqual(spy.searches[0].arguments, ["conversations", "search", "--json"])
    }

    func testStaleResultNeverOverwritesTheNewest() {
        let model = makeModel()
        model.query = "left"
        waitForSearches(1)
        model.query = "left navi"
        waitForSearches(2)
        spy.searches[1].completion(ok(resultJSON(["new"])))
        spy.searches[0].completion(ok(resultJSON(["old-a", "old-b"])))
        XCTAssertEqual(model.list.historyRows.map(\.sessionID), ["new"])
    }

    func testCancelledSearchFailureDoesNotFlagAnError() {
        let model = makeModel()
        model.query = "left"
        waitForSearches(1)
        model.query = "left navi"
        waitForSearches(2)
        spy.searches[1].completion(ok(resultJSON(["new"])))
        spy.searches[0].completion(CLIRunResult(exitCode: 15, stdout: "", stderr: ""))
        XCTAssertNil(model.messageError)
        XCTAssertNil(model.messageText)
    }

    func testSearchFailureKeepsThePreviousListAndShowsTheError() {
        let model = makeModel()
        openPopover(model, delivering: ["a", "b"])
        model.query = "zz"
        waitForSearches(2)
        spy.searches[1].completion(CLIRunResult(exitCode: 1, stdout: "", stderr: ""))
        XCTAssertEqual(model.list.historyRows.map(\.sessionID), ["a", "b"])
        XCTAssertEqual(model.messageText, "Search failed")
        // §4.6: the error clears on the next successful fetch.
        model.refreshClicked()
        waitForSearches(3)
        spy.searches[2].completion(ok(resultJSON(["a"])))
        XCTAssertNil(model.messageError)
    }

    // MARK: - ⟳ (§4.6 / §8.44 / §9)

    func testRefreshHoldsTheMinimumTurnThenShowsUpdated() {
        let model = makeModel()
        model.refreshClicked()
        XCTAssertTrue(model.isRefreshing)
        XCTAssertEqual(model.messageText, "Refreshing\u{2026}")
        waitForSearches(1)
        spy.searches[0].completion(ok(resultJSON(["r1"])))
        XCTAssertEqual(model.list.historyRows.map(\.sessionID), ["r1"], "the result applies at once")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(model.isRefreshing, "the turn is not done at 0.3s")
        model.refreshClicked()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(spy.searches.count, 1, "a press during the turn is ignored")
        pump(until: { !model.isRefreshing }, timeout: 1.5)
        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(model.messageText, "Updated \u{00B7} 1 conversations")
    }

    func testRefreshFailureSettlesWithTheError() {
        let model = makeModel()
        model.refreshClicked()
        waitForSearches(1)
        spy.searches[0].completion(CLIRunResult(exitCode: 1, stdout: "", stderr: ""))
        pump(until: { !model.isRefreshing }, timeout: 1.5)
        XCTAssertEqual(model.messageText, "Search failed")
    }

    // MARK: - Opening a surface (§4.5 / §4.6)

    func testShowingRunsIndexThenSearchAndSelectsNothing() {
        let model = makeModel()
        openPopover(model, delivering: ["newest", "older"])
        XCTAssertEqual(spy.surfaceShownCount, 1, "the permission check re-runs on show")
        XCTAssertNil(model.list.selection, "no auto-select (§8.49)")
        XCTAssertTrue(spy.shows.isEmpty)
        XCTAssertEqual(model.list.columns, .one)
    }

    func testFullBuildDisablesSearchShowsProgressAndHidesHistory() {
        let model = makeModel()
        openPopover(model, delivering: ["a"])
        model.surfaceDidHide(.popover)
        model.surfaceDidShow(.popover)
        spy.indexLines[1](#"{"event":"start","total":4200,"full_build":true}"#)
        spy.indexLines[1](#"{"event":"progress","done":340,"total":4200}"#)
        XCTAssertTrue(model.list.isFullBuild)
        XCTAssertEqual(model.messageText, "Indexing 340 of 4,200\u{2026}")
        XCTAssertEqual(model.list.historyRows, [])
        XCTAssertNil(model.list.emptyStateText, "no empty line during a full build")
        model.query = "ab"
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(spy.searches.count, 1, "keystrokes issue no search during a full build")
        spy.indexCompletions[1](0)
        XCTAssertFalse(model.list.isFullBuild)
        XCTAssertNil(model.messageText)
        XCTAssertEqual(spy.searches.count, 2)
        XCTAssertEqual(spy.searches[1].arguments, ["conversations", "search", "ab", "--json"])
    }

    /// §4.6: an index run that is not a full build (any total) keeps the
    /// previous History, the selection, the page, and the search field.
    func testIncrementalIndexRunKeepsHistorySelectionPageAndSearchField() {
        for line in [
            #"{"event":"start","total":3,"full_build":false}"#,
            #"{"event":"start","total":4200}"#, // missing key = not a full build
        ] {
            let model = makeModel()
            openPopover(model, delivering: ["a", "b"])
            model.rowOpenClicked(.history(sessionID: "b"))
            XCTAssertEqual(model.list.page, .detail)
            let showsBefore = spy.shows.count
            model.surfaceDidHide(.popover)
            model.surfaceDidShow(.popover)
            spy.indexLines[1](line)
            spy.indexLines[1](#"{"event":"progress","done":1,"total":3}"#)
            XCTAssertFalse(model.list.isFullBuild, line)
            XCTAssertEqual(model.messageText, "Indexing 1 of 3\u{2026}", "progress still shows")
            XCTAssertEqual(model.list.historyRows.map(\.sessionID), ["a", "b"], "History stays: \(line)")
            XCTAssertEqual(model.list.selection?.key, .history(sessionID: "b"), line)
            XCTAssertEqual(model.list.page, .detail, line)
            XCTAssertEqual(spy.shows.count, showsBefore, "the page is not reloaded")
            spy.indexCompletions[1](0)
            XCTAssertNil(model.messageText)
            XCTAssertEqual(spy.searches.count, 2, "the index is followed by a search")
            spy.searches[1].completion(ok(resultJSON(["a", "b"])))
            XCTAssertEqual(model.list.selection?.key, .history(sessionID: "b"))
            XCTAssertEqual(model.list.page, .detail)
        }
    }

    func testKeystrokeDuringIncrementalRunIsSearched() {
        let model = makeModel()
        openPopover(model, delivering: ["a"])
        model.surfaceDidHide(.popover)
        model.surfaceDidShow(.popover)
        spy.indexLines[1](#"{"event":"start","total":5,"full_build":false}"#)
        model.query = "ab"
        waitForSearches(2)
        XCTAssertEqual(spy.searches.count, 2, "typing during an incremental run is not dropped")
        XCTAssertEqual(spy.searches[1].arguments, ["conversations", "search", "ab", "--json"])
        // The index finishing re-runs the search with the same query.
        spy.indexCompletions[1](0)
        XCTAssertEqual(spy.searches.last?.arguments, ["conversations", "search", "ab", "--json"])
        spy.searches.last?.completion(ok(resultJSON(["ab-hit"])))
        XCTAssertEqual(model.list.historyRows.map(\.sessionID), ["ab-hit"])
    }

    func testLaterStartFollowsTheLatestFullBuildFlag() {
        // A relayed full build hands over to this process's own incremental
        // catch-up: the latest start decides (§4.4 "consumers draw the
        // latest line").
        let model = makeModel()
        model.surfaceDidShow(.popover)
        spy.indexLines[0](#"{"event":"start","total":10,"full_build":true}"#)
        XCTAssertTrue(model.list.isFullBuild)
        spy.indexLines[0](#"{"event":"start","total":0,"full_build":false}"#)
        XCTAssertFalse(model.list.isFullBuild)
    }

    func testIndexFailureShowsTheErrorAndKeepsHistory() {
        let model = makeModel()
        openPopover(model, delivering: ["a"])
        model.surfaceDidHide(.popover)
        model.surfaceDidShow(.popover)
        spy.indexCompletions[1](1)
        XCTAssertEqual(model.messageText, "Indexing failed")
        XCTAssertEqual(model.list.historyRows.map(\.sessionID), ["a"])
        XCTAssertEqual(spy.searches.count, 1)
    }

    func testWindowKeyReRunsIndexAndColumnsFollowTheWidth() {
        let model = makeModel()
        model.windowColumnsChanged(.two)
        model.windowDidBecomeKey()
        XCTAssertEqual(model.visibleSurface, .window)
        XCTAssertEqual(model.list.columns, .two)
        XCTAssertEqual(spy.indexCompletions.count, 1)
        model.windowDidBecomeKey()
        XCTAssertEqual(spy.indexCompletions.count, 2, "becoming key again re-runs index -> search")
        model.windowColumnsChanged(.one)
        XCTAssertEqual(model.list.columns, .one)
    }

    // MARK: - Selection, pane, refetch

    func testRowClickLoadsTheConversationAndShowErrorsShowInThePane() {
        let model = makeModel()
        openPopover(model, delivering: ["a", "b"])
        model.rowOpenClicked(.history(sessionID: "b"))
        XCTAssertEqual(model.list.page, .detail)
        XCTAssertEqual(spy.shows.map(\.arguments), [["conversations", "show", "b", "--json"]])
        spy.shows[0].completion(CLIRunResult(exitCode: 2, stdout: "", stderr: ""))
        XCTAssertEqual(model.paneLoadError, MainSurfaceModel.unavailableText)
        XCTAssertEqual(model.list.historyRows.map(\.sessionID), ["a", "b"], "the list stays")
    }

    func testRunningRowRemovalRefetchesHistoryNowAndAgainLater() {
        let model = makeModel()
        model.agentsUpdated([agent("iterm2:T1", session: "s1")])
        XCTAssertTrue(spy.searches.isEmpty)
        XCTAssertTrue(spy.scheduled.isEmpty)
        model.agentsUpdated([])
        XCTAssertEqual(spy.searches.count, 1, "a Running row disappearing re-runs the search (§4.6)")
        XCTAssertEqual(spy.scheduled.map(\.seconds), [2], "and schedules a second one 2 s later (§9)")
        spy.scheduled[0].action()
        XCTAssertEqual(spy.searches.count, 2, "the second refetch")
        XCTAssertEqual(spy.searches[1].arguments, ["conversations", "search", "--json"])
    }

    func testSecondRefetchShowsTheEndedConversationAsPast() {
        // The first refetch still sees the ending process alive (`live`);
        // the delayed one sees it ended.
        let model = makeModel()
        model.agentsUpdated([agent("iterm2:T1", session: "s1")])
        openPopover(model, delivering: [])
        model.agentsUpdated([])
        spy.searches[1].completion(ok(#"{"conversations":[\#(summaryJSON("s1", live: true))]}"#))
        XCTAssertFalse(model.list.historyRows[0].primaryButton.isEnabled, "live: disabled Jump")
        spy.scheduled[0].action()
        spy.searches[2].completion(ok(#"{"conversations":[\#(summaryJSON("s1", live: false))]}"#))
        XCTAssertEqual(model.list.historyRows[0].primaryButton.kind, .resume)
        XCTAssertTrue(model.list.historyRows[0].primaryButton.isEnabled)
    }

    func testANewerRemovalReplacesThePendingSecondRefetch() {
        let model = makeModel()
        model.agentsUpdated([agent("iterm2:T1", session: "s1"), agent("iterm2:T2", session: "s2")])
        model.agentsUpdated([agent("iterm2:T2", session: "s2")])
        model.agentsUpdated([])
        XCTAssertEqual(spy.searches.count, 2)
        XCTAssertEqual(spy.scheduled.count, 2)
        spy.scheduled[0].action()
        XCTAssertEqual(spy.searches.count, 2, "the replaced schedule does nothing")
        spy.scheduled[1].action()
        XCTAssertEqual(spy.searches.count, 3)
    }

    // MARK: - In-body hits (§4.6 "hit navigation")

    private func showJSON(_ id: String, texts: [String]) -> String {
        let messages = texts.enumerated().map { index, text in
            #"{"seq":\#(index),"role":"\#(index % 2 == 0 ? "user" : "assistant")","text":"\#(text)"}"#
        }
        return #"{"session_id":"\#(id)","cwd":"/Users/example/demo","title":"t","messages":[\#(messages.joined(separator: ","))]}"#
    }

    /// Open the popover, deliver `a` (for `query` when given), and open its
    /// detail page with `texts` as the conversation.
    private func openDetail(_ model: MainSurfaceModel, query: String? = nil, texts: [String]) {
        openPopover(model, delivering: ["a"])
        if let query {
            model.query = query
            waitForSearches(2)
            spy.searches[1].completion(ok(resultJSON(["a"])))
        }
        model.rowOpenClicked(.history(sessionID: "a"))
        XCTAssertEqual(spy.shows.last?.arguments, ["conversations", "show", "a", "--json"])
        spy.shows.last?.completion(ok(showJSON("a", texts: texts)))
    }

    func testHitsAreComputedAfterShowStartingAtTheLatest() {
        let model = makeModel()
        openDetail(model, query: "needle", texts: ["a needle here", "no match", "needle and needle"])
        XCTAssertEqual(model.hits.count, 3)
        XCTAssertEqual(model.hits.map(\.messageIndex), [0, 2, 2], "document order")
        XCTAssertEqual(model.currentHitIndex, 2, "the initial position is the latest hit")
        XCTAssertEqual(model.hitCounterText, "3 of 3", "N counts from the oldest hit as 1")
    }

    func testCommandGMovesThroughTheHits() {
        let model = makeModel()
        openDetail(model, query: "needle", texts: ["needle one", "needle two", "needle three"])
        XCTAssertEqual(model.currentHitIndex, 2)
        let shiftG = ListKey.other(charactersIgnoringModifiers: "G") // shift-g arrives as "G"
        XCTAssertEqual(key(model, shiftG, [.command, .shift]), .consumed)
        XCTAssertEqual(model.currentHitIndex, 1, "⇧⌘G: toward older")
        XCTAssertEqual(model.hitCounterText, "2 of 3")
        XCTAssertEqual(key(model, .other(charactersIgnoringModifiers: "g"), [.command]), .consumed)
        XCTAssertEqual(model.currentHitIndex, 2, "⌘G: toward newer")
        XCTAssertEqual(key(model, .other(charactersIgnoringModifiers: "g"), [.command], searchFieldFocused: true),
                       .consumed, "⌘G works in both focus states")
        XCTAssertEqual(model.currentHitIndex, 0, "⌘G past the newest wraps to the oldest")
        XCTAssertEqual(model.hitCounterText, "1 of 3")
    }

    func testRetypingRecomputesHitsAndClearsThem() {
        let model = makeModel()
        openDetail(model, texts: ["alpha beta", "beta"])
        XCTAssertTrue(model.hits.isEmpty, "an empty query has no hits")
        XCTAssertNil(model.hitCounterText)
        model.query = "beta"
        XCTAssertEqual(model.hits.count, 2, "hits follow the query at once (no search round-trip)")
        XCTAssertEqual(model.hitCounterText, "2 of 2")
        model.query = "b"
        XCTAssertTrue(model.hits.isEmpty, "a 1-character query has no valid term")
    }

    func testDecomposedImeQueryFindsComposedTextInTheBody() {
        let model = makeModel()
        openDetail(model, query: navNFD, texts: ["see \(navNFC) here"])
        XCTAssertEqual(model.hits, [ConversationHit(messageIndex: 0, start: 4, length: 5)])
        XCTAssertEqual(model.hitCounterText, "1 of 1")
    }

    // MARK: - Row verbs (§4.5 "action buttons" / §4.6 "bottom panel")

    /// Click a row (select only — §4.5 "row click") and return the bottom
    /// panel's buttons for it on the one-column list page.
    private func panelButtons(_ model: MainSurfaceModel, selecting key: UnifiedRowKey,
                              file: StaticString = #filePath, line: UInt = #line) -> BottomPanelButtons? {
        model.rowClicked(key)
        XCTAssertEqual(model.list.page, .list, "a row click stays on the list page", file: file, line: line)
        let buttons = model.list.listBottomPanel?.buttons
        XCTAssertNotNil(buttons, "the list page's bottom panel shows the selected row's buttons", file: file, line: line)
        return buttons
    }

    func testRowClickSelectsAndTheOpenButtonOpensTheDetailPage() {
        let model = makeModel()
        openPopover(model, delivering: ["a", "b"])
        XCTAssertEqual(model.list.listBottomPanel, BottomPanelModel(hints: [.move], buttons: nil, showsShortcuts: true))
        model.rowClicked(.history(sessionID: "a"))
        XCTAssertEqual(model.list.page, .list)
        XCTAssertEqual(model.list.selection?.key, .history(sessionID: "a"))
        XCTAssertTrue(spy.shows.isEmpty, "a click never opens (or loads) the detail page")
        XCTAssertEqual(spy.focusListSurfaces, [.popover], "a click moves focus to the list")
        let paneFocus = model.paneFocusRequests[.popover] ?? 0
        model.rowOpenClicked(.history(sessionID: "b"))
        XCTAssertEqual(model.list.page, .detail)
        XCTAssertEqual(model.list.selection?.key, .history(sessionID: "b"))
        XCTAssertEqual(spy.shows.map(\.arguments), [["conversations", "show", "b", "--json"]])
        XCTAssertEqual(model.paneFocusRequests[.popover], paneFocus + 1)
    }

    func testResumeRunsTheCliAndClosesThePopoverOnSuccess() {
        let model = makeModel()
        openPopover(model, delivering: ["a"])
        guard let buttons = panelButtons(model, selecting: .history(sessionID: "a")) else { return }
        model.buttonClicked(buttons.primary)
        XCTAssertEqual(spy.commands.map(\.arguments),
                       [["resume", "--cwd", "/Users/example/demo", "--terminal", "apple-terminal", "a"]])
        XCTAssertEqual(model.list.page, .list, "a button never changes the page")
        spy.commands[0].completion(0)
        XCTAssertEqual(spy.closePopoverCount, 1)
        XCTAssertEqual(spy.searches.count, 2, "a successful Resume re-runs the search")
    }

    func testBranchPassesForkAndJumpDoesNotRefetch() {
        let model = makeModel()
        model.agentsUpdated([agent("iterm2:T1", session: "s1")])
        openPopover(model, delivering: ["a"])
        guard let running = panelButtons(model, selecting: .running(target: "iterm2:T1")) else { return }
        model.buttonClicked(running.branch)
        XCTAssertEqual(spy.commands.last?.arguments,
                       ["resume", "--cwd", "/Users/example/demo", "--terminal", "apple-terminal", "--fork", "s1"])
        model.buttonClicked(running.primary)
        XCTAssertEqual(spy.commands.last?.arguments, ["focus", "iterm2:T1"])
        let searchesBefore = spy.searches.count
        spy.commands.last?.completion(0)
        XCTAssertEqual(spy.searches.count, searchesBefore, "Jump never re-runs the search")
        XCTAssertEqual(spy.closePopoverCount, 1)
    }

    func testFailureOutcomesKeepThePopoverOpen() {
        struct Case {
            let exitCode: Int32
            let jump: Bool
            let expectedMessage: String?
            let expectedPermissionDenied: Int
        }
        let cases = [
            Case(exitCode: 2, jump: true, expectedMessage: nil, expectedPermissionDenied: 0),
            Case(exitCode: 3, jump: true, expectedMessage: nil, expectedPermissionDenied: 1),
            Case(exitCode: 1, jump: true, expectedMessage: "Jump failed", expectedPermissionDenied: 0),
            Case(exitCode: 1, jump: false, expectedMessage: "Resume failed", expectedPermissionDenied: 0),
            Case(exitCode: 3, jump: false, expectedMessage: nil, expectedPermissionDenied: 1),
        ]
        for testCase in cases {
            let model = makeModel()
            model.agentsUpdated([agent("iterm2:T1", session: "s1")])
            openPopover(model, delivering: ["a"])
            let key: UnifiedRowKey = testCase.jump ? .running(target: "iterm2:T1") : .history(sessionID: "a")
            guard let buttons = panelButtons(model, selecting: key) else { return }
            model.buttonClicked(buttons.primary)
            spy.commands[0].completion(testCase.exitCode)
            XCTAssertEqual(spy.closePopoverCount, 0, "exit \(testCase.exitCode)")
            XCTAssertEqual(model.messageText, testCase.expectedMessage, "exit \(testCase.exitCode)")
            XCTAssertEqual(spy.permissionDeniedCount, testCase.expectedPermissionDenied, "exit \(testCase.exitCode)")
        }
    }

    func testSuccessInTheWindowDoesNotClosePopover() {
        let model = makeModel()
        model.windowDidBecomeKey()
        spy.indexCompletions[0](0)
        spy.searches[0].completion(ok(resultJSON(["a"])))
        guard let buttons = panelButtons(model, selecting: .history(sessionID: "a")) else { return }
        model.buttonClicked(buttons.primary)
        spy.commands[0].completion(0)
        XCTAssertEqual(spy.closePopoverCount, 0)
    }

    func testDisabledButtonRunsNothing() {
        let model = makeModel()
        model.surfaceDidShow(.popover)
        spy.indexCompletions[0](0)
        spy.searches[0].completion(ok(#"{"conversations":[\#(summaryJSON("x", cwd: nil))]}"#))
        guard let buttons = panelButtons(model, selecting: .history(sessionID: "x")) else { return }
        XCTAssertFalse(buttons.primary.isEnabled)
        XCTAssertFalse(buttons.branch.isEnabled)
        model.buttonClicked(buttons.primary)
        model.buttonClicked(buttons.branch)
        XCTAssertTrue(spy.commands.isEmpty)
    }

    // MARK: - Keys (§4.5)

    private func key(
        _ model: MainSurfaceModel, _ key: ListKey, _ modifiers: ListKeyModifiers = [],
        surface: MainSurface = .popover, marked: Bool = false, searchFieldFocused: Bool = false
    ) -> MainSurfaceModel.KeyRouting {
        model.handleKey(key: key, modifiers: modifiers, surface: surface,
                        hasMarkedText: marked, searchFieldFocused: searchFieldFocused)
    }

    func testKeyRouting() {
        let model = makeModel()
        openPopover(model, delivering: ["a", "b"])
        XCTAssertEqual(key(model, .escape, surface: .window), .consumed,
                       "Esc in the window is consumed (it must not clear the search field)")
        XCTAssertEqual(spy.closePopoverCount, 0)
        XCTAssertEqual(key(model, .escape, searchFieldFocused: true), .consumed)
        XCTAssertEqual(spy.closePopoverCount, 1)
        XCTAssertEqual(key(model, .downArrow, marked: true, searchFieldFocused: true), .passThrough,
                       "marked text: the input method gets every key")
        XCTAssertEqual(key(model, .returnKey, marked: true, searchFieldFocused: true), .passThrough)
        XCTAssertNil(model.list.selection)
        XCTAssertTrue(spy.focusListSurfaces.isEmpty)
        XCTAssertEqual(key(model, .rightArrow, searchFieldFocused: true), .passThrough, "→ moves the caret")
        XCTAssertEqual(key(model, .other(charactersIgnoringModifiers: "x"), searchFieldFocused: true), .passThrough)
        XCTAssertEqual(key(model, .other(charactersIgnoringModifiers: "c"), [.command]), .passThrough,
                       "⌘C belongs to the pane")
        XCTAssertEqual(key(model, .returnKey, [.command, .shift]), .passThrough, "⇧⌘Enter is not assigned")
    }

    /// §4.5: ↑ / ↓ and ⌘Enter in the search field do nothing (swallowed:
    /// no selection move, no focus move, no verb); Enter moves focus to the
    /// list, then Enter (list focus) runs the primary button and ⌘Enter runs
    /// Branch.
    func testSearchFieldEditsOnlyThenEnterResumesAndCommandEnterBranches() {
        let model = makeModel()
        openPopover(model, delivering: ["a", "b"])
        XCTAssertEqual(key(model, .downArrow, searchFieldFocused: true), .consumed)
        XCTAssertEqual(key(model, .upArrow, searchFieldFocused: true), .consumed)
        XCTAssertNil(model.list.selection, "↑ / ↓ in the search field: no selection")
        XCTAssertTrue(spy.focusListSurfaces.isEmpty, "↑ / ↓ in the search field: the focus stays")
        XCTAssertTrue(model.list.isSearchFieldFocused)
        XCTAssertEqual(key(model, .returnKey, [.command], searchFieldFocused: true), .consumed)
        XCTAssertTrue(spy.commands.isEmpty, "⌘Enter in the search field: nothing")
        XCTAssertNil(model.list.selection)

        XCTAssertEqual(key(model, .returnKey, searchFieldFocused: true), .consumed)
        XCTAssertEqual(model.list.selection?.key, .history(sessionID: "a"))
        XCTAssertEqual(spy.focusListSurfaces, [.popover], "focus moves to the list")
        XCTAssertEqual(key(model, .downArrow), .consumed)
        XCTAssertEqual(model.list.selection?.key, .history(sessionID: "b"), "↓ with list focus moves")
        XCTAssertEqual(key(model, .returnKey), .consumed)
        XCTAssertEqual(spy.commands.map(\.arguments),
                       [["resume", "--cwd", "/Users/example/demo", "--terminal", "apple-terminal", "b"]])
        XCTAssertEqual(key(model, .returnKey, [.command]), .consumed)
        XCTAssertEqual(spy.commands.last?.arguments,
                       ["resume", "--cwd", "/Users/example/demo", "--terminal", "apple-terminal", "--fork", "b"])
        // With a selection, ⌘Enter in the search field still does nothing.
        XCTAssertEqual(key(model, .returnKey, [.command], searchFieldFocused: true), .consumed)
        XCTAssertEqual(key(model, .downArrow, searchFieldFocused: true), .consumed)
        XCTAssertEqual(spy.commands.count, 2)
        XCTAssertEqual(model.list.selection?.key, .history(sessionID: "b"))
    }

    /// §4.5: Enter in the search field focuses the list, selecting the
    /// first row when nothing is selected — it never runs a verb; with no
    /// rows it does nothing.
    func testEnterInTheSearchField() {
        let model = makeModel()
        openPopover(model, delivering: [])
        XCTAssertEqual(key(model, .returnKey, searchFieldFocused: true), .consumed)
        XCTAssertNil(model.list.selection)
        XCTAssertTrue(spy.focusListSurfaces.isEmpty, "no rows: nothing")

        let withRows = makeModel()
        openPopover(withRows, delivering: ["a", "b"])
        XCTAssertEqual(key(withRows, .returnKey, searchFieldFocused: true), .consumed)
        XCTAssertEqual(withRows.list.selection?.key, .history(sessionID: "a"))
        XCTAssertEqual(spy.focusListSurfaces, [.popover])
        XCTAssertTrue(spy.commands.isEmpty, "Enter in the search field never runs Resume")
        // Back in the search field with a selection: focus only.
        withRows.rowClicked(.history(sessionID: "b"))
        XCTAssertEqual(key(withRows, .returnKey, searchFieldFocused: true), .consumed)
        XCTAssertEqual(withRows.list.selection?.key, .history(sessionID: "b"))
        XCTAssertTrue(spy.commands.isEmpty)
    }

    /// §4.5 "global hotkey": opened by the hotkey, the list takes focus on
    /// the shown surface (no selection: the first row); with no rows the
    /// search field does; on the detail page the conversation pane does.
    func testOpenedByHotKeyFocusesTheList() {
        let empty = makeModel()
        openPopover(empty, delivering: [])
        let searchRequests = empty.searchFocusRequests[.popover] ?? 0
        empty.openedByHotKey()
        XCTAssertEqual(empty.searchFocusRequests[.popover] ?? 0, searchRequests + 1, "no rows: the search field")
        XCTAssertTrue(spy.focusListSurfaces.isEmpty)

        let withRows = makeModel()
        openPopover(withRows, delivering: ["a", "b"])
        withRows.openedByHotKey()
        XCTAssertEqual(withRows.list.selection?.key, .history(sessionID: "a"))
        XCTAssertEqual(spy.focusListSurfaces, [.popover])
        XCTAssertTrue(spy.commands.isEmpty, "never runs a verb")

        withRows.rowOpenClicked(.history(sessionID: "b"))
        let paneRequests = withRows.paneFocusRequests[.popover] ?? 0
        withRows.openedByHotKey()
        XCTAssertEqual(withRows.list.page, .detail, "the detail page stays")
        XCTAssertEqual(withRows.paneFocusRequests[.popover] ?? 0, paneRequests + 1)
    }

    /// §4.5: list-focus Enter / ⌘Enter do nothing without a selection or
    /// with the button disabled.
    func testListEnterWithoutSelectionOrDisabledDoesNothing() {
        let model = makeModel()
        model.surfaceDidShow(.popover)
        spy.indexCompletions[0](0)
        spy.searches[0].completion(ok(#"{"conversations":[\#(summaryJSON("x", cwd: nil))]}"#))
        XCTAssertEqual(key(model, .returnKey), .consumed)
        XCTAssertEqual(key(model, .returnKey, [.command]), .consumed)
        model.rowClicked(.history(sessionID: "x"))
        XCTAssertEqual(key(model, .returnKey), .consumed)
        XCTAssertEqual(key(model, .returnKey, [.command]), .consumed)
        XCTAssertTrue(spy.commands.isEmpty)
    }

    /// §4.5: typing with list focus does nothing — the key is not assigned,
    /// so it passes on to the focused view (the conversation pane scrolls
    /// with Space); it never reaches the search field.
    func testTypingWithListFocusPassesThroughWithoutEffect() {
        let model = makeModel()
        openPopover(model, delivering: ["a", "b"])
        model.rowClicked(.history(sessionID: "a"))
        let searchFocus = model.searchFocusRequests[.popover] ?? 0
        for typed in [ListKey.other(charactersIgnoringModifiers: "t"), .other(charactersIgnoringModifiers: " "), .delete] {
            XCTAssertEqual(key(model, typed), .passThrough, "\(typed)")
        }
        XCTAssertEqual(model.searchFocusRequests[.popover] ?? 0, searchFocus, "the search field does not take focus")
        XCTAssertEqual(model.list.selection?.key, .history(sessionID: "a"))
        XCTAssertEqual(model.query, "")
        model.rowOpenClicked(.history(sessionID: "a"))
        XCTAssertEqual(key(model, .other(charactersIgnoringModifiers: " ")), .passThrough, "detail page: Space to the pane")
        XCTAssertEqual(model.list.page, .detail)

        let window = makeModel()
        window.windowColumnsChanged(.two)
        window.windowDidBecomeKey()
        let windowSearchFocus = window.searchFocusRequests[.window] ?? 0
        XCTAssertEqual(key(window, .other(charactersIgnoringModifiers: "t"), surface: .window), .passThrough)
        XCTAssertEqual(window.searchFocusRequests[.window] ?? 0, windowSearchFocus)
    }

    /// → / ← with list focus open and close the detail page; the focus
    /// follows (detail page: the pane; back: the list).
    func testArrowsOpenAndCloseTheDetailPage() {
        let model = makeModel()
        openPopover(model, delivering: ["a", "b"])
        XCTAssertEqual(key(model, .rightArrow), .consumed)
        XCTAssertEqual(model.list.page, .list, "no selection: nothing")
        model.rowClicked(.history(sessionID: "b"))
        let paneFocus = model.paneFocusRequests[.popover] ?? 0
        XCTAssertEqual(key(model, .rightArrow), .consumed)
        XCTAssertEqual(model.list.page, .detail)
        XCTAssertEqual(spy.shows.map(\.arguments), [["conversations", "show", "b", "--json"]])
        XCTAssertEqual(model.paneFocusRequests[.popover], paneFocus + 1)
        XCTAssertEqual(key(model, .returnKey), .consumed, "Enter on the detail page: Resume")
        XCTAssertEqual(spy.commands.last?.arguments.last, "b")
        XCTAssertEqual(model.list.page, .detail, "Enter no longer toggles the page")
        let focusList = spy.focusListSurfaces.count
        XCTAssertEqual(key(model, .leftArrow), .consumed)
        XCTAssertEqual(model.list.page, .list)
        XCTAssertEqual(spy.focusListSurfaces.count, focusList + 1, "back on the list page, the focus is the list")
    }

    /// §4.5: on the one-column detail page ↑ / ↓ go to the conversation
    /// pane (scrolling) and never switch conversations; ⌥↑ / ⌥↓ and the
    /// header's prev / next buttons switch to the previous / next row's
    /// conversation (nothing at the ends). ⌥↑ / ⌥↓ on the list page do
    /// nothing; in the search field they are text editing.
    func testDetailPageArrowsScrollAndOptionArrowsSwitch() {
        let model = makeModel()
        openPopover(model, delivering: ["a", "b"])
        model.rowClicked(.history(sessionID: "a"))
        XCTAssertEqual(key(model, .downArrow, [.option]), .consumed)
        XCTAssertEqual(model.list.selection?.key, .history(sessionID: "a"), "list page: ⌥↓ does nothing")
        XCTAssertEqual(key(model, .downArrow, [.option], searchFieldFocused: true), .passThrough,
                       "search field: ⌥↓ is text editing")
        model.rowOpenClicked(.history(sessionID: "a"))
        XCTAssertEqual(model.list.page, .detail)
        for arrow in [ListKey.downArrow, .upArrow] {
            XCTAssertEqual(key(model, arrow), .passToConversationPane, "\(arrow)")
        }
        XCTAssertEqual(model.list.selection?.key, .history(sessionID: "a"), "↑ / ↓ do not switch")
        guard case .conversation(let pane) = model.list.paneContent else { return XCTFail("expected the pane") }
        XCTAssertEqual(pane.hints, [.prevNext, .back])

        XCTAssertEqual(key(model, .downArrow, [.option]), .consumed)
        XCTAssertEqual(model.list.selection?.key, .history(sessionID: "b"))
        XCTAssertEqual(model.list.page, .detail)
        XCTAssertEqual(spy.shows.last?.arguments, ["conversations", "show", "b", "--json"])
        XCTAssertEqual(key(model, .downArrow, [.option]), .consumed)
        XCTAssertEqual(model.list.selection?.key, .history(sessionID: "b"), "last row: nothing")
        XCTAssertEqual(key(model, .upArrow, [.option]), .consumed)
        XCTAssertEqual(model.list.selection?.key, .history(sessionID: "a"))

        model.nextConversationClicked()
        XCTAssertEqual(model.list.selection?.key, .history(sessionID: "b"))
        model.previousConversationClicked()
        XCTAssertEqual(model.list.selection?.key, .history(sessionID: "a"))
        XCTAssertEqual(model.list.page, .detail)
    }

    /// The focus location reported by the AppKit layer drives the key hints
    /// and the buttons' shortcut glyphs; a report from the surface that is
    /// not on screen is ignored.
    func testSearchFieldFocusReportsDriveHintsAndGlyphs() {
        let model = makeModel()
        openPopover(model, delivering: ["a"])
        model.rowClicked(.history(sessionID: "a"))
        XCTAssertEqual(model.list.footerHints, [.move, .open])
        XCTAssertEqual(model.list.listBottomPanel?.showsShortcuts, true)
        model.searchFieldFocusChanged(surface: .popover, focused: true)
        XCTAssertEqual(model.list.footerHints, [.list])
        XCTAssertEqual(model.list.listBottomPanel?.showsShortcuts, false)
        XCTAssertNotNil(model.list.listBottomPanel?.buttons, "the buttons stay")
        model.searchFieldFocusChanged(surface: .window, focused: false)
        XCTAssertEqual(model.list.footerHints, [.list], "the hidden window's report is ignored")
        // A key event carries the live focus location too.
        XCTAssertEqual(key(model, .escape, surface: .window, searchFieldFocused: false), .consumed)
        XCTAssertFalse(model.list.isSearchFieldFocused)
        XCTAssertEqual(model.list.footerHints, [.move, .open])
        XCTAssertEqual(model.list.listBottomPanel?.showsShortcuts, true)
    }

    /// §4.6: the buttons stay clickable while the search field has focus.
    func testButtonClickWorksWithSearchFieldFocus() {
        let model = makeModel()
        openPopover(model, delivering: ["a"])
        model.rowClicked(.history(sessionID: "a"))
        model.searchFieldFocusChanged(surface: .popover, focused: true)
        guard let buttons = model.list.listBottomPanel?.buttons else { return XCTFail("expected buttons") }
        model.buttonClicked(buttons.primary)
        XCTAssertEqual(spy.commands.map(\.arguments),
                       [["resume", "--cwd", "/Users/example/demo", "--terminal", "apple-terminal", "a"]])
    }

    /// §4.5 "row click": clicking the selected row deselects it.
    func testClickOnTheSelectedRowDeselects() {
        let model = makeModel()
        openPopover(model, delivering: ["a"])
        model.rowClicked(.history(sessionID: "a"))
        XCTAssertNotNil(model.list.listBottomPanel?.buttons)
        model.rowClicked(.history(sessionID: "a"))
        XCTAssertNil(model.list.selection)
        XCTAssertEqual(model.list.listBottomPanel, BottomPanelModel(hints: [.move], buttons: nil, showsShortcuts: true))
        XCTAssertEqual(spy.focusListSurfaces, [.popover, .popover], "each click moves focus to the list")
    }

    /// §4.5 "row click" through the model: the press snapshot from the
    /// AppKit layer's mouse-down monitor decides, even when the surface
    /// became key and the search field resigned before the row's action.
    func testRowClickOnTheSelectedRowUsesThePressSnapshot() {
        struct Case {
            let name: String
            let surfaceWasKey: Bool
            let searchFieldFocused: Bool
            let expectDeselect: Bool
        }
        let cases = [
            Case(name: "accent at the press", surfaceWasKey: true, searchFieldFocused: false, expectDeselect: true),
            Case(name: "search field focus at the press", surfaceWasKey: true, searchFieldFocused: true, expectDeselect: false),
            Case(name: "not key at the press", surfaceWasKey: false, searchFieldFocused: false, expectDeselect: false),
        ]
        for testCase in cases {
            let model = makeModel()
            openPopover(model, delivering: ["a", "b"])
            model.rowClicked(.history(sessionID: "a"))
            model.surfaceKeyChanged(surface: .popover, isKey: testCase.surfaceWasKey)
            model.searchFieldFocusChanged(surface: .popover, focused: testCase.searchFieldFocused)
            XCTAssertEqual(model.list.isSelectionActive, testCase.surfaceWasKey && !testCase.searchFieldFocused, testCase.name)
            model.pointerDown(surface: .popover, surfaceWasKey: testCase.surfaceWasKey,
                              searchFieldFocused: testCase.searchFieldFocused)
            // AppKit: the window becomes key and the search field resigns
            // before the row's click action runs.
            model.surfaceKeyChanged(surface: .popover, isKey: true)
            model.searchFieldFocusChanged(surface: .popover, focused: false)
            XCTAssertTrue(model.list.isSelectionActive, testCase.name)
            spy.focusListSurfaces = []
            model.rowClicked(.history(sessionID: "a"))
            // §4.5 "row double-click": the deselect waits for the
            // double-click interval (the injected scheduler).
            XCTAssertEqual(spy.scheduled.count, testCase.expectDeselect ? 1 : 0, testCase.name)
            spy.scheduled.forEach { $0.action() }
            XCTAssertEqual(model.list.selection?.key, testCase.expectDeselect ? nil : .history(sessionID: "a"), testCase.name)
            XCTAssertEqual(spy.focusListSurfaces, [.popover], "\(testCase.name): the click moves focus to the list")
        }
    }

    /// §4.5 "row double-click" through the model: a double-click runs Jump
    /// (Running row) or Resume (History row) with the spy, in the popover and
    /// in the window, from any row look; a single click on an accent row
    /// deselects only when the injected scheduler fires, after the system
    /// double-click interval counted from the press.
    func testDoubleClickRunsJumpOrResume() {
        struct Case {
            let name: String
            let surface: MainSurface
            let key: UnifiedRowKey
            let expected: [String]
        }
        let cases = [
            Case(name: "popover, Running", surface: .popover, key: .running(target: "iterm2:T1"),
                 expected: ["focus", "iterm2:T1"]),
            Case(name: "popover, History", surface: .popover, key: .history(sessionID: "a"),
                 expected: ["resume", "--cwd", "/Users/example/demo", "--terminal", "apple-terminal", "a"]),
            Case(name: "window, History", surface: .window, key: .history(sessionID: "a"),
                 expected: ["resume", "--cwd", "/Users/example/demo", "--terminal", "apple-terminal", "a"]),
        ]
        for testCase in cases {
            for preselect in [false, true] {
                let name = "\(testCase.name), preselected: \(preselect)"
                let model = makeModel()
                model.agentsUpdated([agent("iterm2:T1", session: "s1")])
                if testCase.surface == .popover {
                    openPopover(model, delivering: ["a"])
                } else {
                    model.windowDidBecomeKey()
                    spy.indexCompletions[0](0)
                    spy.searches[0].completion(ok(resultJSON(["a"])))
                }
                if preselect { model.rowClicked(testCase.key) }
                spy.focusListSurfaces = []
                model.pointerDown(surface: testCase.surface, surfaceWasKey: true, searchFieldFocused: false,
                                  clickCount: 1, pressedAt: 100)
                model.rowClicked(testCase.key)
                XCTAssertTrue(spy.commands.isEmpty, "\(name): the first click runs nothing")
                model.pointerDown(surface: testCase.surface, surfaceWasKey: true, searchFieldFocused: false,
                                  clickCount: 2, pressedAt: 100.2)
                model.rowClicked(testCase.key)
                XCTAssertEqual(spy.commands.map(\.arguments), [testCase.expected], name)
                XCTAssertEqual(model.list.selection?.key, testCase.key, name)
                XCTAssertEqual(spy.focusListSurfaces, [testCase.surface, testCase.surface], name)
                // The first click's deselect (preselected = accent) is off.
                spy.scheduled.forEach { $0.action() }
                XCTAssertEqual(model.list.selection?.key, testCase.key, "\(name): never deselected")
                // A third click does not run it again.
                model.pointerDown(surface: testCase.surface, surfaceWasKey: true, searchFieldFocused: false,
                                  clickCount: 3, pressedAt: 100.4)
                model.rowClicked(testCase.key)
                XCTAssertEqual(spy.commands.count, 1, name)
            }
        }
    }

    func testDoubleClickWithTheButtonDisabledRunsNothing() {
        let model = makeModel()
        model.surfaceDidShow(.popover)
        spy.indexCompletions[0](0)
        spy.searches[0].completion(ok(#"{"conversations":[\#(summaryJSON("x", cwd: nil))]}"#))
        for count in [1, 2] {
            model.pointerDown(surface: .popover, surfaceWasKey: true, searchFieldFocused: false, clickCount: count)
            model.rowClicked(.history(sessionID: "x"))
        }
        XCTAssertTrue(spy.commands.isEmpty)
        XCTAssertEqual(model.list.selection?.key, .history(sessionID: "x"))
        XCTAssertEqual(spy.focusListSurfaces, [.popover, .popover])
    }

    /// The deferred deselect waits for the system double-click interval
    /// from the press: the click action runs on mouse-up, so the time since
    /// the press is subtracted (never below zero).
    func testDeferredDeselectWaitsForTheIntervalFromThePress() {
        struct Case {
            let pressedAt: TimeInterval?
            let now: TimeInterval
            let expectedDelay: Double
        }
        let cases = [
            Case(pressedAt: 100, now: 100.1, expectedDelay: 0.4),
            Case(pressedAt: 100, now: 100, expectedDelay: 0.5),
            Case(pressedAt: 100, now: 101, expectedDelay: 0),
            Case(pressedAt: nil, now: 100.1, expectedDelay: 0.5),
        ]
        for testCase in cases {
            spy = Spy()
            let spy = self.spy
            let model = MainSurfaceModel(
                home: "/Users/example", defaults: defaults, textSize: ConversationsTextSizeStore(defaults: defaults),
                launchers: ConversationsLaunchers(
                    search: { arguments, _, completion in
                        spy.searches.append(Dispatched(arguments: arguments, completion: completion))
                        return ConversationsProcess(process: Process())
                    },
                    show: { _, _, _ in ConversationsProcess(process: Process()) },
                    index: { _, _, _, completion in
                        spy.indexCompletions.append(completion)
                        return ConversationsProcess(process: Process())
                    }),
                runCommand: { arguments, completion in spy.commands.append((arguments: arguments, completion: completion)) },
                schedule: { seconds, action in spy.scheduled.append((seconds: seconds, action: action)) },
                doubleClickInterval: { 0.5 },
                uptime: { testCase.now })
            openPopover(model, delivering: ["a"])
            model.rowClicked(.history(sessionID: "a"))
            model.pointerDown(surface: .popover, surfaceWasKey: true, searchFieldFocused: false,
                              clickCount: 1, pressedAt: testCase.pressedAt)
            model.rowClicked(.history(sessionID: "a"))
            let name = "pressed \(String(describing: testCase.pressedAt)), now \(testCase.now)"
            XCTAssertEqual(spy.scheduled.count, 1, name)
            XCTAssertEqual(spy.scheduled.first?.seconds ?? -1, testCase.expectedDelay, accuracy: 1e-9, name)
            XCTAssertEqual(model.list.selection?.key, .history(sessionID: "a"), "\(name): not yet")
            spy.scheduled[0].action()
            XCTAssertNil(model.list.selection, name)
        }
    }

    /// Closing the surface cancels a pending deselect.
    func testClosingTheSurfaceCancelsThePendingDeselect() {
        let model = makeModel()
        openPopover(model, delivering: ["a"])
        model.rowClicked(.history(sessionID: "a"))
        model.pointerDown(surface: .popover, surfaceWasKey: true, searchFieldFocused: false, clickCount: 1)
        model.rowClicked(.history(sessionID: "a"))
        XCTAssertEqual(spy.scheduled.count, 1)
        model.surfaceDidHide(.popover)
        spy.scheduled[0].action()
        XCTAssertEqual(model.list.selection?.key, .history(sessionID: "a"))
    }

    /// Key-status reports and presses from the surface that is not on
    /// screen are ignored; the key status leaves the key hints and the
    /// buttons' shortcut glyphs alone.
    func testKeyStatusAndPressReportsFollowTheVisibleSurface() {
        let model = makeModel()
        openPopover(model, delivering: ["a"])
        model.rowClicked(.history(sessionID: "a"))
        model.surfaceKeyChanged(surface: .window, isKey: false)
        XCTAssertTrue(model.list.isSurfaceKey, "the hidden window's report is ignored")
        model.pointerDown(surface: .window, surfaceWasKey: false, searchFieldFocused: false)
        XCTAssertNil(model.list.selectionActiveAtPointerDown, "the hidden window's press is ignored")
        model.surfaceKeyChanged(surface: .popover, isKey: false)
        XCTAssertFalse(model.list.isSelectionActive)
        XCTAssertEqual(model.list.footerHints, [.move, .open], "hints follow the search field only")
        XCTAssertEqual(model.list.listBottomPanel?.showsShortcuts, true)
        // A key event comes from the key window only.
        XCTAssertEqual(key(model, .escape, surface: .popover, searchFieldFocused: false), .consumed)
        XCTAssertTrue(model.list.isSurfaceKey)
        XCTAssertTrue(model.list.isSelectionActive)
    }

    func testInitialFocusFollowsThePage() {
        let model = makeModel()
        openPopover(model, delivering: ["a"])
        let search = model.searchFocusRequests[.popover] ?? 0
        model.requestInitialFocus()
        XCTAssertEqual(model.searchFocusRequests[.popover], search + 1)
        XCTAssertNil(model.searchFocusRequests[.window], "a popover request never reaches the window")
        model.rowOpenClicked(.history(sessionID: "a"))
        XCTAssertEqual(model.paneFocusRequests[.popover], 1, "opening the detail page focuses the pane")
        let pane = model.paneFocusRequests[.popover] ?? 0
        model.requestInitialFocus()
        XCTAssertEqual(model.paneFocusRequests[.popover], pane + 1)
        let searchBeforeBack = model.searchFocusRequests[.popover] ?? 0
        let focusListBeforeBack = spy.focusListSurfaces.count
        model.backClicked()
        XCTAssertEqual(model.searchFocusRequests[.popover], searchBeforeBack, "back never focuses the search field")
        XCTAssertEqual(spy.focusListSurfaces.count, focusListBeforeBack + 1, "back to the list focuses the list")
        // ⌘F from the detail page: back to the list page, then the search field.
        model.rowOpenClicked(.history(sessionID: "a"))
        XCTAssertEqual(key(model, .other(charactersIgnoringModifiers: "f"), [.command]), .consumed)
        XCTAssertEqual(model.list.page, .list)
        XCTAssertEqual(model.searchFocusRequests[.popover], searchBeforeBack + 1)
    }

    // MARK: - Stars, pin, message line

    func testStarsPersistToTheInjectedDefaults() {
        let model = makeModel()
        openPopover(model, delivering: ["a", "b"])
        model.starClicked(sessionID: "b")
        XCTAssertEqual(StarredSessions.load(from: defaults), ["b"])
        XCTAssertEqual(model.list.historyRows.map(\.sessionID), ["b", "a"])
        XCTAssertNil(model.list.selection)
        // A new model reads the stars back.
        let reloaded = makeModel()
        XCTAssertEqual(reloaded.list.stars, ["b"])
    }

    func testKeepOnTopPersistsAndNotifies() {
        let model = makeModel()
        XCTAssertFalse(model.keepOnTop, "default OFF")
        model.keepOnTopClicked()
        XCTAssertTrue(model.keepOnTop)
        XCTAssertEqual(defaults.object(forKey: MainSurfaceDefaultsKeys.windowKeepOnTop) as? Bool, true)
        XCTAssertEqual(spy.keepOnTopChanges, [true])
        XCTAssertTrue(makeModel().keepOnTop)
    }

    func testRescanFeedbackUsesTheMessageLine() {
        let model = makeModel()
        model.showRescanFeedback(.running)
        XCTAssertEqual(model.messageText, "Rescanning\u{2026}")
        model.showRescanFeedback(.success)
        XCTAssertEqual(model.messageText, "\u{2713} Rescan done")
        model.showRescanFeedback(nil)
        XCTAssertNil(model.messageText)
    }

    func testWarningsAreStoredForTheFooter() {
        let model = makeModel()
        model.setWarnings([.disconnected, .automationPermission])
        XCTAssertEqual(model.warnings.map(\.text), [
            "Disconnected from daemon \u{2014} reconnecting\u{2026}",
            "Automation permission needed (run \"shiibar-cc doctor\")",
        ])
    }
}
