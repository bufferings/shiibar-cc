import XCTest

@testable import ShiibarCcCore

/// The row drag (DESIGN.md §4.5 "row drag" / "row double-click" / "key
/// operations", §8.60, §9): the drop table, holding the target in gaps, the
/// start conditions and the reasons a row cannot be dragged, the cancel
/// conditions, the drop's effect on the ordered stars, what is faded and
/// hinted during a drag, and the auto-scroll speed.
final class CardDragTests: XCTestCase {
    /// Running: t1 (s1). Starred: a, b, c. Recent: h1, h2.
    private func populated(
        columns: ColumnMode = .one, collapsed: Set<ListHeading> = [], stars: StarredList = ["a", "b", "c"]
    ) -> UnifiedListState {
        var state = UnifiedListState(home: UL.home, now: UL.now, stars: stars, collapsedSections: collapsed)
        state.handle(.columnsChanged(columns))
        state.handle(.agentsUpdated([UL.agent("t1", session: "s1")]))
        state.handle(.historyDelivered(browse, isFiltered: false))
        return state
    }

    private let browse = [
        UL.summary("s1", updatedAt: 9_700, live: true), UL.summary("h1", updatedAt: 9_600),
        UL.summary("a", updatedAt: 9_500), UL.summary("b", updatedAt: 9_400),
        UL.summary("h2", updatedAt: 9_300), UL.summary("c", updatedAt: 9_200),
    ]

    private func key(_ sessionID: String) -> UnifiedRowKey { .conversation(sessionID: sessionID) }

    private func row(_ sessionID: String, upper: Bool) -> ListPointerHit {
        .element(.row(key(sessionID)), upperHalf: upper)
    }

    /// A press on a row as the mouse monitors report it, then a move of
    /// `distance` points; returns the move's effects.
    @discardableResult
    private func press(_ state: inout UnifiedListState, _ rowKey: UnifiedRowKey, clickCount: Int = 1,
                       onStar: Bool = false, surfaceKey: Bool = true, pressedAt: TimeInterval? = nil,
                       distance: Double = 4) -> [UnifiedListEffect] {
        state.handle(.pointerDown(surfaceKey: surfaceKey, searchFieldFocused: false, clickCount: clickCount,
                                  pressedAt: pressedAt))
        state.handle(.rowPressed(rowKey, clickCount: clickCount, onStar: onStar, x: 100, y: 200))
        return state.handle(.rowPressDragged(x: 100, y: 200 + distance))
    }

    @discardableResult
    private func startDrag(_ state: inout UnifiedListState, _ sessionID: String, clickCount: Int = 1,
                           surfaceKey: Bool = true, pressedAt: TimeInterval? = nil) -> [UnifiedListEffect] {
        let effects = press(&state, key(sessionID), clickCount: clickCount, surfaceKey: surfaceKey, pressedAt: pressedAt)
        XCTAssertEqual(state.cardDrag?.key, key(sessionID), "the drag started")
        return effects
    }

    private func target(_ state: UnifiedListState) -> CardDropTarget? { state.cardDrag?.target }
    private func indicator(_ state: UnifiedListState) -> CardDropIndicator? { state.cardDrag?.indicator }

    private func heading(_ state: UnifiedListState, _ heading: ListHeading) -> ListHeadingModel? {
        state.headings.first { $0.heading == heading }
    }

    // MARK: - The drop table (§4.5)

    func testTheDropTable() {
        struct Case {
            let name: String
            let source: String
            let hit: ListPointerHit
            let collapsed: Set<ListHeading>
            let target: CardDropTarget?
            let indicator: CardDropIndicator?
        }
        let cases: [Case] = [
            Case(name: "Starred row, upper half", source: "c", hit: row("b", upper: true), collapsed: [],
                 target: .starred(before: "b"), indicator: .line(before: "b")),
            Case(name: "Starred row, lower half", source: "c", hit: row("a", upper: false), collapsed: [],
                 target: .starred(before: "b"), indicator: .line(before: "b")),
            Case(name: "last Starred row, lower half: the end", source: "a", hit: row("c", upper: false), collapsed: [],
                 target: .starred(before: nil), indicator: .line(before: nil)),
            Case(name: "Recent row onto a Starred row", source: "h1", hit: row("b", upper: true), collapsed: [],
                 target: .starred(before: "b"), indicator: .line(before: "b")),
            Case(name: "open Starred heading: the first row", source: "c", hit: .element(.heading(.starred), upperHalf: false),
                 collapsed: [], target: .starred(before: "a"), indicator: .line(before: "a")),
            Case(name: "closed Starred heading: the end", source: "h1", hit: .element(.heading(.starred), upperHalf: true),
                 collapsed: [.starred], target: .starred(before: nil), indicator: .heading(.starred)),
            Case(name: "Recent heading, Starred row: unstar", source: "b", hit: .element(.heading(.recent), upperHalf: true),
                 collapsed: [], target: .unstar, indicator: .heading(.recent)),
            Case(name: "Recent row, Starred row: unstar", source: "b", hit: row("h2", upper: true),
                 collapsed: [], target: .unstar, indicator: .heading(.recent)),
            Case(name: "N more line, Starred row: unstar", source: "b", hit: .element(.moreLine, upperHalf: false),
                 collapsed: [], target: .unstar, indicator: .heading(.recent)),
            Case(name: "closed Recent heading, Starred row: unstar", source: "b",
                 hit: .element(.heading(.recent), upperHalf: false), collapsed: [.recent],
                 target: .unstar, indicator: .heading(.recent)),
            Case(name: "Recent section, Recent row: nothing", source: "h1", hit: row("h2", upper: false),
                 collapsed: [], target: nil, indicator: nil),
            Case(name: "Recent heading, Recent row: nothing", source: "h2", hit: .element(.heading(.recent), upperHalf: true),
                 collapsed: [], target: nil, indicator: nil),
            Case(name: "Running row: nothing", source: "a", hit: .element(.row(.running(target: "t1")), upperHalf: false),
                 collapsed: [], target: nil, indicator: nil),
            Case(name: "Running heading: nothing", source: "h1", hit: .element(.heading(.running), upperHalf: true),
                 collapsed: [], target: nil, indicator: nil),
            Case(name: "History heading: nothing", source: "b", hit: .element(.heading(.history), upperHalf: false),
                 collapsed: [], target: nil, indicator: nil),
            Case(name: "outside the list: nothing", source: "a", hit: .outside, collapsed: [], target: nil, indicator: nil),
        ]
        for c in cases {
            var state = populated(collapsed: c.collapsed)
            startDrag(&state, c.source)
            state.handle(.cardDragMoved(c.hit))
            XCTAssertEqual(target(state), c.target, c.name)
            XCTAssertEqual(indicator(state), c.indicator, c.name)
            let emphasized = state.headings.filter(\.isDropTarget).map(\.heading)
            if case .heading(let heading) = c.indicator {
                XCTAssertEqual(emphasized, [heading], c.name)
            } else {
                XCTAssertEqual(emphasized, [], c.name)
            }
        }
    }

