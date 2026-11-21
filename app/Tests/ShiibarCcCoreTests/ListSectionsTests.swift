import XCTest

@testable import ShiibarCcCore

/// The three sections under their headings and opening / closing them
/// (DESIGN.md §4.5 "the list has three sections" / "row selection" /
/// "collapsing sections" / "key operations", §4.6 "Starred section" /
/// "Recent section" / "search scope", §8.60).
final class ListSectionsTests: XCTestCase {
    /// Running: t1 (s1). Starred, in the stars' order: c, a, b. Recent: h1,
    /// h2. Search order (newest first): s1, h1, a, h2, b, c.
    private func populated(columns: ColumnMode = .one, collapsed: Set<ListHeading> = []) -> UnifiedListState {
        var state = UnifiedListState(home: UL.home, now: UL.now, stars: ["c", "a", "b"], collapsedSections: collapsed)
        state.handle(.columnsChanged(columns))
        state.handle(.agentsUpdated([UL.agent("t1", session: "s1")]))
        state.handle(.historyDelivered(browse, isFiltered: false))
        return state
    }

    private let browse = [
        UL.summary("s1", updatedAt: 9_600, live: true), UL.summary("h1", updatedAt: 9_500),
        UL.summary("a", updatedAt: 9_400), UL.summary("h2", updatedAt: 9_300),
        UL.summary("b", updatedAt: 9_200), UL.summary("c", updatedAt: 9_100),
    ]

    private func key(_ sessionID: String) -> UnifiedRowKey { .conversation(sessionID: sessionID) }

    /// A click on a heading: the press, then the click.
    @discardableResult
    private func clickHeading(_ state: inout UnifiedListState, _ heading: ListHeading,
                              clickCount: Int = 1, surfaceKey: Bool = true) -> [UnifiedListEffect] {
        state.handle(.pointerDown(surfaceKey: surfaceKey, searchFieldFocused: false, clickCount: clickCount))
        return state.handle(.headingClicked(heading))
    }

    private func heading(_ state: UnifiedListState, _ heading: ListHeading) -> ListHeadingModel? {
        state.headings.first { $0.heading == heading }
    }

    /// The frames shown, with their rows' session IDs (a Running row: its
    /// target).
    private func frames(_ state: UnifiedListState) -> [ListFrameID: [String]] {
        var frames: [ListFrameID: [String]] = [:]
        for block in state.blocks {
            guard case .frame(let frame) = block else { continue }
            frames[frame.id] = frame.rows.map { row in
                if case .running(let target) = row.id { return target }
                return row.sessionID
            }
        }
        return frames
    }

    // MARK: - Three sections

    func testRowsSplitIntoRunningStarredAndRecent() {
        let state = populated()
        XCTAssertEqual(state.runningRows.map(\.id), [.running(target: "t1")])
        XCTAssertEqual(state.starredRows.map(\.sessionID), ["c", "a", "b"], "the stars' order")
        XCTAssertEqual(state.recentRows.map(\.sessionID), ["h1", "h2"], "newest first, no starred and no running")
        XCTAssertEqual(state.blocks.map(\.id), [
            .heading(.running), .frame(.running), .heading(.history), .heading(.starred), .frame(.starred),
            .heading(.recent), .frame(.recent),
        ])
        XCTAssertEqual(state.headings.map(\.style), [.band, .band, .sub, .sub])
        XCTAssertEqual(state.headings.map(\.countText), ["1", nil, "3", "2"],
                       "History shows no count while it has its own Starred and Recent headings")
        XCTAssertEqual(frames(state), [.running: ["t1"], .starred: ["c", "a", "b"], .recent: ["h1", "h2"]])
    }

    func testArrowsAndThePositionCrossTheThreeSections() {
        var state = populated()
        let expected: [UnifiedRowKey] = [.running(target: "t1"), key("c"), key("a"), key("b"), key("h1"), key("h2")]
        XCTAssertEqual(state.visibleRows.map(\.id), expected)
        state.handle(.moveDown)
        for next in expected.dropFirst() {
            state.handle(.moveDown)
            XCTAssertEqual(state.selection?.key, next)
        }
        state.handle(.openDetail)
        guard case .conversation(let pane) = state.paneContent else { return XCTFail("expected the detail page") }
        XCTAssertEqual(pane.positionText, "6 / 6")
        state.handle(.previousConversation)
        state.handle(.previousConversation)
        XCTAssertEqual(state.selection?.key, key("b"))
        guard case .conversation(let moved) = state.paneContent else { return XCTFail("expected the detail page") }
        XCTAssertEqual(moved.positionText, "4 / 6")
    }

