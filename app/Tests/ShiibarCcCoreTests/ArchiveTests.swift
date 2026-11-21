import XCTest

@testable import ShiibarCcCore

/// The archived list and its storage (DESIGN.md §4.6 "Archive" / "saving").
final class ArchivedListTests: XCTestCase {
    private func summaries(_ ids: [String]) -> [ConversationSummary] { ids.map { UL.summary($0) } }

    func testArchivingPutsTheConversationFirstAndKeepsAnArchivedOneInPlace() {
        let cases: [(name: String, start: ArchivedList, archive: String, expected: [String])] = [
            ("into an empty list", [], "a", ["a"]),
            ("the newest archive goes first", ["a", "b"], "c", ["c", "a", "b"]),
            ("already archived: unchanged", ["a", "b"], "b", ["a", "b"]),
        ]
        for c in cases {
            XCTAssertEqual(c.start.archiving(c.archive).sessionIDs, c.expected, c.name)
        }
    }

    func testUnarchivingLeavesTheOthersInOrder() {
        let list: ArchivedList = ["c", "a", "b"]
        XCTAssertEqual(list.unarchiving("a").sessionIDs, ["c", "b"])
        XCTAssertEqual(list.unarchiving("x").sessionIDs, ["c", "a", "b"], "not archived: unchanged")
        XCTAssertEqual(list.removing(["c", "b"]).sessionIDs, ["a"])
    }

    func testARepeatedSessionIDKeepsItsFirstPosition() {
        XCTAssertEqual(ArchivedList(["a", "b", "a", "c", "b"]).sessionIDs, ["a", "b", "c"])
    }

    /// §4.6: a browse list prunes the session IDs it does not hold (the
    /// transcript was deleted); nil when nothing changes.
    func testPruningByTheBrowseList() {
        let list: ArchivedList = ["c", "gone", "a"]
        XCTAssertEqual(list.pruned(browseResults: summaries(["a", "b", "c"]))?.sessionIDs, ["c", "a"])
        XCTAssertNil(ArchivedList(["a"]).pruned(browseResults: summaries(["a", "b"])))
    }

    func testStorage() {
        let defaults = InMemoryDefaults()
        XCTAssertEqual(ArchivedSessions.load(from: defaults), [], "nothing stored")
        ArchivedSessions.save(["b", "a"], to: defaults)
        XCTAssertEqual(defaults.object(forKey: MainSurfaceDefaultsKeys.archivedSessionList) as? [String], ["b", "a"])
        XCTAssertEqual(ArchivedSessions.load(from: defaults).sessionIDs, ["b", "a"])
        let malformed: [(String, Any)] = [("a string", "a"), ("a number", 3), ("mixed array", ["a", 1]),
                                          ("dictionary", ["a": "b"])]
        for (name, value) in malformed {
            defaults.set(value, forKey: MainSurfaceDefaultsKeys.archivedSessionList)
            XCTAssertEqual(ArchivedSessions.load(from: defaults), [], name)
        }
        defaults.set(["a", "b", "a"], forKey: MainSurfaceDefaultsKeys.archivedSessionList)
        XCTAssertEqual(ArchivedSessions.load(from: defaults).sessionIDs, ["a", "b"], "first of a repeated ID")
    }

    /// The key follows the stars' naming.
    func testKeyName() {
        XCTAssertEqual(MainSurfaceDefaultsKeys.archivedSessionList, "cc.shiibar.archivedSessionList")
    }
}

/// Archive on the normal list, the automatic unarchive, the Archive view,
/// and the row menu (DESIGN.md §4.5 "the list has three sections" / "row
/// drag" / "key operations" / "⌄ menu", §4.6 "Recent section" / "Archive" /
/// "Archive view" / "search scope", §8.63).
final class ArchiveStateTests: XCTestCase {
    private func key(_ sessionID: String) -> UnifiedRowKey { .conversation(sessionID: sessionID) }

    /// Newest first: a, b, c, d, e.
    private let browse = ["a", "b", "c", "d", "e"].enumerated().map { UL.summary($0.element, updatedAt: Int64(9_500 - $0.offset)) }