    func testTheLineShowsAlsoWhereTheOrderDoesNotChange() {
        var state = populated()
        startDrag(&state, "b")
        state.handle(.cardDragMoved(row("b", upper: true)))
        XCTAssertEqual(indicator(state), .line(before: "b"))
        state.handle(.cardDragMoved(row("a", upper: false)))
        XCTAssertEqual(indicator(state), .line(before: "b"))
        state.handle(.cardDragMoved(row("b", upper: false)))
        XCTAssertEqual(indicator(state), .line(before: "c"))
    }

    /// §4.5 "row drag": gaps between elements and the list's ends.
    func testGapsAndTheListsEnds() {
        var state = UnifiedListState(home: UL.home, now: UL.now, stars: ["a", "b"])
        state.handle(.agentsUpdated([UL.agent("t1", session: "s1"), UL.agent("t2", session: "s2")]))
        state.handle(.historyDelivered([UL.summary("a"), UL.summary("b"), UL.summary("h1"), UL.summary("h2")],
                                       isFiltered: false))
        startDrag(&state, "b")
        state.handle(.cardDragMoved(row("a", upper: true)))
        state.handle(.cardDragMoved(.gap(above: .heading(.starred), below: .row(key("a")))))
        XCTAssertEqual(target(state), .starred(before: "a"), "Starred heading-frame gap: held")
        state.handle(.cardDragMoved(.gap(above: .heading(.running), below: .row(.running(target: "t1")))))
        XCTAssertNil(target(state), "a gap inside Running is Running")
        state.handle(.cardDragMoved(row("a", upper: true)))
        state.handle(.cardDragMoved(.gap(above: .row(.running(target: "t2")), below: .heading(.history))))
        XCTAssertNil(target(state), "the gap below Running's last element is Running")
        state.handle(.cardDragMoved(row("a", upper: true)))
        state.handle(.cardDragMoved(.gap(above: .heading(.history), below: .heading(.starred))))
        XCTAssertNil(target(state), "the History-Starred gap is the History heading")
        state.handle(.cardDragMoved(row("a", upper: true)))
        state.handle(.cardDragMoved(.gap(above: .row(key("b")), below: .heading(.recent))))
        XCTAssertEqual(target(state), .starred(before: "a"), "below Starred's last element up to Recent: held")
        state.handle(.cardDragMoved(.gap(above: .heading(.recent), below: .row(key("h1")))))
        XCTAssertEqual(target(state), .unstar, "a gap in Recent is Recent")
        XCTAssertEqual(indicator(state), .heading(.recent))
        state.handle(.cardDragMoved(.gap(above: .row(key("h2")), below: nil)))
        XCTAssertEqual(target(state), .unstar, "below the last element: its lower half")
        state.handle(.cardDragMoved(.gap(above: nil, below: .heading(.starred))))
        XCTAssertEqual(target(state), .starred(before: "a"), "above the first element: that element")
        state.handle(.cardDragMoved(.gap(above: nil, below: .heading(.running))))
        XCTAssertNil(target(state), "above Running's heading: Running")
        state.handle(.cardDragMoved(.outside))
        state.handle(.cardDragMoved(.gap(above: .heading(.starred), below: .row(key("a")))))
        XCTAssertNil(target(state), "nothing to hold")

        var recent = state
        recent.handle(.cardDragCancelled)
        startDrag(&recent, "h1")
        recent.handle(.cardDragMoved(.gap(above: .heading(.recent), below: .row(key("h1")))))
        XCTAssertNil(target(recent), "a Recent row over a Recent gap: nothing")
    }

    func testAClosedStarredHeadingHoldsInTheGapBelowIt() {
        var state = populated(collapsed: [.starred])
        startDrag(&state, "h1")
        state.handle(.cardDragMoved(.element(.heading(.starred), upperHalf: false)))
        state.handle(.cardDragMoved(.gap(above: .heading(.starred), below: .heading(.recent))))
        XCTAssertEqual(indicator(state), .heading(.starred))
    }