    func testAStarChangeKeepsTheSelectionAndThePage() {
        var state = populated()
        state.openDetailPage(key("h1"))
        state.handle(.starToggled(sessionID: "h1"))
        XCTAssertEqual(state.starredRows.map(\.sessionID), ["c", "a", "b", "h1"], "a new star goes to the end")
        XCTAssertEqual(state.selection?.key, key("h1"))
        XCTAssertEqual(state.page, .detail)
        state.handle(.starToggled(sessionID: "h1"))
        XCTAssertEqual(state.recentRows.map(\.sessionID), ["h1", "h2"], "back at its newest-first place")
        XCTAssertEqual(state.selection?.key, key("h1"))
        XCTAssertEqual(state.page, .detail)
    }

    func testAStarredRowThatResumesMovesTheSelectionToRunning() {
        var state = populated()
        state.openDetailPage(key("a"))
        state.handle(.agentsUpdated([UL.agent("t1", session: "s1"), UL.agent("t2", session: "a", createdAt: 5)]))
        XCTAssertEqual(state.selection?.key, .running(target: "t2"))
        XCTAssertEqual(state.page, .detail)
        XCTAssertEqual(state.starredRows.map(\.sessionID), ["c", "b"])
    }

    // MARK: - Headings shown (§4.5 "headings not shown" / "row counts")

    func testTheHeadingsShownForStarredAndRecentRowsAndHistoryOpenOrClosed() {
        struct Case {
            let name: String
            let stars: StarredList
            let results: [String]
            let historyClosed: Bool
            let headings: [ListHeading]
            let counts: [String?]
            let frames: [ListFrameID: [String]]
        }
        let cases = [
            Case(name: "both, open", stars: ["a"], results: ["a", "r"], historyClosed: false,
                 headings: [.history, .starred, .recent], counts: [nil, "1", "1"],
                 frames: [.starred: ["a"], .recent: ["r"]]),
            Case(name: "both, History closed", stars: ["a"], results: ["a", "r"], historyClosed: true,
                 headings: [.history], counts: [nil], frames: [:]),
            Case(name: "Starred only, open", stars: ["a"], results: ["a"], historyClosed: false,
                 headings: [.history, .starred], counts: [nil, "1"], frames: [.starred: ["a"]]),
            Case(name: "Starred only, History closed", stars: ["a"], results: ["a"], historyClosed: true,
                 headings: [.history], counts: [nil], frames: [:]),
            Case(name: "Recent only, open: History stands for the Recent heading", stars: [], results: ["r", "q"],
                 historyClosed: false, headings: [.history], counts: ["2"], frames: [.recent: ["r", "q"]]),
            Case(name: "Recent only, History closed", stars: [], results: ["r", "q"], historyClosed: true,
                 headings: [.history], counts: ["2"], frames: [:]),
            Case(name: "neither, open", stars: [], results: [], historyClosed: false,
                 headings: [], counts: [], frames: [:]),
            Case(name: "neither, History closed", stars: [], results: [], historyClosed: true,
                 headings: [], counts: [], frames: [:]),
        ]
        for c in cases {
            var state = UnifiedListState(home: UL.home, now: UL.now, stars: c.stars,
                                         collapsedSections: c.historyClosed ? [.history] : [])
            state.handle(.historyDelivered(c.results.map { UL.summary($0) }, isFiltered: false))
            XCTAssertEqual(state.headings.map(\.heading), c.headings, c.name)
            XCTAssertEqual(state.headings.map(\.countText), c.counts, c.name)
            XCTAssertEqual(state.headings.first?.isOpen, c.headings.isEmpty ? nil : !c.historyClosed, c.name)
            XCTAssertEqual(frames(state), c.frames, c.name)
        }
    }