    private func state(
        stars: StarredList = [], archived: ArchivedList = [], results: [ConversationSummary]? = nil,
        agents: [Agent] = [], collapsed: Set<ListHeading> = [], columns: ColumnMode = .one
    ) -> UnifiedListState {
        var state = UnifiedListState(home: UL.home, now: UL.now, stars: stars, collapsedSections: collapsed,
                                     archived: archived)
        state.handle(.columnsChanged(columns))
        if !agents.isEmpty { state.handle(.agentsUpdated(agents)) }
        state.handle(.historyDelivered(results ?? browse, isFiltered: false))
        return state
    }

    private func persistedArchive(_ effects: [UnifiedListEffect]) -> [String]? {
        for effect in effects {
            if case .persistArchive(let ids) = effect { return ids }
        }
        return nil
    }

    private func frameRows(_ state: UnifiedListState, _ id: ListFrameID) -> [String]? {
        for block in state.blocks {
            if case .frame(let frame) = block, frame.id == id { return frame.rows.map(\.sessionID) }
        }
        return nil
    }

    private func archiveHeading(_ state: UnifiedListState) -> ArchiveHeadingModel? {
        for block in state.blocks {
            if case .archiveHeading(let model) = block { return model }
        }
        return nil
    }

    // MARK: - The normal list without archived conversations

    func testArchivedConversationsLeaveStarredAndRecent() {
        let s = state(stars: ["b"], archived: ["c", "e"])
        XCTAssertEqual(s.starredRows.map(\.sessionID), ["b"])
        XCTAssertEqual(s.recentRows.map(\.sessionID), ["a", "d"])
        XCTAssertFalse(s.visibleRows.contains { ["c", "e"].contains($0.sessionID) })
    }

    /// Stored values holding both a star and an archive: the star goes (an
    /// archived conversation has none) and is persisted, so an Unarchive
    /// never brings a hidden star back.
    func testAnArchivedConversationWithAStarLosesTheStar() {
        var s = UnifiedListState(home: UL.home, now: UL.now, stars: ["c", "a"], archived: ["c"])
        let effects = s.handle(.historyDelivered(browse, isFiltered: false))
        XCTAssertEqual(s.stars.sessionIDs, ["a"])
        XCTAssertTrue(effects.contains(.persistStars(["a"])))
        XCTAssertEqual(s.starredRows.map(\.sessionID), ["a"])
        XCTAssertEqual(s.recentRows.map(\.sessionID), ["b", "d", "e"])
        s.handle(.archivedMenuItemChosen)
        s.handle(.unarchiveRequested(sessionID: "c"))
        XCTAssertEqual(s.starredRows.map(\.sessionID), ["a"])
        XCTAssertEqual(s.recentRows.map(\.sessionID), ["b", "c", "d", "e"])
    }

    func testSearchingLeavesArchivedConversationsOut() {
        var s = state(stars: ["b"], archived: ["c"])
        s.handle(.queryValidityChanged(true))
        s.handle(.historyDelivered([UL.summary("c"), UL.summary("b"), UL.summary("a")], isFiltered: true))
        XCTAssertEqual(frameRows(s, .history), ["b", "a"])
        XCTAssertEqual(s.headings.map(\.countText), ["2"])
    }

    /// §9: the Recent cap applies after the archived conversations are
    /// left out.
    func testTheRecentCapCountsAfterTheArchivedAreLeftOut() {
        let results = (0..<105).map { UL.summary("c\($0)", updatedAt: Int64(9_000 - $0)) }
        let s = state(archived: ["c0", "c1", "c2", "c3", "c4"], results: results)
        XCTAssertEqual(s.recentRows.count, 100)
        XCTAssertEqual(s.hiddenRecentCount, 0, "105 - 5 archived = 100: nothing hidden")
        XCTAssertEqual(s.recentRows.first?.sessionID, "c5")
        let six = state(archived: ["c0", "c1", "c2", "c3"], results: results)
        XCTAssertEqual(six.hiddenRecentCount, 1)
        XCTAssertEqual(six.recentRows.last?.sessionID, "c103")
    }

    /// §4.6 "empty state": archived conversations do not count.
    func testTheEmptyStateDoesNotCountArchivedConversations() {
        let s = state(archived: ["a"], results: [UL.summary("a")])
        XCTAssertEqual(s.emptyStateText, "No conversations")
        XCTAssertEqual(s.blocks, [])
    }

    // MARK: - Archive and Unarchive