    func testWithoutRecentRowsAStarredRowCannotBeUnstarred() {
        var state = UnifiedListState(home: UL.home, now: UL.now, stars: ["a", "b"])
        state.handle(.historyDelivered([UL.summary("a"), UL.summary("b")], isFiltered: false))
        XCTAssertEqual(state.headings.map(\.heading), [.history, .starred])
        startDrag(&state, "a")
        state.handle(.cardDragMoved(.gap(above: .row(key("b")), below: nil)))
        XCTAssertEqual(target(state), .starred(before: nil), "below the list's last row: Starred's end")
        let resolver = state.dropResolver(source: .starred)
        XCTAssertNil(resolver.resolve(.gap(above: .heading(.starred), below: .row(key("a"))),
                                      previous: .heading(.recent)),
                     "no Recent on screen: an earlier unstar target does not hold")
    }

    func testTheTargetIsWorkedOutAgainWhenTheListChanges() {
        var state = populated()
        startDrag(&state, "a")
        state.handle(.cardDragMoved(row("b", upper: false)))
        XCTAssertEqual(target(state), .starred(before: "c"))
        // c starts running: b is now the last Starred row.
        state.handle(.agentsUpdated([UL.agent("t1", session: "s1"), UL.agent("t2", session: "c")]))
        XCTAssertEqual(target(state), .starred(before: nil))
        XCTAssertEqual(indicator(state), .line(before: nil))
        // The row under the pointer leaves: no target until the pointer is
        // reported again.
        state.handle(.agentsUpdated([UL.agent("t1", session: "s1"), UL.agent("t3", session: "b")]))
        XCTAssertNil(target(state))
        XCTAssertNotNil(state.cardDrag, "the dragged row is still shown")
    }

    /// A hit on a Starred heading that is no longer on screen (the list
    /// changed under the pointer) has no target.
    func testAStaleHitOnAStarredHeadingThatIsGoneHasNoTarget() {
        var state = populated(collapsed: [.starred], stars: ["a"])
        startDrag(&state, "h1")
        state.handle(.cardDragMoved(.element(.heading(.starred), upperHalf: false)))
        XCTAssertEqual(indicator(state), .heading(.starred))
        // a starts running: Starred has no rows, its heading goes away.
        state.handle(.agentsUpdated([UL.agent("t1", session: "s1"), UL.agent("t2", session: "a")]))
        XCTAssertFalse(state.headings.contains { $0.heading == .starred })
        XCTAssertNil(indicator(state))
        XCTAssertNil(state.handle(.cardDragEnded).first, "a release without a target changes nothing")
        XCTAssertEqual(state.stars, ["a"])
    }

    func testAPressPendingWhenTheSurfaceStopsBeingKeyStartsNothing() {
        var state = populated()
        state.handle(.pointerDown(surfaceKey: true, searchFieldFocused: false, clickCount: 1))
        state.handle(.rowPressed(key("a"), clickCount: 1, onStar: false, x: 0, y: 0))
        state.handle(.surfaceKeyChanged(false))
        XCTAssertEqual(state.handle(.rowPressDragged(x: 0, y: 10)), [])
        XCTAssertNil(state.cardDrag)

        var running = populated()
        running.handle(.pointerDown(surfaceKey: true, searchFieldFocused: false, clickCount: 1))
        running.handle(.rowPressed(.running(target: "t1"), clickCount: 1, onStar: false, x: 0, y: 0))
        running.handle(.surfaceKeyChanged(false))
        running.handle(.rowPressDragged(x: 0, y: 10))
        XCTAssertNil(running.dragRefusal, "no reason either")
    }

    /// While a line is shown, the line's place is where the drop puts the
    /// row — also when rows come next to the line while a gap holds the
    /// target (a running starred conversation ends during the drag).
    func testTheLineIsWhereTheDropPutsTheRowWhenRowsComeNextToIt() {
        var state = UnifiedListState(home: UL.home, now: UL.now, stars: ["a", "b", "x", "c"])
        state.handle(.agentsUpdated([UL.agent("t1", session: "s1"), UL.agent("t2", session: "x")]))
        state.handle(.historyDelivered(browse + [UL.summary("x", updatedAt: 9_000)], isFiltered: false))
        XCTAssertEqual(state.starredRows.map(\.sessionID), ["a", "b", "c"])
        startDrag(&state, "h1")
        state.handle(.cardDragMoved(row("b", upper: false)))
        XCTAssertEqual(indicator(state), .line(before: "c"))
        state.handle(.cardDragMoved(.gap(above: .row(key("c")), below: .heading(.recent))))
        XCTAssertEqual(indicator(state), .line(before: "c"), "held in the gap")
        // x ends and shows between b and c.
        state.handle(.agentsUpdated([UL.agent("t1", session: "s1")]))
        XCTAssertEqual(state.starredRows.map(\.sessionID), ["a", "b", "x", "c"])
        XCTAssertEqual(indicator(state), .line(before: "c"), "the line sits on c's top edge")
        XCTAssertEqual(target(state), .starred(before: "c"), "and the drop goes right above c")
        state.handle(.cardDragEnded)
        XCTAssertEqual(state.starredRows.map(\.sessionID), ["a", "b", "x", "h1", "c"])

        // Rows removed next to a held end line: the line stays at the end.
        var end = populated()
        startDrag(&end, "h1")
        end.handle(.cardDragMoved(row("c", upper: false)))
        end.handle(.cardDragMoved(.gap(above: .row(key("c")), below: .heading(.recent))))
        end.handle(.agentsUpdated([UL.agent("t1", session: "s1"), UL.agent("t2", session: "c")]))
        XCTAssertEqual(indicator(end), .line(before: nil))
        end.handle(.cardDragEnded)
        XCTAssertEqual(end.starredRows.map(\.sessionID), ["a", "b", "h1"])
        XCTAssertEqual(end.stars, ["a", "b", "c", "h1"])
    }