    /// A closed section with rows still shows its heading: closing Starred
    /// does not make the History heading stand for the Recent heading.
    func testAClosedStarredKeepsItsHeading() {
        let state = populated(collapsed: [.starred])
        XCTAssertEqual(state.headings.map(\.heading), [.running, .history, .starred, .recent])
        XCTAssertEqual(heading(state, .history)?.countText, nil)
        XCTAssertFalse(state.historyHeadingIsRecentHeading)
    }

    // MARK: - Searching (§4.6 "search scope")

    func testSearchingShowsOneHistoryFrameWithStarredRowsFirst() {
        // Every heading is remembered closed: searching shows them all open,
        // Starred's and Recent's rows included.
        var state = populated(collapsed: [.running, .history, .starred, .recent])
        state.handle(.queryValidityChanged(true))
        state.handle(.historyDelivered(
            [UL.summary("s1"), UL.summary("h2"), UL.summary("b"), UL.summary("c"), UL.summary("h1")],
            isFiltered: true))
        XCTAssertEqual(state.blocks.map(\.id), [.heading(.running), .frame(.running), .heading(.history), .frame(.history)])
        XCTAssertEqual(state.headings.map(\.style), [.band, .band], "the bands keep their shape (§4.5)")
        XCTAssertEqual(state.headings.map(\.isCollapsible), [false, false], "no chevron")
        XCTAssertEqual(state.headings.map(\.showsAttentionMark), [false, false], "no Running mark")
        XCTAssertEqual(state.headings.map(\.isOpen), [true, true])
        XCTAssertEqual(state.headings.map(\.countText), ["1", "4"], "History counts the Starred and Recent rows")
        XCTAssertEqual(frames(state)[.history], ["c", "b", "h2", "h1"], "Starred rows first, in the stars' order")
        XCTAssertEqual(state.visibleRows.map(\.sessionID), ["s1", "c", "b", "h2", "h1"])
        for section in UnifiedListSection.normalList {
            XCTAssertTrue(state.isSectionShown(section), "\(section)")
        }
        XCTAssertFalse(state.isSectionShown(.archived), "the Archive view's rows belong to the Archive view only")

        // A star change moves the row inside the same frame.
        state.handle(.starToggled(sessionID: "h1"))
        XCTAssertEqual(frames(state)[.history], ["c", "b", "h1", "h2"])
        state.handle(.starToggled(sessionID: "c"))
        XCTAssertEqual(frames(state)[.history], ["b", "h1", "h2", "c"])
        XCTAssertEqual(state.collapsedSections, [.running, .history, .starred, .recent])
    }

    /// §4.5 "collapsing sections": a closed Running with a waiting row
    /// shows the Running mark on its band; while searching the band keeps
    /// its shape without the mark and the chevron.
    func testSearchingBandsShowNoRunningMarkAndNoChevron() {
        var state = UnifiedListState(home: UL.home, now: UL.now, collapsedSections: [.running])
        state.handle(.agentsUpdated([UL.agent("t1", status: .waiting, session: "s1")]))
        state.handle(.historyDelivered([UL.summary("s1")], isFiltered: false))
        XCTAssertEqual(heading(state, .running)?.style, .band)
        XCTAssertEqual(heading(state, .running)?.showsAttentionMark, true)
        XCTAssertEqual(heading(state, .running)?.isCollapsible, true)
        state.handle(.queryValidityChanged(true))
        XCTAssertEqual(heading(state, .running)?.style, .band)
        XCTAssertEqual(heading(state, .running)?.showsAttentionMark, false)
        XCTAssertEqual(heading(state, .running)?.isCollapsible, false)
    }

    func testSearchingCountsFirstWhileTheCapLeavesRecentRowsOut() {
        var state = UnifiedListState(home: UL.home, now: UL.now, stars: ["c150", "c151"])
        state.handle(.queryValidityChanged(true))
        let results = (0..<152).map { UL.summary("c\($0)", updatedAt: Int64(9_000 - $0)) }
        state.handle(.historyDelivered(results, isFiltered: true))
        XCTAssertEqual(state.headings.map(\.countText), ["first 102"])
        XCTAssertEqual(state.blocks.map(\.id), [.heading(.history), .frame(.history), .moreLine])
        XCTAssertEqual(state.hiddenRecentText, "50 more \u{2014} refine your search")
    }