    func testArchiveTakesTheRowOffAtOnceAndRemovesItsStar() {
        var s = state(stars: ["a", "b"])
        let effects = s.handle(.archiveRequested(sessionID: "a"))
        XCTAssertEqual(s.archived.sessionIDs, ["a"])
        XCTAssertEqual(s.stars.sessionIDs, ["b"])
        XCTAssertTrue(effects.contains(.persistStars(["b"])))
        XCTAssertEqual(persistedArchive(effects), ["a"])
        XCTAssertFalse(effects.contains(.refetchHistory), "no new search")
        XCTAssertEqual(s.starredRows.map(\.sessionID), ["b"])
        XCTAssertFalse(s.recentRows.contains { $0.sessionID == "a" })

        // Unarchive brings it back to Recent at its newest-first place,
        // without the star.
        s.handle(.archiveRequested(sessionID: "c"))
        s.handle(.archivedMenuItemChosen)
        let back = s.handle(.unarchiveRequested(sessionID: "a"))
        XCTAssertEqual(persistedArchive(back), ["c"])
        XCTAssertEqual(s.stars.sessionIDs, ["b"], "the star does not come back")
        s.handle(.leaveArchiveView)
        XCTAssertEqual(s.recentRows.map(\.sessionID), ["a", "d", "e"])
    }

    func testArchivingTheSelectedRowDeselects() {
        var s = state(columns: .two)
        s.handle(.rowClicked(key("b")))
        s.handle(.archiveRequested(sessionID: "b"))
        XCTAssertNil(s.selection)
        XCTAssertEqual(s.paneContent, .noSelection)

        var one = state()
        one.openDetailPage(key("c"))
        one.handle(.archiveRequested(sessionID: "c"))
        XCTAssertNil(one.selection)
        XCTAssertEqual(one.page, .list)
    }

    func testArchivingAnotherRowKeepsTheSelection() {
        var s = state()
        s.handle(.rowClicked(key("b")))
        s.handle(.archiveRequested(sessionID: "c"))
        XCTAssertEqual(s.selection?.key, key("b"))
    }

    // MARK: - The row menu

    func testRowMenuItems() {
        let s = state(
            stars: ["b"],
            results: [UL.summary("a"), UL.summary("b"), UL.summary("live", live: true)],
            agents: [UL.agent("t1", session: "s1")])
        func items(_ id: String) -> [RowMenuItem]? { s.visibleRows.first { $0.sessionID == id }?.menuItems }
        XCTAssertEqual(items("a"), [RowMenuItem(command: .archive, title: "Archive", isEnabled: true)])
        XCTAssertEqual(items("b"), [RowMenuItem(command: .archive, title: "Archive", isEnabled: true)], "Starred")
        XCTAssertEqual(items("live"), [RowMenuItem(command: .archive, title: "Archive", isEnabled: false)],
                       "a live conversation's row (`· running`)")
        XCTAssertEqual(s.visibleRows.first { $0.sessionID == "live" }?.showsRunningMark, true)
        XCTAssertEqual(items("s1"), [], "a Running row has no more button")
        XCTAssertEqual(s.runningRows.first?.symbol.boxes, [.status])
        XCTAssertEqual(s.recentRows.first?.symbol.boxes, [.star, .moreButton])
        XCTAssertEqual(RowMoreButton.tooltip, "More")
        XCTAssertEqual(RowMoreButton.accessibilityLabel, "More actions")
    }

    func testAMoreButtonClickOpensTheMenuWithoutSelecting() {
        var s = state()
        s.handle(.pointerDown(surfaceKey: false, searchFieldFocused: false))
        let effects = s.handle(.moreButtonClicked(key("b")))
        XCTAssertEqual(effects, [.makeSurfaceKey, .showRowMenu(key("b"))])
        XCTAssertNil(s.selection)
        XCTAssertFalse(s.canStartCardDrag(key: key("b"), clickCount: 1, onStar: true))
        XCTAssertNil(s.dragRefusal(key: key("b"), onStar: true), "no reason shown on the more button")
    }

    /// §4.5 "collapsing sections": the second click of a sequence begun on
    /// a heading does nothing on the more button either.
    func testAMoreButtonClickContinuingAHeadingClickDoesNothing() {
        var s = state(stars: ["a"])
        s.handle(.pointerDown(surfaceKey: true, searchFieldFocused: false, clickCount: 1))
        s.handle(.headingClicked(.starred))
        s.handle(.pointerDown(surfaceKey: true, searchFieldFocused: false, clickCount: 2))
        XCTAssertEqual(s.handle(.moreButtonClicked(key("b"))), [])
    }