    // MARK: - Start (§4.5)

    func testStartDistanceAndMetrics() {
        XCTAssertEqual(CardDragMetrics.startDistance, 4)
        XCTAssertFalse(CardDragMetrics.hasMovedFarEnough(fromX: 10, fromY: 10, toX: 13, toY: 10))
        XCTAssertFalse(CardDragMetrics.hasMovedFarEnough(fromX: 10, fromY: 10, toX: 12.8, toY: 12.8))
        XCTAssertTrue(CardDragMetrics.hasMovedFarEnough(fromX: 10, fromY: 10, toX: 14, toY: 10))
        XCTAssertTrue(CardDragMetrics.hasMovedFarEnough(fromX: 10, fromY: 10, toX: 10, toY: 6))
        XCTAssertEqual(CardDragMetrics.ghostOpacity, 0.92)
        XCTAssertEqual(CardDragMetrics.liftedOpacity, 0.35)
        XCTAssertEqual(CardDragMetrics.dimmedOpacity, 0.4)
        XCTAssertEqual(CardDragMetrics.refusalSeconds, 2)

        var near = populated()
        press(&near, key("a"), distance: 3.9)
        XCTAssertNil(near.cardDrag, "under 4pt: no drag yet")
        near.handle(.rowPressDragged(x: 100, y: 204))
        XCTAssertEqual(near.cardDrag?.key, key("a"), "4pt: the drag starts")
    }

    func testWhichPressesStartADrag() {
        var starred = populated()
        press(&starred, key("a"))
        XCTAssertEqual(starred.cardDrag?.section, .starred, "a Starred row")
        var recent = populated()
        press(&recent, key("h1"))
        XCTAssertEqual(recent.cardDrag?.section, .recent, "a Recent row")
        var star = populated()
        XCTAssertEqual(press(&star, key("a"), onStar: true), [])
        XCTAssertNil(star.cardDrag, "on the star")
        XCTAssertNil(star.dragRefusal, "no reason on the star")
        var closedStarred = populated(collapsed: [.starred])
        press(&closedStarred, key("h1"))
        XCTAssertNotNil(closedStarred.cardDrag, "a closed Starred with rows still takes a drop")
        var hidden = populated(collapsed: [.recent])
        XCTAssertEqual(press(&hidden, key("h1")), [])
        XCTAssertNil(hidden.cardDrag, "a row not shown")
    }

    func testTheSecondPressOfADoubleClickDoesNotStartADrag() {
        var state = populated()
        state.handle(.pointerDown(surfaceKey: true, searchFieldFocused: false, clickCount: 1))
        state.handle(.rowPressed(key("a"), clickCount: 1, onStar: false, x: 0, y: 0))
        state.handle(.rowPressReleased)
        state.handle(.rowClicked(key("a")))
        XCTAssertEqual(press(&state, key("a"), clickCount: 2), [])
        XCTAssertNil(state.cardDrag)
        var other = populated()
        other.handle(.pointerDown(surfaceKey: true, searchFieldFocused: false, clickCount: 1))
        other.handle(.rowClicked(key("a")))
        press(&other, key("b"), clickCount: 2)
        XCTAssertEqual(other.cardDrag?.key, key("b"), "a press counted as a repeat on another row starts a new sequence there")
    }

    func testAPressOnANonKeySurfaceCanStartADrag() {
        var state = populated(columns: .two)
        state.handle(.surfaceKeyChanged(false))
        state.handle(.pointerDown(surfaceKey: false, searchFieldFocused: false, clickCount: 1))
        state.handle(.rowPressed(key("b"), clickCount: 1, onStar: false, x: 0, y: 0))
        state.handle(.surfaceKeyChanged(true))
        let effects = state.handle(.rowPressDragged(x: 0, y: 10))
        XCTAssertEqual(effects, [.focusList, .loadConversation(sessionID: "b")])
        XCTAssertEqual(state.cardDrag?.key, key("b"))
    }

    func testStartingSelectsAndFocusesLikeAClickAndThePressIsNoClick() {
        var state = populated()
        let effects = startDrag(&state, "b")
        XCTAssertEqual(effects, [.focusList])
        XCTAssertEqual(state.selection?.key, key("b"))
        XCTAssertEqual(state.cardDrag, CardDrag(key: key("b"), sessionID: "b", section: .starred))
        state.handle(.cardDragMoved(.outside))
        state.handle(.cardDragEnded)
        XCTAssertEqual(state.handle(.rowClicked(key("b"))), [], "the release is not a click")
        XCTAssertEqual(state.selection?.key, key("b"))
        // The next press is a fresh click, not the second click of a
        // double-click: no Resume.
        state.handle(.pointerDown(surfaceKey: true, searchFieldFocused: false, clickCount: 2))
        let next = state.handle(.rowClicked(key("b")))
        XCTAssertFalse(next.contains { if case .invoke = $0 { return true } else { return false } })
        XCTAssertNotNil(state.pendingDeselect, "a single click on the accent row")
    }