    // MARK: - Empty state

    func testEmptyStateOnlyWhenEverySectionIsEmpty() {
        var state = UnifiedListState(home: UL.home, now: UL.now, stars: ["a"], collapsedSections: [.history])
        state.handle(.historyDelivered([UL.summary("a")], isFiltered: false))
        XCTAssertNil(state.emptyStateText, "a closed section's rows are rows")
        XCTAssertEqual(state.visibleRows, [])
        XCTAssertEqual(state.headings.map(\.isOpen), [false])
        state.handle(.starToggled(sessionID: "a"))
        XCTAssertNil(state.emptyStateText, "Recent (closed) has the row now")
        state.handle(.historyDelivered([], isFiltered: false))
        XCTAssertEqual(state.emptyStateText, "No conversations")
    }

    // MARK: - Opening and closing

    func testAHeadingClickClosesAndOpensAndIsRemembered() {
        var state = populated()
        let effects = clickHeading(&state, .starred)
        XCTAssertEqual(effects, [.makeSurfaceKey, .persistCollapsedSections([.starred])])
        XCTAssertEqual(state.headings.map(\.isOpen), [true, true, false, true])
        XCTAssertNil(frames(state)[.starred])
        XCTAssertEqual(heading(state, .starred)?.countText, "3", "a closed heading shows the same count")
        XCTAssertEqual(clickHeading(&state, .starred), [.makeSurfaceKey, .persistCollapsedSections([])])
        XCTAssertEqual(state.headings.map(\.isOpen), [true, true, true, true])
    }

    func testClosedHistoryHidesStarredAndRecentAndReopensThemAsRemembered() {
        var state = populated(collapsed: [.recent])
        XCTAssertEqual(clickHeading(&state, .history), [.makeSurfaceKey, .persistCollapsedSections([.history, .recent])])
        XCTAssertEqual(state.headings.map(\.heading), [.running, .history])
        XCTAssertEqual(state.visibleRows.map(\.id), [.running(target: "t1")])
        clickHeading(&state, .history)
        XCTAssertEqual(state.headings.map(\.heading), [.running, .history, .starred, .recent])
        XCTAssertEqual(state.headings.map(\.isOpen), [true, true, true, false], "Starred open, Recent still closed")
        XCTAssertEqual(state.visibleRows.map(\.sessionID), ["s1", "c", "a", "b"])
    }

    /// §4.5 "collapsing sections": while the History heading stands for the
    /// Recent heading, it shows open only while History and Recent are both
    /// open; open, a click closes History; closed, a click opens both.
    func testTheHistoryHeadingStandingForTheRecentHeading() {
        struct Case {
            let collapsed: Set<ListHeading>
            let open: Bool
            let afterClick: Set<ListHeading>
        }
        let cases = [
            Case(collapsed: [], open: true, afterClick: [.history]),
            Case(collapsed: [.history], open: false, afterClick: []),
            Case(collapsed: [.recent], open: false, afterClick: []),
            Case(collapsed: [.history, .recent], open: false, afterClick: []),
        ]
        for c in cases {
            var state = UnifiedListState(home: UL.home, now: UL.now, collapsedSections: c.collapsed.union([.starred]))
            state.handle(.historyDelivered([UL.summary("r"), UL.summary("q")], isFiltered: false))
            let name = "\(c.collapsed.map(\.rawValue).sorted())"
            XCTAssertEqual(state.headings.map(\.heading), [.history], name)
            XCTAssertEqual(state.headings.first?.isOpen, c.open, name)
            XCTAssertEqual(frames(state)[.recent], c.open ? ["r", "q"] : nil, name)
            XCTAssertEqual(state.visibleRows.count, c.open ? 2 : 0, name)
            clickHeading(&state, .history)
            XCTAssertEqual(state.collapsedSections, c.afterClick.union([.starred]), "\(name): Starred's own state is kept")
            XCTAssertEqual(state.headings.first?.isOpen, !c.open, name)
        }
    }