    // MARK: - The automatic unarchive (a state rule)

    func testALiveConversationIsNeverArchived() {
        struct Case {
            let name: String
            let agents: [Agent]
            let results: [ConversationSummary]
        }
        let cases = [
            Case(name: "the first list after launch: a Running row", agents: [UL.agent("t1", session: "a")],
                 results: browse),
            Case(name: "the search result reports it live", agents: [],
                 results: [UL.summary("a", live: true), UL.summary("b")]),
        ]
        for c in cases {
            var s = UnifiedListState(home: UL.home, now: UL.now, archived: ["a", "b"])
            var effects: [UnifiedListEffect] = []
            if !c.agents.isEmpty { effects += s.handle(.agentsUpdated(c.agents)) }
            effects += s.handle(.historyDelivered(c.results, isFiltered: false))
            XCTAssertEqual(s.archived.sessionIDs, ["b"], c.name)
            XCTAssertNotNil(persistedArchive(effects), c.name)
        }
    }

    func testARunningRowThatGainsItsSessionLaterUnarchives() {
        var s = state(archived: ["a"], agents: [UL.agent("t1", session: "")])
        XCTAssertEqual(s.archived.sessionIDs, ["a"])
        let effects = s.handle(.agentsUpdated([UL.agent("t1", session: "a")]))
        XCTAssertEqual(s.archived.sessionIDs, [])
        XCTAssertEqual(persistedArchive(effects), [])
    }

    /// A menu opened before the conversation became live: its `Archive`
    /// changes nothing — no archive, the star kept, nothing persisted.
    func testArchivingALiveConversationChangesNothing() {
        var s = state(stars: ["a"], agents: [UL.agent("t1", session: "a")])
        XCTAssertEqual(s.handle(.archiveRequested(sessionID: "a")), [])
        XCTAssertEqual(s.archived.sessionIDs, [])
        XCTAssertEqual(s.stars.sessionIDs, ["a"])
        var live = state(stars: ["x"], results: [UL.summary("x", live: true)])
        XCTAssertEqual(live.handle(.archiveRequested(sessionID: "x")), [])
        XCTAssertEqual(live.archived.sessionIDs, [])
        XCTAssertEqual(live.stars.sessionIDs, ["x"])
        XCTAssertEqual(live.starredRows.map(\.sessionID), ["x"])
    }

    func testAnUnknownStatusAgentIsNoRunningRow() {
        let s = state(archived: ["a"], agents: [UL.agent("t1", status: .unknown, session: "a")])
        XCTAssertEqual(s.archived.sessionIDs, ["a"])
    }

    // MARK: - The Archive view

    private func archiveView(
        archived: ArchivedList = ["d", "a", "c"], results: [ConversationSummary]? = nil, columns: ColumnMode = .one,
        collapsed: Set<ListHeading> = []
    ) -> UnifiedListState {
        var s = state(archived: archived, results: results, collapsed: collapsed, columns: columns)
        s.handle(.archivedMenuItemChosen)
        return s
    }

    func testTheArchiveViewShowsTheArchivedRowsInArchiveOrder() {
        var s = state(archived: ["d", "a", "c"], agents: [UL.agent("t1", session: "s1")])
        let effects = s.handle(.archivedMenuItemChosen)
        XCTAssertTrue(s.isArchiveView)
        XCTAssertTrue(effects.contains(.scrollListToTop), "shown from its top")
        XCTAssertEqual(s.blocks.map(\.id), [.archiveHeading, .frame(.archived)])
        XCTAssertEqual(archiveHeading(s)?.countText, "3")
        XCTAssertEqual(frameRows(s, .archived), ["d", "a", "c"], "the most recently archived first")
        XCTAssertEqual(s.visibleRows.map(\.sessionID), ["d", "a", "c"], "no Running, Starred or Recent rows")
        let row = s.archivedRows[0]
        XCTAssertEqual(row.section, .archived)
        XCTAssertEqual(row.symbol, .moreButtonOnly)
        XCTAssertEqual(row.symbol.boxes, [.moreButton])
        XCTAssertEqual(row.menuItems, [RowMenuItem(command: .unarchive, title: "Unarchive", isEnabled: true)])
        XCTAssertEqual(row.primaryButton.kind, .resume)
        XCTAssertTrue(row.primaryButton.isEnabled)
        XCTAssertTrue(row.branchButton.isEnabled)
        XCTAssertFalse(s.showsRunningAttentionMark)
        XCTAssertEqual(s.searchPlaceholder, "Search archived")
    }