    /// §4.5 "row drag": an accent selected Starred / Recent row held past
    /// the double-click interval deselects at the release (the deferred
    /// deselect is timed from the press, so it is due at once); a drag
    /// started before the release never deselects.
    func testAnAccentRowHeldPastTheIntervalDeselectsAtReleaseUnlessDragged() {
        var held = populated()
        held.handle(.rowClicked(key("a")))
        held.handle(.pointerDown(surfaceKey: true, searchFieldFocused: false, clickCount: 1, pressedAt: 100))
        held.handle(.rowPressed(key("a"), clickCount: 1, onStar: false, x: 0, y: 0))
        XCTAssertEqual(held.selection?.key, key("a"), "nothing while the button is down")
        held.handle(.rowPressReleased)
        let effects = held.handle(.rowClicked(key("a")))
        XCTAssertEqual(effects, [.scheduleDeferredDeselect(id: 1, pressedAt: 100), .focusList])
        held.handle(.deferredDeselectDue(id: 1))
        XCTAssertNil(held.selection)

        var dragged = populated()
        dragged.handle(.rowClicked(key("a")))
        startDrag(&dragged, "a", pressedAt: 100)
        dragged.handle(.cardDragMoved(.outside))
        dragged.handle(.cardDragEnded)
        XCTAssertEqual(dragged.handle(.rowClicked(key("a"))), [])
        XCTAssertNil(dragged.pendingDeselect)
        XCTAssertEqual(dragged.selection?.key, key("a"))
    }

    /// §4.5 "row double-click" / "row drag": click a blue row, press it
    /// again within the interval and hold past it — the deselect does not
    /// run while the button is down; the release is the double-click.
    func testASecondPressHeldOnTheBlueRowCancelsThePendingDeselect() {
        var state = populated()
        state.handle(.rowClicked(key("a")))
        state.handle(.pointerDown(surfaceKey: true, searchFieldFocused: false, clickCount: 1, pressedAt: 100))
        state.handle(.rowClicked(key("a")))
        XCTAssertNotNil(state.pendingDeselect)
        state.handle(.pointerDown(surfaceKey: true, searchFieldFocused: false, clickCount: 2, pressedAt: 100.2))
        state.handle(.rowPressed(key("a"), clickCount: 2, onStar: false, x: 0, y: 0))
        XCTAssertNil(state.pendingDeselect)
        state.handle(.deferredDeselectDue(id: 1))
        XCTAssertEqual(state.selection?.key, key("a"), "held: still selected")
        let release = state.handle(.rowClicked(key("a")))
        XCTAssertTrue(release.contains(.invoke(.resume(sessionID: "a", cwd: "/Users/example/demo/web"))))
        XCTAssertEqual(state.selection?.key, key("a"))

        // A single press, or a repeat on another row, leaves it.
        var other = populated()
        other.handle(.rowClicked(key("a")))
        other.handle(.pointerDown(surfaceKey: true, searchFieldFocused: false, clickCount: 1))
        other.handle(.rowClicked(key("a")))
        other.handle(.rowPressed(key("a"), clickCount: 1, onStar: false, x: 0, y: 0))
        other.handle(.rowPressed(key("b"), clickCount: 2, onStar: false, x: 0, y: 0))
        XCTAssertNotNil(other.pendingDeselect)
    }

    // MARK: - Rows that cannot be dragged (§4.5)

    func testTheReasonsARowCannotBeDragged() {
        struct Case {
            let name: String
            let stars: StarredList
            let searching: Bool
            let row: UnifiedRowKey
            let text: String
        }
        let cases = [
            Case(name: "a Running row", stars: ["a"], searching: false, row: .running(target: "t1"),
                 text: "Running is ordered automatically"),
            Case(name: "a Running row while searching: the Running reason first", stars: ["a"], searching: true,
                 row: .running(target: "t1"), text: "Running is ordered automatically"),
            Case(name: "a Starred row while searching", stars: ["a"], searching: true, row: key("a"),
                 text: "Clear the search to reorder"),
            Case(name: "a Recent row while searching, no Starred rows: searching first", stars: [], searching: true,
                 row: key("h1"), text: "Clear the search to reorder"),
            Case(name: "a Recent row without Starred rows", stars: [], searching: false, row: key("h1"),
                 text: "Click the star to add it to Starred"),
            Case(name: "a Recent row while the only star is running", stars: ["s1"], searching: false, row: key("h1"),
                 text: "Click the star to add it to Starred"),
        ]
        for c in cases {
            var state = populated(stars: c.stars)
            if c.searching {
                state.handle(.queryValidityChanged(true))
                state.handle(.historyDelivered(browse, isFiltered: true))
            }
            let effects = press(&state, c.row)
            XCTAssertNil(state.cardDrag, c.name)
            XCTAssertEqual(state.dragRefusal?.text, c.text, c.name)
            XCTAssertEqual(effects, [.scheduleDragRefusalDismiss(id: 1, afterSeconds: 2)], c.name)
        }
    }

    func testTheReasonShowsOncePerPressAndGoesAway() {
        var state = populated()
        press(&state, .running(target: "t1"))
        XCTAssertEqual(state.dragRefusal, DragRefusalNotice(id: 1, refusal: .running))
        XCTAssertEqual(state.handle(.rowPressDragged(x: 100, y: 260)), [], "once per press")
        state.handle(.dragRefusalDismissDue(id: 2))
        XCTAssertNotNil(state.dragRefusal, "another schedule's answer leaves it")
        state.handle(.dragRefusalDismissDue(id: 1))
        XCTAssertNil(state.dragRefusal, "§9 time passed")

        press(&state, .running(target: "t1"))
        XCTAssertEqual(state.dragRefusal?.id, 2)
        state.handle(.pointerDown(surfaceKey: true, searchFieldFocused: false, clickCount: 1))
        XCTAssertNil(state.dragRefusal, "the next press clears it")

        press(&state, .running(target: "t1"))
        state.handle(.surfaceHidden)
        XCTAssertNil(state.dragRefusal)
    }