    func testConsecutiveClicksToggleOnce() {
        var state = populated()
        clickHeading(&state, .recent, clickCount: 1)
        XCTAssertEqual(clickHeading(&state, .recent, clickCount: 2), [.makeSurfaceKey], "the double-click's second click")
        XCTAssertEqual(clickHeading(&state, .recent, clickCount: 3), [.makeSurfaceKey])
        XCTAssertEqual(state.collapsedSections, [.recent])
        // A new sequence toggles again.
        clickHeading(&state, .recent, clickCount: 1)
        XCTAssertEqual(state.collapsedSections, [])
    }

    /// §4.5 "collapsing sections": a click that continues a sequence begun
    /// on a heading does nothing, whatever is under the pointer — the first
    /// click may have moved another heading or a row there.
    func testAClickContinuingAHeadingClickDoesNothingElsewhere() {
        var state = populated()
        clickHeading(&state, .starred, clickCount: 1)
        XCTAssertEqual(clickHeading(&state, .recent, clickCount: 2), [.makeSurfaceKey], "another heading")
        XCTAssertEqual(state.collapsedSections, [.starred])

        state.handle(.pointerDown(surfaceKey: true, searchFieldFocused: false, clickCount: 3))
        state.handle(.rowPressed(key("h1"), clickCount: 3, onStar: false, x: 0, y: 0))
        XCTAssertEqual(state.handle(.rowPressDragged(x: 0, y: 10)), [], "no drag and no reason")
        XCTAssertNil(state.cardDrag)
        XCTAssertEqual(state.handle(.rowClicked(key("h1"))), [], "a row")
        XCTAssertNil(state.selection)

        // A press counted as a repeat after a row click is a row click.
        state.handle(.pointerDown(surfaceKey: true, searchFieldFocused: false, clickCount: 1))
        state.handle(.rowClicked(key("h1")))
        clickHeading(&state, .running, clickCount: 2)
        XCTAssertEqual(state.collapsedSections, [.starred, .running], "the sequence began on a row")
    }

    /// A star click continuing a sequence begun on a heading changes no
    /// star: closing a section can move a row's star under the pointer.
    func testAStarClickContinuingAHeadingClickDoesNothing() {
        var state = populated()
        clickHeading(&state, .running, clickCount: 1)
        state.handle(.pointerDown(surfaceKey: true, searchFieldFocused: false, clickCount: 2))
        XCTAssertEqual(state.handle(.starToggled(sessionID: "c")), [], "no change, nothing persisted")
        state.handle(.pointerDown(surfaceKey: true, searchFieldFocused: false, clickCount: 3))
        XCTAssertEqual(state.handle(.starToggled(sessionID: "h1")), [], "the third click of the sequence")
        XCTAssertEqual(state.stars, ["c", "a", "b"])
        XCTAssertNil(state.selection)

        // A fresh single press after the heading click toggles as usual.
        state.handle(.pointerDown(surfaceKey: true, searchFieldFocused: false, clickCount: 1))
        XCTAssertEqual(state.handle(.starToggled(sessionID: "h1")), [.persistStars(["c", "a", "b", "h1"])])
    }

    /// The suppression belongs to the press: a star toggle that arrives
    /// without a pointer press (an accessibility action) after a suppressed
    /// click toggles.
    func testAStarToggleWithoutAPressAfterASuppressedClickToggles() {
        var state = populated()
        clickHeading(&state, .running, clickCount: 1)
        state.handle(.pointerDown(surfaceKey: true, searchFieldFocused: false, clickCount: 2))
        XCTAssertEqual(state.handle(.starToggled(sessionID: "c")), [])
        XCTAssertEqual(state.handle(.starToggled(sessionID: "h1")), [.persistStars(["c", "a", "b", "h1"])])
    }

    func testAHeadingClickInANonKeySurfaceMakesItKeyAndToggles() {
        var state = populated()
        state.handle(.surfaceKeyChanged(false))
        let effects = clickHeading(&state, .running, surfaceKey: false)
        XCTAssertEqual(effects, [.makeSurfaceKey, .persistCollapsedSections([.running])])
    }

    func testAHeadingClickKeepsTheFocusAndOtherSectionsSelection() {
        var state = populated(columns: .two)
        state.handle(.rowClicked(key("h1")))
        state.handle(.searchFieldFocusChanged(true))
        let effects = clickHeading(&state, .starred)
        XCTAssertFalse(effects.contains(.focusList))
        XCTAssertFalse(effects.contains(.focusSearchField))
        XCTAssertEqual(state.selection?.key, key("h1"))
    }