    /// An archived conversation the search result does not hold is not
    /// shown.
    func testTheArchiveViewShowsOnlyConversationsInTheResult() {
        var s = state(archived: ["d", "a"])
        s.handle(.archivedMenuItemChosen)
        s.handle(.queryValidityChanged(true))
        s.handle(.historyDelivered([UL.summary("a"), UL.summary("b")], isFiltered: true))
        XCTAssertEqual(frameRows(s, .archived), ["a"])
        XCTAssertEqual(archiveHeading(s)?.countText, "1", "the rows shown")
        XCTAssertEqual(s.archived.sessionIDs, ["d", "a"], "a filtered result prunes nothing")
        s.handle(.historyDelivered([UL.summary("b")], isFiltered: true))
        XCTAssertEqual(s.blocks, [.archiveHeading(ArchiveHeadingModel(countText: "0")),
                                  .emptyLine("No matching conversations")])
        XCTAssertNil(s.emptyStateText, "the line sits under the band")
    }

    func testTheArchiveViewCapsLikeRecent() {
        let results = (0..<150).map { UL.summary("c\($0)", updatedAt: Int64(9_000 - $0)) }
        var s = state(archived: ArchivedList(results.map(\.sessionID)), results: results)
        XCTAssertEqual(s.recentRows, [])
        s.handle(.archivedMenuItemChosen)
        XCTAssertEqual(s.archivedRows.count, 100)
        XCTAssertEqual(s.hiddenArchivedCount, 50)
        XCTAssertEqual(archiveHeading(s)?.countText, "first 100")
        XCTAssertEqual(s.blocks.map(\.id), [.archiveHeading, .frame(.archived), .moreLine])
        XCTAssertEqual(s.hiddenArchivedText, "50 more \u{2014} search to narrow down")
        s.handle(.queryValidityChanged(true))
        s.handle(.historyDelivered(results, isFiltered: true))
        XCTAssertEqual(archiveHeading(s)?.countText, "first 100")
        XCTAssertEqual(s.hiddenArchivedText, "50 more \u{2014} refine your search")
        s.handle(.leaveArchiveView)
        XCTAssertNil(s.hiddenArchivedText)
    }

    func testBeforeTheFirstResultTheBandHasNoCount() {
        var s = UnifiedListState(home: UL.home, now: UL.now, archived: ["a"])
        s.handle(.archivedMenuItemChosen)
        XCTAssertTrue(s.isArchiveView, "the menu does not wait for a search result")
        XCTAssertEqual(s.blocks, [.archiveHeading(ArchiveHeadingModel(countText: nil))])
        s.handle(.historyDelivered([UL.summary("a")], isFiltered: false))
        XCTAssertEqual(archiveHeading(s)?.countText, "1")
        s.handle(.fullBuildChanged(true))
        XCTAssertEqual(s.blocks, [.archiveHeading(ArchiveHeadingModel(countText: nil))], "a full build")
    }

    func testTheArchivedMenuItemNeedsAnArchivedConversation() {
        var s = state()
        XCTAssertEqual(s.handle(.archivedMenuItemChosen), [])
        XCTAssertFalse(s.isArchiveView)
    }

    func testWaysBackToTheNormalList() {
        // The band click.
        var band = archiveView()
        band.handle(.pointerDown(surfaceKey: true, searchFieldFocused: true))
        let effects = band.handle(.archiveHeadingClicked)
        XCTAssertFalse(band.isArchiveView)
        XCTAssertEqual(effects, [.makeSurfaceKey, .restoreListScroll], "the keyboard focus stays")
        // The ⌄ menu's checked item.
        var menu = archiveView()
        menu.handle(.archivedMenuItemChosen)
        XCTAssertFalse(menu.isArchiveView)
        // Esc.
        var esc = archiveView()
        XCTAssertEqual(esc.perform(.leaveArchiveView), [.restoreListScroll])
        XCTAssertFalse(esc.isArchiveView)
        // Closing the surface.
        var closed = archiveView()
        XCTAssertTrue(closed.handle(.surfaceHidden).contains(.restoreListScroll))
        XCTAssertFalse(closed.isArchiveView)
        XCTAssertEqual(closed.searchPlaceholder, "Search (2+ characters)")
    }