    func testNoReasonOnTheSecondPressOfADoubleClick() {
        var state = populated()
        state.handle(.pointerDown(surfaceKey: true, searchFieldFocused: false, clickCount: 1))
        state.handle(.rowClicked(.running(target: "t1")))
        XCTAssertEqual(press(&state, .running(target: "t1"), clickCount: 2), [])
        XCTAssertNil(state.dragRefusal)
    }

    func testARefusedPressStillClicks() {
        var state = populated()
        press(&state, .running(target: "t1"))
        state.handle(.rowPressReleased)
        XCTAssertEqual(state.handle(.rowClicked(.running(target: "t1"))), [.focusList])
        XCTAssertEqual(state.selection?.key, .running(target: "t1"), "the click selects as usual")
    }

    // MARK: - During a drag: faded rows and heading hints (§4.5)

    func testFadedRowsAndHintsWhileAStarredRowIsDragged() {
        var state = populated()
        startDrag(&state, "b")
        let faded = state.visibleRows.filter(state.isRowDimmed).map(\.id)
        XCTAssertEqual(faded, [.running(target: "t1"), key("h1"), key("h2")])
        XCTAssertNil(heading(state, .starred)?.hint)
        XCTAssertEqual(heading(state, .recent)?.hint, "Drop here to unstar")
        state.handle(.cardDragMoved(row("a", upper: true)))
        XCTAssertFalse(frameEmphasized(state), "no frame emphasis for a Starred row")
        // Closing Recent (a click without a press record) keeps the hint.
        state.handle(.headingClicked(.recent))
        XCTAssertEqual(heading(state, .recent)?.isOpen, false)
        XCTAssertEqual(heading(state, .recent)?.hint, "Drop here to unstar", "also while closed")
        state.handle(.cardDragCancelled)
        XCTAssertFalse(state.visibleRows.contains(where: state.isRowDimmed))
        XCTAssertTrue(state.headings.allSatisfy { $0.hint == nil })
    }

    func testFadedRowsHintsAndFrameEmphasisWhileARecentRowIsDragged() {
        var state = populated()
        startDrag(&state, "h1")
        let faded = state.visibleRows.filter(state.isRowDimmed).map(\.id)
        XCTAssertEqual(faded, [.running(target: "t1"), key("h2")], "not the dragged row, not Starred rows")
        XCTAssertEqual(heading(state, .starred)?.hint, "Drop here to star")
        XCTAssertNil(heading(state, .recent)?.hint)
        XCTAssertFalse(frameEmphasized(state))
        state.handle(.cardDragMoved(row("a", upper: false)))
        XCTAssertTrue(frameEmphasized(state), "the line is shown: the Starred frame is emphasized")
        state.handle(.cardDragMoved(.outside))
        XCTAssertFalse(frameEmphasized(state))

        var closed = populated(collapsed: [.starred])
        startDrag(&closed, "h1")
        XCTAssertEqual(heading(closed, .starred)?.hint, "Drop here to star", "also while closed")
    }

    private func frameEmphasized(_ state: UnifiedListState) -> Bool {
        state.blocks.contains { block in
            if case .frame(let frame) = block { return frame.id == .starred && frame.isEmphasized }
            return false
        }
    }

    // MARK: - Drop (§4.5)

    private func drop(_ state: inout UnifiedListState, _ sessionID: String, at hit: ListPointerHit) -> [UnifiedListEffect] {
        startDrag(&state, sessionID)
        state.handle(.cardDragMoved(hit))
        return state.handle(.cardDragEnded)
    }

    func testDropReordersStarred() {
        var state = populated()
        XCTAssertEqual(drop(&state, "c", at: row("a", upper: false)), [.persistStars(["a", "c", "b"])])
        XCTAssertEqual(state.starredRows.map(\.sessionID), ["a", "c", "b"])
        XCTAssertEqual(state.selection?.key, key("c"), "the moved row stays selected")
        XCTAssertNil(state.cardDrag)
        XCTAssertEqual(drop(&state, "a", at: .element(.heading(.starred), upperHalf: true)), [],
                       "to the top it already holds: nothing")
        XCTAssertEqual(drop(&state, "a", at: row("b", upper: false)), [.persistStars(["c", "b", "a"])])
    }

    func testDropFromRecentStarsAtThePlace() {
        var state = populated()
        XCTAssertEqual(drop(&state, "h2", at: row("b", upper: true)), [.persistStars(["a", "h2", "b", "c"])])
        XCTAssertEqual(state.starredRows.map(\.sessionID), ["a", "h2", "b", "c"])
        XCTAssertEqual(state.recentRows.map(\.sessionID), ["h1"])
        XCTAssertEqual(state.selection?.key, key("h2"))
    }

    func testDropOnRecentUnstars() {
        var state = populated()
        XCTAssertEqual(drop(&state, "a", at: .element(.heading(.recent), upperHalf: true)), [.persistStars(["b", "c"])])
        XCTAssertEqual(state.recentRows.map(\.sessionID), ["h1", "a", "h2"], "at its newest-first place")
        XCTAssertEqual(state.selection?.key, key("a"))
    }