    func testClosedSectionsRowsAreNotInTheList() {
        var state = populated(collapsed: [.starred])
        XCTAssertEqual(state.visibleRows.map(\.id), [.running(target: "t1"), key("h1"), key("h2")])
        state.handle(.moveDown)
        state.handle(.moveDown)
        XCTAssertEqual(state.selection?.key, key("h1"), "↓ skips the closed Starred")
        state.handle(.openDetail)
        guard case .conversation(let pane) = state.paneContent else { return XCTFail("expected the detail page") }
        XCTAssertEqual(pane.positionText, "2 / 3")
        state.handle(.previousConversation)
        XCTAssertEqual(state.selection?.key, .running(target: "t1"))

        var first = populated(collapsed: [.running])
        first.handle(.enterFromSearchField)
        XCTAssertEqual(first.selection?.key, key("c"), "the list's first row is the first row shown")
        var hotKey = populated(collapsed: [.running, .starred])
        hotKey.handle(.openedByHotKey)
        XCTAssertEqual(hotKey.selection?.key, key("h1"))
        var history = populated(collapsed: [.history])
        history.handle(.moveDown)
        history.handle(.moveDown)
        XCTAssertEqual(history.selection?.key, .running(target: "t1"), "closed History hides Starred and Recent")
    }

    func testWithEveryRowClosedTheKeysActAsWithNoRows() {
        var state = populated(collapsed: [.running, .history])
        XCTAssertNil(state.emptyStateText)
        state.handle(.searchFieldFocusChanged(true))
        let context = state.keyContext(isPopover: true, hasMarkedText: false)
        XCTAssertFalse(context.hasRows)
        XCTAssertEqual(UnifiedListKeys.decide(key: .returnKey, modifiers: [], context: context), .ignore,
                       "Enter in the search field does nothing")
        XCTAssertEqual(state.handle(.enterFromSearchField), [])
        XCTAssertNil(state.selection)
        XCTAssertEqual(state.handle(.openedByHotKey), [.focusSearchField], "the hotkey focuses the search field")
        XCTAssertNil(state.selection)
        state.handle(.searchFieldFocusChanged(false))
        XCTAssertEqual(state.handle(.moveDown), [])
    }

    func testClosingTheSelectedRowsSectionDeselects() {
        var state = populated()
        state.openDetailPage(key("a"))
        clickHeading(&state, .recent)
        XCTAssertEqual(state.selection?.key, key("a"), "closing another section keeps it")
        clickHeading(&state, .starred)
        XCTAssertNil(state.selection)
        XCTAssertEqual(state.page, .list, "the one-column detail page returns to the list page")

        var history = populated()
        history.handle(.rowClicked(key("h1")))
        clickHeading(&history, .history)
        XCTAssertNil(history.selection, "closing History closes Recent too")
    }

    func testASelectedRowMovingIntoAClosedSectionDeselects() {
        // A star change.
        var star = populated(collapsed: [.starred])
        star.handle(.rowClicked(key("h1")))
        star.handle(.starToggled(sessionID: "h1"))
        XCTAssertNil(star.selection)

        // A Resume while Running is closed.
        var resume = populated(collapsed: [.running])
        resume.openDetailPage(key("a"))
        resume.handle(.agentsUpdated([UL.agent("t1", session: "s1"), UL.agent("t2", session: "a")]))
        XCTAssertNil(resume.selection)
        XCTAssertEqual(resume.page, .list)

        // A session that ends: the refetch puts its row in a closed section.
        var ended = populated(collapsed: [.recent])
        ended.handle(.rowClicked(.running(target: "t1")))
        ended.handle(.agentsUpdated([]))
        XCTAssertNotNil(ended.selection, "awaiting the refetch")
        ended.handle(.historyDelivered(browse, isFiltered: false))
        XCTAssertNil(ended.selection, "s1 is in the closed Recent")

        var endedStarred = populated(collapsed: [.recent])
        endedStarred.handle(.rowClicked(.running(target: "t1")))
        endedStarred.handle(.agentsUpdated([]))
        endedStarred.handle(.starToggled(sessionID: "s1"))
        endedStarred.handle(.historyDelivered(browse, isFiltered: false))
        XCTAssertEqual(endedStarred.selection?.key, key("s1"), "Starred is open: the selection stays")
    }