    /// The band's second click of a double-click does nothing — the first
    /// changed what is under the pointer — so no heading toggles.
    func testADoubleClickOnTheBandTogglesNothing() {
        var s = archiveView(results: browse + [UL.summary("s1")])
        s.handle(.agentsUpdated([UL.agent("t1", session: "x")]))
        s.handle(.pointerDown(surfaceKey: true, searchFieldFocused: false, clickCount: 1))
        s.handle(.archiveHeadingClicked)
        s.handle(.pointerDown(surfaceKey: true, searchFieldFocused: false, clickCount: 2))
        s.handle(.headingClicked(.running))
        XCTAssertEqual(s.collapsedSections, [])
    }

    /// The second click of the band's double-click, landing on a row of
    /// the normal list, does nothing either.
    func testASecondClickAfterTheBandClickDoesNothingOnARow() {
        var s = archiveView(columns: .two)
        s.handle(.pointerDown(surfaceKey: true, searchFieldFocused: false, clickCount: 1))
        s.handle(.archiveHeadingClicked)
        XCTAssertFalse(s.isArchiveView)
        s.handle(.pointerDown(surfaceKey: true, searchFieldFocused: false, clickCount: 2))
        XCTAssertEqual(s.handle(.rowClicked(key("b"))), [])
        XCTAssertNil(s.selection)
    }

    func testTheRememberedClosedHeadingsDoNotApplyAndDoNotChange() {
        let closed: Set<ListHeading> = [.running, .history, .starred, .recent]
        var s = archiveView(collapsed: closed)
        XCTAssertEqual(frameRows(s, .archived), ["d", "a", "c"])
        let effects = s.handle(.headingClicked(.history))
        XCTAssertFalse(effects.contains { if case .persistCollapsedSections = $0 { return true }; return false })
        s.handle(.leaveArchiveView)
        XCTAssertEqual(s.collapsedSections, closed)
    }

    func testArchiveViewRowsCannotBeDraggedAndShowNoReason() {
        var s = archiveView()
        XCTAssertFalse(s.canStartCardDrag(key: key("a"), clickCount: 1, onStar: false))
        XCTAssertNil(s.dragRefusal(key: key("a"), onStar: false))
        s.handle(.pointerDown(surfaceKey: true, searchFieldFocused: false))
        s.handle(.rowPressed(key("a"), clickCount: 1, onStar: false, x: 0, y: 0))
        let effects = s.handle(.rowPressDragged(x: 0, y: 40))
        XCTAssertNil(s.cardDrag)
        XCTAssertNil(s.dragRefusal)
        XCTAssertEqual(effects, [])
    }

    func testRowsBehaveLikeHistoryRows() {
        var s = archiveView(columns: .two)
        let click = s.handle(.rowClicked(key("a")))
        XCTAssertEqual(s.selection?.key, key("a"))
        XCTAssertTrue(click.contains(.loadConversation(sessionID: "a")))
        s.handle(.moveDown)
        XCTAssertEqual(s.selection?.key, key("c"))
        XCTAssertEqual(s.keyContext(isPopover: false, hasMarkedText: false).isArchiveView, true)
        XCTAssertEqual(s.perform(.primary), [.invoke(.resume(sessionID: "c", cwd: "/Users/example/demo/web"))])
        var one = archiveView()
        one.openDetailPage(key("a"))
        guard case .conversation(let pane) = one.paneContent else { return XCTFail("expected the detail page") }
        XCTAssertEqual(pane.positionText, "2 / 3")
    }

    // MARK: - Selection when switching

    func testSwitchingDeselectsARowThatIsNotInTheOtherList() {
        // Normal -> Archive view: the selected Recent row is not archived.
        var s = state(archived: ["c"], columns: .two)
        s.handle(.rowClicked(key("a")))
        s.handle(.archivedMenuItemChosen)
        XCTAssertNil(s.selection)
        // Archive view -> normal: the selected archived row.
        s.handle(.rowClicked(key("c")))
        XCTAssertEqual(s.selection?.key, key("c"))
        s.handle(.leaveArchiveView)
        XCTAssertNil(s.selection)
        // One column, detail page: back to the list page.
        var one = archiveView()
        one.openDetailPage(key("a"))
        one.handle(.leaveArchiveView)
        XCTAssertNil(one.selection)
        XCTAssertEqual(one.page, .list)
        // A selected Running row (even one that just ended) is not in the
        // Archive view.
        var running = state(archived: ["c"], agents: [UL.agent("t1", session: "s1")])
        running.handle(.rowClicked(.running(target: "t1")))
        running.handle(.archivedMenuItemChosen)
        XCTAssertNil(running.selection)
    }