    func testDropOnAClosedRecentUnstarsAndDeselects() {
        var state = populated(collapsed: [.recent])
        XCTAssertEqual(drop(&state, "a", at: .element(.heading(.recent), upperHalf: true)), [.persistStars(["b", "c"])])
        XCTAssertNil(state.selection, "the row is in a closed section")
    }

    func testDropAtTheSamePlaceChangesNothing() {
        var state = populated()
        XCTAssertEqual(drop(&state, "b", at: row("b", upper: false)), [], "below itself")
        XCTAssertEqual(drop(&state, "b", at: row("c", upper: true)), [], "before its next")
        XCTAssertEqual(drop(&state, "b", at: row("a", upper: false)), [], "after its previous")
        XCTAssertEqual(state.stars, ["a", "b", "c"])
    }

    func testADropAtTheSameDisplayedPlaceWithAHiddenRunningStarChangesNothing() {
        var state = populated(stars: ["a", "b", "s1", "c"])
        XCTAssertEqual(state.starredRows.map(\.sessionID), ["a", "b", "c"])
        XCTAssertEqual(drop(&state, "b", at: row("b", upper: false)), [], "on its own lower half")
        XCTAssertEqual(drop(&state, "b", at: row("c", upper: true)), [], "on the next row's upper half")
        XCTAssertEqual(state.stars, ["a", "b", "s1", "c"], "the hidden star keeps its place")

        var last = populated(stars: ["a", "c", "s1"])
        XCTAssertEqual(drop(&last, "c", at: row("c", upper: false)), [])
        XCTAssertEqual(last.stars, ["a", "c", "s1"])
    }

    func testRunningConversationsKeepTheirPlaceInTheList() {
        var state = populated(stars: ["a", "s1", "b", "c"])
        XCTAssertEqual(state.starredRows.map(\.sessionID), ["a", "b", "c"])
        XCTAssertEqual(drop(&state, "c", at: row("a", upper: true)), [.persistStars(["c", "a", "s1", "b"])])
        XCTAssertEqual(drop(&state, "a", at: row("b", upper: false)), [.persistStars(["c", "s1", "b", "a"])])
    }

    func testDropOnAClosedStarredGoesToTheEndAndDeselects() {
        var state = populated(collapsed: [.starred])
        XCTAssertEqual(drop(&state, "h1", at: .element(.heading(.starred), upperHalf: false)),
                       [.persistStars(["a", "b", "c", "h1"])])
        XCTAssertNil(state.selection, "the row is in a closed section")
    }

    // MARK: - Cancel (§4.5)

    func testEveryCancelTriggerEndsTheDragWithNothingChanged() {
        struct Case {
            let name: String
            let event: UnifiedListEvent
            /// The stars after it (a browse refetch prunes on its own).
            let stars: StarredList
        }
        let cases = [
            Case(name: "released without a target", event: .cardDragEnded, stars: ["a", "b", "c"]),
            Case(name: "Esc (the app's cancel)", event: .cardDragCancelled, stars: ["a", "b", "c"]),
            Case(name: "the surface closed", event: .surfaceHidden, stars: ["a", "b", "c"]),
            Case(name: "the window stopped being key", event: .surfaceKeyChanged(false), stars: ["a", "b", "c"]),
            Case(name: "searching started", event: .queryValidityChanged(true), stars: ["a", "b", "c"]),
            Case(name: "the row started running",
                 event: .agentsUpdated([UL.agent("t1", session: "s1"), UL.agent("t2", session: "b")]),
                 stars: ["a", "b", "c"]),
            Case(name: "a refetch without the row",
                 event: .historyDelivered(browse.filter { $0.sessionID != "b" }, isFiltered: false),
                 stars: ["a", "c"]),
        ]
        for c in cases {
            var state = populated()
            let started = startDrag(&state, "b")
            XCTAssertEqual(started, [.focusList], c.name)
            if c.event == .cardDragEnded {
                state.handle(.cardDragMoved(.outside))
            } else {
                state.handle(.cardDragMoved(row("a", upper: true)))
                XCTAssertNotNil(state.cardDrag?.target, c.name)
            }
            let effects = state.handle(c.event)
            XCTAssertNil(state.cardDrag, c.name)
            XCTAssertEqual(state.stars, c.stars, c.name)
            XCTAssertFalse(effects.contains(.persistStars(["a", "b", "c"])), c.name)
            // (The row that left the list is no longer selectable.)
            if c.name.hasPrefix("the row started") || c.name.hasPrefix("a refetch") {
                continue
            }
            // The selection and focus made at the start are kept.
            XCTAssertEqual(state.selection?.key, key("b"), c.name)
            XCTAssertFalse(effects.contains(.focusSearchField), c.name)
        }
    }

    func testARecentRowPushedBeyondTheCapCancels() {
        var state = UnifiedListState(home: UL.home, now: UL.now, stars: ["s"])
        let results = [UL.summary("s", updatedAt: 9_900)]
            + (0..<100).map { UL.summary("c\($0)", updatedAt: Int64(9_000 - $0)) }
        state.handle(.historyDelivered(results, isFiltered: false))
        startDrag(&state, "c99")
        state.handle(.historyDelivered([UL.summary("new", updatedAt: 9_500)] + results, isFiltered: false))
        XCTAssertNil(state.cardDrag)
    }