    func testClosingRunningWhileItsEndedRowAwaitsTheRefetchDeselects() {
        var state = populated()
        state.handle(.rowClicked(.running(target: "t1")))
        state.handle(.agentsUpdated([]))
        XCTAssertTrue(state.isAwaitingRefetch)
        clickHeading(&state, .running)
        XCTAssertNil(state.selection)
        XCTAssertFalse(state.isAwaitingRefetch)
    }

    func testSearchingShowsRunningAndHistoryOpenAndHeadingsDoNothing() {
        var state = populated(collapsed: [.running, .history])
        state.handle(.queryValidityChanged(true))
        state.handle(.historyDelivered(browse, isFiltered: true))
        XCTAssertTrue(state.isSearching)
        XCTAssertEqual(state.headings.map(\.heading), [.running, .history])
        XCTAssertEqual(state.headings.map(\.isOpen), [true, true])
        XCTAssertEqual(clickHeading(&state, .history), [.makeSurfaceKey], "no toggle; a non-key window becomes key")
        XCTAssertEqual(clickHeading(&state, .running), [.makeSurfaceKey])
        XCTAssertEqual(state.collapsedSections, [.running, .history], "the remembered state stays")
        state.handle(.rowClicked(key("h1")))
        XCTAssertEqual(state.selection?.key, key("h1"))
        // Searching ends with the search text: the remembered state shows
        // again, and the row in a closed section deselects.
        state.handle(.queryValidityChanged(false))
        XCTAssertEqual(state.headings.map(\.isOpen), [false, false])
        XCTAssertNil(state.selection)

        var kept = populated(collapsed: [.starred])
        kept.handle(.queryValidityChanged(true))
        kept.handle(.rowClicked(key("h1")))
        kept.handle(.queryValidityChanged(false))
        XCTAssertEqual(kept.selection?.key, key("h1"), "a row in an open section stays selected")
    }

    /// "Searching" is the search text being valid (§4.5 "collapsing
    /// sections"): from that moment, before any result and when the search
    /// fails, until the text stops being valid.
    func testSearchingFollowsTheSearchTextNotTheResult() {
        var state = populated(collapsed: [.history])
        state.handle(.queryValidityChanged(true))
        XCTAssertTrue(state.isSearching, "before any result")
        XCTAssertEqual(state.headings.map(\.isOpen), [true, true])
        XCTAssertEqual(clickHeading(&state, .history, surfaceKey: false), [.makeSurfaceKey])
        XCTAssertFalse(state.canStartCardDrag(key: key("a"), clickCount: 1, onStar: false))
        state.handle(.historyFetchFailed)
        XCTAssertTrue(state.isSearching, "a failed search is still searching")
        XCTAssertEqual(state.collapsedSections, [.history])

        state.handle(.historyDelivered(browse, isFiltered: true))
        state.handle(.queryValidityChanged(false))
        XCTAssertFalse(state.isSearching, "the filtered result is still shown, but searching ended")
        XCTAssertEqual(state.headings.map(\.isCollapsible), [true, true])
        clickHeading(&state, .history)
        XCTAssertTrue(state.canStartCardDrag(key: key("a"), clickCount: 1, onStar: false))
    }

    func testTheStateOfAHeadingNotShownIsKept() {
        var state = UnifiedListState(home: UL.home, now: UL.now, collapsedSections: [.running, .starred])
        state.handle(.historyDelivered([UL.summary("h1"), UL.summary("h2")], isFiltered: false))
        XCTAssertEqual(state.headings.map(\.heading), [.history])
        clickHeading(&state, .history)
        XCTAssertEqual(state.collapsedSections, [.running, .starred, .history])
        state.handle(.agentsUpdated([UL.agent("t1", session: "s1")]))
        XCTAssertEqual(state.headings.map(\.isOpen), [false, false], "Running shows closed once it has rows")
        clickHeading(&state, .history)
        state.handle(.starToggled(sessionID: "h1"))
        XCTAssertEqual(heading(state, .starred)?.isOpen, false, "Starred shows closed once it has rows")
    }