    func testUnarchivingTheSelectedRowDeselects() {
        var s = archiveView(columns: .two)
        s.handle(.rowClicked(key("a")))
        s.handle(.unarchiveRequested(sessionID: "a"))
        XCTAssertNil(s.selection)
        XCTAssertTrue(s.isArchiveView)
        XCTAssertEqual(frameRows(s, .archived), ["d", "c"])
    }

    func testTheAutomaticUnarchiveOfTheSelectedRowDeselects() {
        var s = archiveView()
        s.openDetailPage(key("a"))
        // Resumed: a Running row with the same session_id appears.
        s.handle(.agentsUpdated([UL.agent("t1", session: "a")]))
        XCTAssertNil(s.selection, "not moved to the Running row, which the Archive view does not show")
        XCTAssertEqual(s.page, .list)
        XCTAssertTrue(s.isArchiveView)
        XCTAssertEqual(frameRows(s, .archived), ["d", "c"])
        s.handle(.leaveArchiveView)
        XCTAssertEqual(s.runningRows.map(\.sessionID), ["a"])
    }

    func testTheLastUnarchiveReturnsToTheNormalList() {
        var s = archiveView(archived: ["a"], columns: .two)
        s.handle(.rowClicked(key("a")))
        let effects = s.handle(.unarchiveRequested(sessionID: "a"))
        XCTAssertFalse(s.isArchiveView)
        XCTAssertNil(s.selection, "deselected, although the row is now in Recent")
        XCTAssertTrue(effects.contains(.restoreListScroll))
        XCTAssertEqual(persistedArchive(effects), [])
        XCTAssertEqual(s.recentRows.map(\.sessionID), ["a", "b", "c", "d", "e"])
    }

    func testTheLastAutomaticUnarchiveOrPruneReturnsToTheNormalList() {
        var live = archiveView(archived: ["a"])
        live.handle(.agentsUpdated([UL.agent("t1", session: "a")]))
        XCTAssertFalse(live.isArchiveView)
        var pruned = archiveView(archived: ["a"])
        pruned.handle(.historyDelivered([UL.summary("b")], isFiltered: false))
        XCTAssertFalse(pruned.isArchiveView)
        XCTAssertEqual(pruned.archived, [])
    }

    func testEscDecisionInTheArchiveView() {
        let s = archiveView()
        for isPopover in [true, false] {
            for searchFieldFocused in [true, false] {
                var context = s.keyContext(isPopover: isPopover, hasMarkedText: false)
                context.searchFieldFocused = searchFieldFocused
                XCTAssertEqual(UnifiedListKeys.decide(key: .escape, modifiers: [], context: context),
                               .perform(.leaveArchiveView), "popover \(isPopover), field \(searchFieldFocused)")
                context.hasMarkedText = true
                XCTAssertEqual(UnifiedListKeys.decide(key: .escape, modifiers: [], context: context), .passThrough,
                               "the input method takes Esc while composing")
            }
        }
        let normal = state()
        XCTAssertEqual(UnifiedListKeys.decide(key: .escape, modifiers: [],
                                              context: normal.keyContext(isPopover: true, hasMarkedText: false)),
                       .perform(.closePopover))
        XCTAssertEqual(UnifiedListKeys.decide(key: .escape, modifiers: [],
                                              context: normal.keyContext(isPopover: false, hasMarkedText: false)),
                       .ignore)
    }

    // MARK: - The pane's show result

    func testShowOutcome() {
        XCTAssertEqual(ConversationShowOutcome.classify(exitCode: 0, isRunningRow: true), .messages)
        XCTAssertEqual(ConversationShowOutcome.classify(exitCode: 2, isRunningRow: true), .noConversation)
        XCTAssertEqual(ConversationShowOutcome.classify(exitCode: 2, isRunningRow: false), .unavailable)
        XCTAssertEqual(ConversationShowOutcome.classify(exitCode: 1, isRunningRow: true), .failed)
        XCTAssertEqual(ConversationShowOutcome.classify(exitCode: 1, isRunningRow: false), .failed)
    }
}