    func testEscDuringADragCancelsOnlyTheDrag() {
        var state = populated()
        startDrag(&state, "b")
        let context = state.keyContext(isPopover: true, hasMarkedText: false)
        XCTAssertTrue(context.cardDragging)
        let decision = UnifiedListKeys.decide(key: .escape, modifiers: [], context: context)
        XCTAssertEqual(decision, .perform(.cancelCardDrag), "not closePopover")
        XCTAssertEqual(state.perform(.cancelCardDrag), [])
        XCTAssertNil(state.cardDrag)
    }

    func testOtherTableKeysDoNothingDuringADrag() {
        var context = populated().keyContext(isPopover: true, hasMarkedText: false)
        context.cardDragging = true
        let consumed: [(ListKey, ListKeyModifiers)] = [
            (.upArrow, []), (.downArrow, [.option]), (.leftArrow, []), (.rightArrow, []), (.returnKey, []),
            (.returnKey, [.command]), (.delete, []), (.other(charactersIgnoringModifiers: "a"), []),
            (.other(charactersIgnoringModifiers: "f"), [.command]), (.other(charactersIgnoringModifiers: "r"), [.command]),
            (.other(charactersIgnoringModifiers: "="), [.command]), (.other(charactersIgnoringModifiers: "g"), [.command]),
        ]
        for (key, modifiers) in consumed {
            XCTAssertEqual(UnifiedListKeys.decide(key: key, modifiers: modifiers, context: context), .ignore, "\(key) \(modifiers)")
        }
        XCTAssertEqual(UnifiedListKeys.decide(key: .other(charactersIgnoringModifiers: "c"), modifiers: [.command],
                                              context: context), .passThrough, "a key outside the table")
    }

    // MARK: - Hit testing

    func testHitTestingByHeight() {
        let elements = [
            ListElementExtent(kind: .heading(.starred), top: 8, bottom: 30, minX: 10, maxX: 410),
            ListElementExtent(kind: .row(key("a")), top: 35, bottom: 100, minX: 11, maxX: 409),
            ListElementExtent(kind: .star(key("a")), top: 44, bottom: 64, minX: 370, maxX: 390),
            ListElementExtent(kind: .row(key("b")), top: 100, bottom: 165, minX: 11, maxX: 409),
            ListElementExtent(kind: .heading(.recent), top: 172, bottom: 194, minX: 10, maxX: 410),
        ]
        XCTAssertEqual(ListPointerHitTest.hit(y: 50, insideList: true, elements: elements), row("a", upper: true))
        XCTAssertEqual(ListPointerHitTest.hit(y: 68, insideList: true, elements: elements), row("a", upper: false))
        XCTAssertEqual(ListPointerHitTest.hit(y: 100, insideList: true, elements: elements), row("b", upper: true),
                       "rows touch: no gap between them")
        XCTAssertEqual(ListPointerHitTest.hit(y: 168, insideList: true, elements: elements),
                       .gap(above: .row(key("b")), below: .heading(.recent)))
        XCTAssertEqual(ListPointerHitTest.hit(y: 2, insideList: true, elements: elements),
                       .gap(above: nil, below: .heading(.starred)))
        XCTAssertEqual(ListPointerHitTest.hit(y: 50, insideList: false, elements: elements), .outside)
        XCTAssertEqual(ListPointerHitTest.pressedRow(x: 100, y: 50, elements: elements)?.key, key("a"))
        XCTAssertEqual(ListPointerHitTest.pressedRow(x: 100, y: 50, elements: elements)?.onStar, false)
        XCTAssertEqual(ListPointerHitTest.pressedRow(x: 380, y: 50, elements: elements)?.onStar, true)
        XCTAssertNil(ListPointerHitTest.pressedRow(x: 5, y: 50, elements: elements), "the side padding is no row")
        XCTAssertNil(ListPointerHitTest.pressedRow(x: 100, y: 20, elements: elements), "a heading is no row")
    }

    // MARK: - Auto-scroll (§9)

    func testAutoScrollSpeed() {
        struct Case {
            let points: Int
            let zone: Double
        }
        for c in [Case(points: 9, zone: 40.0 * 9 / 13), Case(points: 13, zone: 40), Case(points: 18, zone: 40.0 * 18 / 13)] {
            let size = TextSize(clamping: c.points)
            let height = 400.0
            XCTAssertEqual(CardDragAutoScroll.zone(textSize: size), c.zone, accuracy: 1e-9)
            func v(_ y: Double) -> Double { CardDragAutoScroll.velocity(pointerY: y, viewportHeight: height, textSize: size) }
            XCTAssertEqual(v(0), -1200, accuracy: 1e-9, "top edge, \(c.points)")
            XCTAssertEqual(v(c.zone), -120, accuracy: 1e-9, "the zone's inner end, \(c.points)")
            XCTAssertEqual(v(c.zone / 2), -660, accuracy: 1e-9, "linear between, \(c.points)")
            XCTAssertEqual(v(height), 1200, accuracy: 1e-9, "bottom edge, \(c.points)")
            XCTAssertEqual(v(height - c.zone), 120, accuracy: 1e-9)
            XCTAssertEqual(v(height - c.zone / 4), 1200 - 1080 / 4, accuracy: 1e-9)
            XCTAssertEqual(v(c.zone + 1), 0, "outside the zones, \(c.points)")
            XCTAssertEqual(v(height / 2), 0)
            XCTAssertEqual(v(-1), -1200, "above the list: the edge speed")
            XCTAssertEqual(v(-500), -1200)
            XCTAssertEqual(v(height + 1), 1200, "below the list: the edge speed")
            XCTAssertEqual(v(height + 500), 1200)
        }
    }
}