    func testAClosedRecentHidesItsMoreLineButKeepsFirst100() {
        let many = (0..<150).map { UL.summary("c\($0)", updatedAt: Int64(9_000 - $0)) }
        var state = UnifiedListState(home: UL.home, now: UL.now, stars: ["c149"], collapsedSections: [.recent])
        state.handle(.historyDelivered(many, isFiltered: false))
        XCTAssertEqual(heading(state, .recent)?.countText, "first 100")
        XCTAssertEqual(heading(state, .recent)?.isOpen, false)
        XCTAssertNil(state.hiddenRecentText, "no `N more` line under a closed Recent")
        XCTAssertFalse(state.blocks.contains { $0.id == .moreLine })
        clickHeading(&state, .recent)
        XCTAssertEqual(state.hiddenRecentText, "49 more \u{2014} search to narrow down")
        XCTAssertEqual(state.blocks.last?.id, .moreLine, "below the Recent frame")

        var standing = UnifiedListState(home: UL.home, now: UL.now, collapsedSections: [.history])
        standing.handle(.historyDelivered(many, isFiltered: false))
        XCTAssertEqual(standing.headings.map(\.countText), ["first 100"], "`History first 100` while closed")
        XCTAssertNil(standing.hiddenRecentText)
    }

    func testRunningMark() {
        struct Case {
            let name: String
            let status: AgentStatus
            let unreviewed: Bool
            let closed: Bool
            let searching: Bool
            let expected: Bool
        }
        var cases: [Case] = []
        for (status, unreviewed, flagged) in [(AgentStatus.waiting, false, true), (.idle, true, true),
                                               (.working, true, true), (.idle, false, false), (.working, false, false)] {
            for closed in [true, false] {
                for searching in [true, false] {
                    cases.append(Case(name: "\(status) unreviewed=\(unreviewed) closed=\(closed) searching=\(searching)",
                                      status: status, unreviewed: unreviewed, closed: closed, searching: searching,
                                      expected: flagged && closed && !searching))
                }
            }
        }
        for c in cases {
            var state = UnifiedListState(home: UL.home, now: UL.now, collapsedSections: c.closed ? [.running] : [])
            state.handle(.agentsUpdated([
                UL.agent("t1", session: "s1"),
                UL.agent("t2", status: c.status, session: "s2", unreviewed: c.unreviewed),
            ]))
            state.handle(.queryValidityChanged(c.searching))
            state.handle(.historyDelivered([UL.summary("s1"), UL.summary("s2"), UL.summary("h")], isFiltered: c.searching))
            XCTAssertEqual(state.showsRunningAttentionMark, c.expected, c.name)
            XCTAssertEqual(heading(state, .running)?.showsAttentionMark, c.expected, c.name)
            XCTAssertFalse(state.headings.contains { $0.heading != .running && $0.showsAttentionMark }, c.name)
        }
    }

    // MARK: - Stored closed headings

    func testStoredClosedHeadingsAreReadDefensively() {
        XCTAssertEqual(CollapsedSections.decode(nil), [])
        XCTAssertEqual(CollapsedSections.decode("history"), [], "not an array")
        XCTAssertEqual(CollapsedSections.decode(["history", 1] as [Any]), [], "not an array of strings")
        XCTAssertEqual(CollapsedSections.decode(["recent", "pinned", "running", "starred", "history", "History"]),
                       [.recent, .running, .starred, .history], "names other than the four are ignored")
        let defaults = InMemoryDefaults()
        XCTAssertEqual(CollapsedSections.load(from: defaults), [])
        CollapsedSections.save([.recent, .history, .running, .starred], to: defaults)
        XCTAssertEqual(defaults.object(forKey: MainSurfaceDefaultsKeys.collapsedSections) as? [String],
                       ["running", "history", "starred", "recent"])
        XCTAssertEqual(CollapsedSections.load(from: defaults), [.recent, .history, .running, .starred])
        defaults.set(["recent", "bogus"], forKey: MainSurfaceDefaultsKeys.collapsedSections)
        let state = UnifiedListState(home: UL.home, now: UL.now, collapsedSections: CollapsedSections.load(from: defaults))
        XCTAssertEqual(state.collapsedSections, [.recent])
    }
}
