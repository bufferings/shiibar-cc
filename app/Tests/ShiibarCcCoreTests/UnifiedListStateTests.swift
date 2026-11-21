import XCTest

@testable import ShiibarCcCore

/// The shared list state machine (DESIGN.md §4.5 "row selection" / "row
/// click" / "row double-click" / "opening the detail page" / "switching by
/// width" / "key operations", §4.6 "display state rules" / "History refetch
/// triggers" / "bottom panel").
final class UnifiedListStateTests: XCTestCase {
    /// Running: t1 (s1, newest), t2 (s2). History: h1, h2, h3.
    private func populated(columns: ColumnMode = .one) -> UnifiedListState {
        var state = UnifiedListState(home: UL.home, now: UL.now)
        state.handle(.columnsChanged(columns))
        state.handle(.agentsUpdated([
            UL.agent("t1", session: "s1", createdAt: 20),
            UL.agent("t2", session: "s2", createdAt: 10),
        ]))
        state.handle(.historyDelivered(
            [UL.summary("s1", live: true), UL.summary("h1"), UL.summary("h2"), UL.summary("h3")],
            isFiltered: false))
        return state
    }

    private var order: [UnifiedRowKey] {
        [.running(target: "t1"), .running(target: "t2"),
         .conversation(sessionID: "h1"), .conversation(sessionID: "h2"), .conversation(sessionID: "h3")]
    }

    // MARK: - Launch and ↑ / ↓

    func testLaunchHasNoSelection() {
        let state = populated()
        XCTAssertNil(state.selection)
        XCTAssertEqual(state.page, .list)
        XCTAssertEqual(state.visibleRows.map(\.id), order)
        XCTAssertEqual(state.paneContent, .hidden)
        XCTAssertEqual(populated(columns: .two).paneContent, .noSelection)
    }

    func testArrowWithoutSelectionSelectsTheFirstRow() {
        for event in [UnifiedListEvent.moveUp, .moveDown] {
            var state = populated()
            let effects = state.handle(event)
            XCTAssertEqual(state.selection?.key, .running(target: "t1"), "\(event)")
            XCTAssertEqual(effects, [.scrollSelectionIntoView], "\(event): list page, no pane load")
        }
    }

    func testArrowWithNoRowsDoesNothing() {
        var state = UnifiedListState(home: UL.home, now: UL.now)
        XCTAssertEqual(state.handle(.moveDown), [])
        XCTAssertNil(state.selection)
    }

    func testArrowsMoveAndStopAtTheEdges() {
        var state = populated()
        state.handle(.moveDown) // t1
        XCTAssertEqual(state.handle(.moveUp), [], "top edge: no move")
        XCTAssertEqual(state.selection?.key, .running(target: "t1"))
        for expected in order.dropFirst() {
            XCTAssertEqual(state.handle(.moveDown), [.scrollSelectionIntoView])
            XCTAssertEqual(state.selection?.key, expected)
        }
        XCTAssertEqual(state.handle(.moveDown), [], "bottom edge: no move")
        XCTAssertEqual(state.selection?.key, .conversation(sessionID: "h3"))
        state.handle(.moveUp)
        XCTAssertEqual(state.selection?.key, .conversation(sessionID: "h2"))
    }

    func testArrowsMoveWithinSearchResultsOnly() {
        var state = populated()
        state.handle(.historyDelivered([UL.summary("s2"), UL.summary("h2")], isFiltered: true))
        XCTAssertEqual(state.visibleRows.map(\.id), [.running(target: "t2"), .conversation(sessionID: "h2")])
        state.handle(.moveDown)
        state.handle(.moveDown)
        XCTAssertEqual(state.selection?.key, .conversation(sessionID: "h2"))
        state.handle(.moveDown)
        XCTAssertEqual(state.selection?.key, .conversation(sessionID: "h2"))
    }

    /// ⌥↑ / ⌥↓ and the detail header's prev / next buttons (§4.5 "key
    /// operations", §4.6): the shown conversation switches to the previous /
    /// next row's, the selection moves with it, the page stays (no slide),
    /// and nothing happens at the ends.
    func testPreviousNextConversationOnTheDetailPage() {
        var state = populated()
        state.openDetailPage(.conversation(sessionID: "h1"))
        XCTAssertEqual(state.page, .detail)
        let effects = state.handle(.nextConversation)
        XCTAssertEqual(state.page, .detail)
        XCTAssertEqual(state.selection?.key, .conversation(sessionID: "h2"))
        XCTAssertEqual(effects, [.loadConversation(sessionID: "h2")])
        XCTAssertEqual(state.handle(.previousConversation), [.loadConversation(sessionID: "h1")])
        XCTAssertEqual(state.selection?.key, .conversation(sessionID: "h1"))
        // Back to the list page: bring the moved selection into view; the
        // focus is the list.
        XCTAssertEqual(state.handle(.back), [.scrollSelectionIntoView, .focusList])
        XCTAssertEqual(state.page, .list)
    }

    func testPreviousNextConversationStopAtTheEnds() {
        var state = populated()
        state.openDetailPage(order[0])
        XCTAssertEqual(state.handle(.previousConversation), [], "first row: nothing")
        XCTAssertEqual(state.selection?.key, order[0])
        state.openDetailPage(order[order.count - 1])
        XCTAssertEqual(state.handle(.nextConversation), [], "last row: nothing")
        XCTAssertEqual(state.selection?.key, order[order.count - 1])
        XCTAssertEqual(state.page, .detail)
    }

    /// The decided commands reach the same events.
    func testPerformPreviousNextConversation() {
        var state = populated()
        state.openDetailPage(.conversation(sessionID: "h1"))
        XCTAssertEqual(state.perform(.nextConversation), [.loadConversation(sessionID: "h2")])
        XCTAssertEqual(state.perform(.previousConversation), [.loadConversation(sessionID: "h1")])
    }

    /// §4.5 "row selection": the selected card is accent while the keys act
    /// on the list — the surface is key and the list has focus — and gray
    /// while the search field has focus or the surface is not key.
    func testSelectionLookFollowsTheFocus() {
        var state = populated()
        state.handle(.moveDown)
        XCTAssertTrue(state.isSelectionActive)
        state.handle(.searchFieldFocusChanged(true))
        XCTAssertFalse(state.isSelectionActive)
        state.handle(.enterFromSearchField)
        state.handle(.searchFieldFocusChanged(false))
        XCTAssertTrue(state.isSelectionActive)
    }

    func testSelectionLookFollowsFocusAndKeyStatus() {
        struct Case {
            let name: String
            let surfaceKey: Bool
            let searchFieldFocused: Bool
            let active: Bool
        }
        let cases = [
            Case(name: "key, list focus", surfaceKey: true, searchFieldFocused: false, active: true),
            Case(name: "key, search field focus", surfaceKey: true, searchFieldFocused: true, active: false),
            Case(name: "not key, list focus", surfaceKey: false, searchFieldFocused: false, active: false),
            Case(name: "not key, search field focus", surfaceKey: false, searchFieldFocused: true, active: false),
        ]
        for columns in [ColumnMode.one, .two] {
            for testCase in cases {
                let name = "\(columns), \(testCase.name)"
                var state = populated(columns: columns)
                state.handle(.rowClicked(.conversation(sessionID: "h1")))
                XCTAssertEqual(state.handle(.surfaceKeyChanged(testCase.surfaceKey)), [], name)
                XCTAssertEqual(state.handle(.searchFieldFocusChanged(testCase.searchFieldFocused)), [], name)
                XCTAssertEqual(state.isSurfaceKey, testCase.surfaceKey, name)
                XCTAssertEqual(state.isSelectionActive, testCase.active, name)
                // The key hints and the bottom panel's buttons follow the
                // search field's focus only, not the key status (§4.5 "key
                // hints", §4.6 "bottom panel").
                XCTAssertEqual(state.footerHints, testCase.searchFieldFocused ? [.list] : [.move], name)
                if columns == .one {
                    XCTAssertEqual(state.listBottomPanel?.buttons != nil, !testCase.searchFieldFocused, name)
                } else {
                    guard case .conversation(let pane) = state.paneContent else { return XCTFail("expected a pane") }
                    XCTAssertEqual(pane.bottomPanel.buttons != nil, !testCase.searchFieldFocused, name)
                }
                // The key status changes no selection and no page.
                XCTAssertEqual(state.selection?.key, .conversation(sessionID: "h1"), name)
                XCTAssertEqual(state.page, .list, name)
            }
        }
    }

    // MARK: - Click

    /// §4.5 "row click": a click on an unselected row only selects it, in
    /// one column and in two, and moves focus to the list; it never opens
    /// the detail page. Two columns show the selected conversation in the
    /// right column (so it loads there).
    func testRowClickOnlySelects() {
        struct Case {
            let name: String
            let columns: ColumnMode
            /// Select this row first (nil = start with no selection).
            let preselected: UnifiedRowKey?
            let clicked: UnifiedRowKey
            let expectedSessionID: String
            let expectedEffects: [UnifiedListEffect]
        }
        let cases = [
            Case(name: "one column, History, no selection", columns: .one, preselected: nil,
                 clicked: .conversation(sessionID: "h2"), expectedSessionID: "h2", expectedEffects: [.focusList]),
            Case(name: "one column, Running, no selection", columns: .one, preselected: nil,
                 clicked: .running(target: "t2"), expectedSessionID: "s2", expectedEffects: [.focusList]),
            Case(name: "one column, another row selected", columns: .one, preselected: .conversation(sessionID: "h1"),
                 clicked: .conversation(sessionID: "h3"), expectedSessionID: "h3", expectedEffects: [.focusList]),
            Case(name: "two columns, History", columns: .two, preselected: nil,
                 clicked: .conversation(sessionID: "h2"), expectedSessionID: "h2",
                 expectedEffects: [.focusList, .loadConversation(sessionID: "h2")]),
            Case(name: "two columns, another row selected", columns: .two, preselected: .conversation(sessionID: "h1"),
                 clicked: .running(target: "t1"), expectedSessionID: "s1",
                 expectedEffects: [.focusList, .loadConversation(sessionID: "s1")]),
        ]
        for testCase in cases {
            var state = populated(columns: testCase.columns)
            if let preselected = testCase.preselected {
                state.handle(.rowClicked(preselected))
            }
            let effects = state.handle(.rowClicked(testCase.clicked))
            XCTAssertEqual(state.selection, RowSelection(key: testCase.clicked, sessionID: testCase.expectedSessionID), testCase.name)
            XCTAssertEqual(state.page, .list, "\(testCase.name): the list page stays")
            XCTAssertEqual(effects, testCase.expectedEffects, testCase.name)
            if testCase.columns == .one {
                XCTAssertEqual(state.paneContent, .hidden, testCase.name)
            }
        }
    }

    /// §4.5 "row click": clicking the selected row deselects it (no
    /// selection) and moves focus to the list. Two columns then show
    /// `No conversation selected`; one column stays on the list page.
    func testClickOnTheSelectedRowDeselects() {
        let cases: [(String, ColumnMode, UnifiedRowKey)] = [
            ("one column, History", .one, .conversation(sessionID: "h2")),
            ("one column, Running", .one, .running(target: "t1")),
            ("two columns, History", .two, .conversation(sessionID: "h2")),
            ("two columns, Running", .two, .running(target: "t1")),
        ]
        for (name, columns, key) in cases {
            var state = populated(columns: columns)
            state.handle(.rowClicked(key))
            XCTAssertNotNil(state.selection, name)
            let effects = state.handle(.rowClicked(key))
            XCTAssertNil(state.selection, name)
            XCTAssertEqual(effects, [.focusList], name)
            XCTAssertEqual(state.page, .list, name)
            XCTAssertNil(state.listBottomPanel?.buttons, "\(name): no buttons without a selection")
            XCTAssertEqual(state.paneContent, columns == .two ? .noSelection : .hidden, name)
            // A third click selects it again.
            state.handle(.rowClicked(key))
            XCTAssertEqual(state.selection?.key, key, name)
        }
    }

    /// §4.5 "row click": a click on the selected row deselects it only when
    /// the row was shown in accent; a gray selected row (the search field
    /// had focus, or the surface was not key) keeps its selection and the
    /// click moves focus to the list. The look that decides is the one at
    /// the press (`.pointerDown`), whatever AppKit changed before the row's
    /// click action ran; without a press snapshot the current look decides.
    /// With a press, the deselect waits for the double-click interval (§4.5
    /// "row double-click"); without one no second click can follow, so it
    /// deselects at once.
    func testClickOnTheSelectedRowFollowsTheLookAtThePress() {
        struct Case {
            let name: String
            /// The live state before the press.
            let surfaceKey: Bool
            let searchFieldFocused: Bool
            /// The press snapshot (nil: no `.pointerDown`).
            let press: (surfaceKey: Bool, searchFieldFocused: Bool)?
            /// What AppKit reports between the press and the click action
            /// (the window became key / the search field resigned).
            let afterPressSurfaceKey: Bool
            let afterPressSearchFieldFocused: Bool
            let expectDeselect: Bool
        }
        let cases = [
            Case(name: "accent at the press", surfaceKey: true, searchFieldFocused: false,
                 press: (true, false), afterPressSurfaceKey: true, afterPressSearchFieldFocused: false,
                 expectDeselect: true),
            Case(name: "search field focus at the press, resigned before the action", surfaceKey: true,
                 searchFieldFocused: true, press: (true, true),
                 afterPressSurfaceKey: true, afterPressSearchFieldFocused: false, expectDeselect: false),
            Case(name: "not key at the press, key before the action", surfaceKey: false, searchFieldFocused: false,
                 press: (false, false), afterPressSurfaceKey: true, afterPressSearchFieldFocused: false,
                 expectDeselect: false),
            Case(name: "not key and search field focus at the press", surfaceKey: false, searchFieldFocused: true,
                 press: (false, true), afterPressSurfaceKey: true, afterPressSearchFieldFocused: false,
                 expectDeselect: false),
            Case(name: "the activation made it key before the press was seen", surfaceKey: true,
                 searchFieldFocused: false, press: (false, false),
                 afterPressSurfaceKey: true, afterPressSearchFieldFocused: false, expectDeselect: false),
            Case(name: "no press snapshot, accent", surfaceKey: true, searchFieldFocused: false,
                 press: nil, afterPressSurfaceKey: true, afterPressSearchFieldFocused: false, expectDeselect: true),
            Case(name: "no press snapshot, gray (not key)", surfaceKey: false, searchFieldFocused: false,
                 press: nil, afterPressSurfaceKey: false, afterPressSearchFieldFocused: false, expectDeselect: false),
            Case(name: "no press snapshot, gray (search field)", surfaceKey: true, searchFieldFocused: true,
                 press: nil, afterPressSurfaceKey: true, afterPressSearchFieldFocused: true, expectDeselect: false),
        ]
        for columns in [ColumnMode.one, .two] {
            for testCase in cases {
                let name = "\(columns), \(testCase.name)"
                let key = UnifiedRowKey.conversation(sessionID: "h2")
                var state = populated(columns: columns)
                state.handle(.rowClicked(key))
                state.handle(.surfaceKeyChanged(testCase.surfaceKey))
                state.handle(.searchFieldFocusChanged(testCase.searchFieldFocused))
                if let press = testCase.press {
                    XCTAssertEqual(state.handle(.pointerDown(surfaceKey: press.surfaceKey,
                                                             searchFieldFocused: press.searchFieldFocused)), [], name)
                    XCTAssertEqual(state.selectionActiveAtPointerDown, press.surfaceKey && !press.searchFieldFocused, name)
                }
                state.handle(.surfaceKeyChanged(testCase.afterPressSurfaceKey))
                state.handle(.searchFieldFocusChanged(testCase.afterPressSearchFieldFocused))
                let effects = state.handle(.rowClicked(key))
                XCTAssertNil(state.selectionActiveAtPointerDown, "\(name): the snapshot is consumed")
                if testCase.expectDeselect, testCase.press != nil {
                    XCTAssertEqual(effects, [.scheduleDeferredDeselect(id: 1, pressedAt: nil), .focusList], name)
                    XCTAssertEqual(state.selection?.key, key, "\(name): kept until no double-click can follow")
                    XCTAssertEqual(state.handle(.deferredDeselectDue(id: 1)), [], name)
                } else {
                    XCTAssertEqual(effects, [.focusList], name)
                }
                if testCase.expectDeselect {
                    XCTAssertNil(state.selection, name)
                    XCTAssertEqual(state.paneContent, columns == .two ? .noSelection : .hidden, name)
                } else {
                    XCTAssertEqual(state.selection, RowSelection(key: key, sessionID: "h2"), name)
                    XCTAssertEqual(state.page, .list, name)
                }
            }
        }
    }

    /// A click on another row while the selection is gray selects it as
    /// usual (click-through on a window that is not key — §4.5).
    func testClickOnAnotherRowWhileGraySelects() {
        for columns in [ColumnMode.one, .two] {
            for selectFirst in [false, true] {
                let name = "\(columns), preselected: \(selectFirst)"
                var state = populated(columns: columns)
                if selectFirst { state.handle(.rowClicked(.conversation(sessionID: "h1"))) }
                state.handle(.surfaceKeyChanged(false))
                state.handle(.pointerDown(surfaceKey: false, searchFieldFocused: false))
                state.handle(.surfaceKeyChanged(true))
                let effects = state.handle(.rowClicked(.conversation(sessionID: "h3")))
                XCTAssertEqual(state.selection, RowSelection(key: .conversation(sessionID: "h3"), sessionID: "h3"), name)
                XCTAssertEqual(effects, columns == .two ? [.focusList, .loadConversation(sessionID: "h3")] : [.focusList], name)
                XCTAssertTrue(state.isSelectionActive, "\(name): key again, the card is accent")
            }
        }
    }

    /// The press snapshot belongs to the one click that follows: a later
    /// click without a new press decides from the current look.
    func testPressSnapshotIsUsedOnce() {
        var state = populated()
        let key = UnifiedRowKey.conversation(sessionID: "h1")
        state.handle(.rowClicked(key))
        state.handle(.pointerDown(surfaceKey: false, searchFieldFocused: false))
        state.handle(.rowClicked(key))
        XCTAssertEqual(state.selection?.key, key, "gray at the press: kept")
        state.handle(.rowClicked(key))
        XCTAssertNil(state.selection, "accent now, no new press: deselects")
        // A newer press replaces an unused one.
        state.handle(.rowClicked(key))
        state.handle(.pointerDown(surfaceKey: false, searchFieldFocused: false))
        state.handle(.pointerDown(surfaceKey: true, searchFieldFocused: false))
        XCTAssertEqual(state.handle(.rowClicked(key)), [.scheduleDeferredDeselect(id: 1, pressedAt: nil), .focusList])
        state.handle(.deferredDeselectDue(id: 1))
        XCTAssertNil(state.selection)
    }

    // MARK: - Double-click (§4.5 "row double-click")

    /// One mouse click as the app reports it: the press (with the system's
    /// click count and the live key status / focus), then the row's click
    /// action.
    @discardableResult
    private func click(
        _ state: inout UnifiedListState, _ key: UnifiedRowKey, count: Int = 1, pressedAt: TimeInterval? = nil,
        command: Bool = false
    ) -> [UnifiedListEffect] {
        state.handle(.pointerDown(surfaceKey: state.isSurfaceKey, searchFieldFocused: state.isSearchFieldFocused,
                                  clickCount: count, pressedAt: pressedAt, commandKey: command))
        return state.handle(.rowClicked(key))
    }

    /// How the clicked row looks at the first press.
    private enum RowLook: CaseIterable {
        case unselected
        case accent
        case graySearchField
        case grayNotKey
    }

    private func prepared(_ look: RowLook, columns: ColumnMode, key: UnifiedRowKey) -> UnifiedListState {
        var state = populated(columns: columns)
        switch look {
        case .unselected:
            state.handle(.rowClicked(.conversation(sessionID: "h3")))
        case .accent:
            state.handle(.rowClicked(key))
        case .graySearchField:
            state.handle(.rowClicked(key))
            state.handle(.searchFieldFocusChanged(true))
        case .grayNotKey:
            state.handle(.rowClicked(key))
            state.handle(.surfaceKeyChanged(false))
        }
        return state
    }

    /// §4.5 "row click" / "row double-click": unselected / accent / gray ×
    /// click / double-click, one column and two, Running (Jump) and History
    /// (Resume). A single click on an accent row deselects only once the
    /// double-click interval has passed; a double-click selects, focuses the
    /// list and runs the primary button whatever the row looked like, and
    /// never deselects.
    func testClickAndDoubleClickByRowLook() {
        let rows: [(UnifiedRowKey, String, RowInvocation)] = [
            (.running(target: "t2"), "s2", .jump(target: "t2")),
            (.conversation(sessionID: "h1"), "h1", .resume(sessionID: "h1", cwd: "/Users/example/demo/web")),
        ]
        for columns in [ColumnMode.one, .two] {
            for (key, sessionID, invocation) in rows {
                for look in RowLook.allCases {
                    let name = "\(columns), \(key), \(look)"
                    let load: [UnifiedListEffect] = columns == .two && look == .unselected
                        ? [.loadConversation(sessionID: sessionID)] : []

                    // Single click.
                    var single = prepared(look, columns: columns, key: key)
                    let clickEffects = click(&single, key, pressedAt: 50)
                    XCTAssertEqual(single.selection?.key, key, "\(name): the click keeps / makes the selection")
                    if look == .accent {
                        XCTAssertEqual(clickEffects, [.scheduleDeferredDeselect(id: 1, pressedAt: 50), .focusList], name)
                        XCTAssertEqual(single.pendingDeselect, PendingDeselect(id: 1, key: key), name)
                        XCTAssertEqual(single.handle(.deferredDeselectDue(id: 1)), [], name)
                        XCTAssertNil(single.selection, "\(name): no second click came, deselected")
                        XCTAssertNil(single.pendingDeselect, name)
                        XCTAssertEqual(single.paneContent, columns == .two ? .noSelection : .hidden, name)
                    } else {
                        XCTAssertEqual(clickEffects, [.focusList] + load, name)
                        XCTAssertNil(single.pendingDeselect, "\(name): nothing deferred")
                    }
                    XCTAssertEqual(single.page, .list, name)

                    // Double-click.
                    var double = prepared(look, columns: columns, key: key)
                    let first = click(&double, key, count: 1, pressedAt: 50)
                    // AppKit: the click's focus effect makes the surface
                    // key and the list focused before the second press.
                    double.handle(.surfaceKeyChanged(true))
                    double.handle(.searchFieldFocusChanged(false))
                    let second = click(&double, key, count: 2, pressedAt: 50.2)
                    XCTAssertEqual(first.contains(.focusList), true, name)
                    XCTAssertEqual(second, [.focusList, .invoke(invocation)], name)
                    XCTAssertEqual(double.selection?.key, key, "\(name): a double-click never deselects")
                    XCTAssertNil(double.pendingDeselect, "\(name): the first click's deselect is cancelled")
                    if look == .accent {
                        XCTAssertEqual(double.handle(.deferredDeselectDue(id: 1)), [], name)
                        XCTAssertEqual(double.selection?.key, key, "\(name): a late timer changes nothing")
                    }
                    XCTAssertEqual(double.page, .list, "\(name): a double-click never opens the detail page")
                }
            }
        }
    }

    /// §4.5 "row double-click": with the primary button disabled, a
    /// double-click only selects and focuses the list.
    func testDoubleClickWithTheButtonDisabledOnlySelects() {
        var state = populated()
        state.handle(.historyDelivered([UL.summary("x", cwd: nil)], isFiltered: false))
        let key = UnifiedRowKey.conversation(sessionID: "x")
        click(&state, key)
        XCTAssertEqual(state.selectedRow?.primaryButton.isEnabled, false)
        XCTAssertEqual(click(&state, key, count: 2), [.focusList])
        XCTAssertEqual(state.selection?.key, key)
    }

    // MARK: - Rows the app cannot jump to (§4.5 "row double-click", "key operations")

    /// Running t1 (s1), t2 (s2) and `process:48213` (sp, a session in a
    /// terminal the app can't drive); History h1 and the live conversation
    /// `live` (no daemon entry for its session_id).
    private func withRowsThatCannotJump(columns: ColumnMode) -> UnifiedListState {
        var state = UnifiedListState(home: UL.home, now: UL.now)
        state.handle(.columnsChanged(columns))
        state.handle(.agentsUpdated([
            UL.agent("process:48213", session: "sp", createdAt: 30),
            UL.agent("t1", session: "s1", createdAt: 20),
            UL.agent("t2", session: "s2", createdAt: 10),
        ]))
        state.handle(.historyDelivered(
            [UL.summary("s1", live: true), UL.summary("h1"), UL.summary("live", live: true)],
            isFiltered: false))
        return state
    }

    /// Enter with list focus, the way the app runs it: decide from the
    /// state's key context, then perform.
    @discardableResult
    private func pressEnter(_ state: inout UnifiedListState, command: Bool = false) -> [UnifiedListEffect]? {
        let context = state.keyContext(isPopover: false, hasMarkedText: false)
        guard case .perform(let keyCommand) = UnifiedListKeys.decide(
            key: .returnKey, modifiers: command ? [.command] : [], context: context) else { return nil }
        return state.perform(keyCommand)
    }

    /// §4.5 "row double-click" / "key operations": on a row whose primary is
    /// the disabled Jump (the Running row of a session the app cannot jump
    /// to, and a live conversation left in History), Enter and a
    /// double-click show the conversation instead — the one-column list page
    /// opens the detail page, two columns move focus to the conversation
    /// pane — and never run Jump.
    func testEnterAndDoubleClickShowTheConversationOfARowThatCannotJump() {
        let rows: [(UnifiedRowKey, String, RowInvocation)] = [
            (.running(target: "process:48213"), "sp",
             .branch(sessionID: "sp", cwd: "/Users/example/demo/api")),
            (.conversation(sessionID: "live"), "live",
             .branch(sessionID: "live", cwd: "/Users/example/demo/web")),
        ]
        for columns in [ColumnMode.one, .two] {
            for (key, sessionID, branch) in rows {
                let name = "\(columns), \(key)"
                let shown: [UnifiedListEffect] = columns == .one
                    ? [.loadConversation(sessionID: sessionID), .focusConversationPane]
                    : [.focusConversationPane]

                // Enter.
                var enter = withRowsThatCannotJump(columns: columns)
                click(&enter, key)
                XCTAssertEqual(enter.selectedRow?.primaryButton, .undrivableJump, name)
                XCTAssertTrue(enter.selectedRowShowsConversation, name)
                XCTAssertEqual(pressEnter(&enter), shown, name)
                XCTAssertEqual(enter.page, columns == .one ? .detail : .list, name)
                XCTAssertEqual(enter.selection?.key, key, name)

                // Double-click.
                var double = withRowsThatCannotJump(columns: columns)
                click(&double, key, count: 1, pressedAt: 50)
                double.handle(.surfaceKeyChanged(true))
                double.handle(.searchFieldFocusChanged(false))
                XCTAssertEqual(click(&double, key, count: 2, pressedAt: 50.2), [.focusList] + shown, name)
                XCTAssertEqual(double.page, columns == .one ? .detail : .list, name)
                XCTAssertEqual(double.selection?.key, key, "\(name): a double-click never deselects")
                XCTAssertNil(double.pendingDeselect, name)

                // A double-click on an unselected row selects it first.
                var fresh = withRowsThatCannotJump(columns: columns)
                click(&fresh, .conversation(sessionID: "h1"))
                click(&fresh, key, count: 1, pressedAt: 60)
                let second = click(&fresh, key, count: 2, pressedAt: 60.2)
                XCTAssertTrue(second.contains(.focusConversationPane), name)
                XCTAssertEqual(fresh.selection?.key, key, name)

                // ⌘Enter and ⌘ + double-click still run Branch.
                var commandEnter = withRowsThatCannotJump(columns: columns)
                click(&commandEnter, key)
                XCTAssertEqual(pressEnter(&commandEnter, command: true), [.invoke(branch)], name)
                XCTAssertEqual(commandEnter.page, .list, name)
                var commandDouble = withRowsThatCannotJump(columns: columns)
                click(&commandDouble, key, count: 1)
                XCTAssertEqual(click(&commandDouble, key, count: 2, command: true), [.focusList, .invoke(branch)], name)
                XCTAssertEqual(commandDouble.page, .list, name)
            }
        }
    }

    /// §4.5 "key operations": on the one-column detail page, Enter on a row
    /// the app cannot jump to does nothing (the conversation is already on
    /// screen); the key is still taken as the row's Enter.
    func testEnterOnTheDetailPageOfARowThatCannotJumpDoesNothing() {
        for key in [UnifiedRowKey.running(target: "process:48213"), .conversation(sessionID: "live")] {
            var state = withRowsThatCannotJump(columns: .one)
            click(&state, key)
            state.handle(.openDetail)
            XCTAssertEqual(state.page, .detail, "\(key)")
            XCTAssertEqual(state.keyContext(isPopover: false, hasMarkedText: false).primaryShowsConversation, true)
            XCTAssertEqual(pressEnter(&state), [], "\(key)")
            XCTAssertEqual(state.page, .detail, "\(key)")
            XCTAssertEqual(state.selection?.key, key, "\(key)")
        }
    }

    /// Rows with another primary button keep their Enter and double-click:
    /// an enabled Jump (iTerm2) jumps, and a disabled Resume (no cwd) only
    /// selects and focuses the list.
    func testOtherRowsKeepTheirEnterAndDoubleClick() {
        for columns in [ColumnMode.one, .two] {
            var jump = withRowsThatCannotJump(columns: columns)
            click(&jump, .running(target: "t2"))
            XCTAssertFalse(jump.selectedRowShowsConversation)
            XCTAssertEqual(pressEnter(&jump), [.invoke(.jump(target: "t2"))], "\(columns)")
            XCTAssertEqual(jump.page, .list, "\(columns)")

            var resume = withRowsThatCannotJump(columns: columns)
            resume.handle(.historyDelivered([UL.summary("x", cwd: nil)], isFiltered: false))
            let key = UnifiedRowKey.conversation(sessionID: "x")
            click(&resume, key)
            XCTAssertFalse(resume.selectedRowShowsConversation)
            XCTAssertNil(pressEnter(&resume), "\(columns): Enter on a disabled Resume is ignored")
            XCTAssertEqual(click(&resume, key, count: 2), [.focusList], "\(columns)")
            XCTAssertEqual(resume.page, .list, "\(columns)")
        }
    }

    /// Assumption (§4.5 "row selection"): while the selected Running row
    /// that ended awaits the History refetch, every button is disabled and
    /// Enter does not show the conversation either.
    func testARowAwaitingTheRefetchDoesNotShowTheConversation() {
        var state = withRowsThatCannotJump(columns: .one)
        click(&state, .running(target: "process:48213"))
        state.handle(.agentsUpdated([
            UL.agent("t1", session: "s1", createdAt: 20),
            UL.agent("t2", session: "s2", createdAt: 10),
        ]))
        XCTAssertTrue(state.isAwaitingRefetch)
        XCTAssertFalse(state.selectedRowShowsConversation)
        XCTAssertNil(pressEnter(&state))
        XCTAssertEqual(state.handle(.showConversation), [])
        XCTAssertEqual(state.page, .list)
    }

    /// §4.5 "row double-click": ⌘ held at the second press runs Branch
    /// instead of Jump / Resume (like ⌘Enter with list focus); ⌘ is judged at
    /// the second press only. With Branch disabled the double-click only
    /// selects and focuses the list, and a single ⌘-click is a plain click.
    func testCommandDoubleClickRunsBranch() {
        struct Case {
            let name: String
            let key: UnifiedRowKey
            let firstCommand: Bool
            let secondCommand: Bool
            let expectedInvocation: RowInvocation?
        }
        let resumeH1 = RowInvocation.resume(sessionID: "h1", cwd: "/Users/example/demo/web")
        let branchH1 = RowInvocation.branch(sessionID: "h1", cwd: "/Users/example/demo/web")
        let branchS2 = RowInvocation.branch(sessionID: "s2", cwd: "/Users/example/demo/api")
        let cases = [
            Case(name: "History, ⌘ at both presses", key: .conversation(sessionID: "h1"),
                 firstCommand: true, secondCommand: true, expectedInvocation: branchH1),
            Case(name: "History, ⌘ at the second press only", key: .conversation(sessionID: "h1"),
                 firstCommand: false, secondCommand: true, expectedInvocation: branchH1),
            Case(name: "History, ⌘ at the first press only", key: .conversation(sessionID: "h1"),
                 firstCommand: true, secondCommand: false, expectedInvocation: resumeH1),
            Case(name: "Running, ⌘", key: .running(target: "t2"),
                 firstCommand: false, secondCommand: true, expectedInvocation: branchS2),
            Case(name: "Running without a session_id: Branch disabled", key: .running(target: "t0"),
                 firstCommand: false, secondCommand: true, expectedInvocation: nil),
            Case(name: "History without a cwd: Branch disabled", key: .conversation(sessionID: "x"),
                 firstCommand: false, secondCommand: true, expectedInvocation: nil),
        ]
        for columns in [ColumnMode.one, .two] {
            for testCase in cases {
                let name = "\(columns), \(testCase.name)"
                var state = populated(columns: columns)
                state.handle(.agentsUpdated([
                    UL.agent("t0", status: .waiting, session: "", message: "Permission", createdAt: 5),
                    UL.agent("t1", session: "s1", createdAt: 20),
                    UL.agent("t2", session: "s2", createdAt: 10),
                ]))
                state.handle(.historyDelivered(
                    [UL.summary("h1"), UL.summary("h2"), UL.summary("x", cwd: nil)], isFiltered: false))
                let first = click(&state, testCase.key, count: 1, command: testCase.firstCommand)
                XCTAssertFalse(first.contains { if case .invoke = $0 { return true } else { return false } },
                               "\(name): a single ⌘-click runs nothing")
                let second = click(&state, testCase.key, count: 2, command: testCase.secondCommand)
                let invoked = second.compactMap { effect -> RowInvocation? in
                    if case .invoke(let invocation) = effect { return invocation } else { return nil }
                }
                XCTAssertEqual(invoked, testCase.expectedInvocation.map { [$0] } ?? [], name)
                XCTAssertTrue(second.contains(.focusList), name)
                XCTAssertEqual(state.selection?.key, testCase.key, "\(name): selected, never deselected")
                XCTAssertEqual(state.page, .list, name)
                // Further clicks of the sequence never run anything again.
                XCTAssertEqual(click(&state, testCase.key, count: 3, command: true), [.focusList], name)
            }
        }
    }

    /// §4.5 "row click": a single click with ⌘ held is the same as a plain
    /// click (it selects; on the accent row the deselect is deferred).
    func testCommandClickIsAPlainClick() {
        for columns in [ColumnMode.one, .two] {
            var plain = populated(columns: columns)
            var command = populated(columns: columns)
            let key = UnifiedRowKey.conversation(sessionID: "h2")
            XCTAssertEqual(click(&command, key, command: true), click(&plain, key), "\(columns)")
            XCTAssertEqual(command.selection, plain.selection, "\(columns)")
            // A second, separate single click on the accent row.
            XCTAssertEqual(click(&command, key, count: 1, command: true), click(&plain, key, count: 1), "\(columns)")
            XCTAssertEqual(command.pendingDeselect, plain.pendingDeselect, "\(columns)")
        }
    }

    /// §4.5 "row double-click": clicks 3+ of one sequence never run Jump /
    /// Resume again (nor deselect).
    func testTripleClickRunsTheActionOnce() {
        for columns in [ColumnMode.one, .two] {
            var state = populated(columns: columns)
            let key = UnifiedRowKey.conversation(sessionID: "h2")
            click(&state, key, count: 1)
            XCTAssertEqual(click(&state, key, count: 2).filter { if case .invoke = $0 { return true } else { return false } },
                           [.invoke(.resume(sessionID: "h2", cwd: "/Users/example/demo/web"))], "\(columns)")
            XCTAssertEqual(click(&state, key, count: 3), [.focusList], "\(columns)")
            XCTAssertEqual(click(&state, key, count: 4), [.focusList], "\(columns)")
            XCTAssertEqual(state.selection?.key, key, "\(columns)")
            XCTAssertNil(state.pendingDeselect, "\(columns)")
            // A new sequence: a single click on the accent row defers its
            // deselect again.
            XCTAssertEqual(click(&state, key, count: 1), [.scheduleDeferredDeselect(id: 1, pressedAt: nil), .focusList])
        }
    }

    /// A press the system counts as the second click but that lands on
    /// another row is a plain click on that row (no Jump / Resume); a
    /// second click on that row then is a double-click there.
    func testSecondClickOnAnotherRowIsAPlainClick() {
        for columns in [ColumnMode.one, .two] {
            var state = populated(columns: columns)
            click(&state, .conversation(sessionID: "h1"), count: 1)
            let onOther = click(&state, .conversation(sessionID: "h2"), count: 2)
            XCTAssertEqual(onOther, columns == .two ? [.focusList, .loadConversation(sessionID: "h2")] : [.focusList],
                           "\(columns)")
            XCTAssertEqual(state.selection?.key, .conversation(sessionID: "h2"), "\(columns)")
            XCTAssertEqual(click(&state, .conversation(sessionID: "h2"), count: 3),
                           [.focusList, .invoke(.resume(sessionID: "h2", cwd: "/Users/example/demo/web"))],
                           "\(columns): the next click on the same row completes a double-click there")
        }
        // The first click on an accent row, the second on another row: the
        // other row is selected and the pending deselect is gone.
        var state = populated()
        click(&state, .conversation(sessionID: "h1"))
        click(&state, .conversation(sessionID: "h1"), count: 1)
        XCTAssertNotNil(state.pendingDeselect)
        click(&state, .conversation(sessionID: "h3"), count: 2)
        XCTAssertNil(state.pendingDeselect)
        XCTAssertEqual(state.handle(.deferredDeselectDue(id: 1)), [])
        XCTAssertEqual(state.selection?.key, .conversation(sessionID: "h3"))
    }

    /// A press that reached no row (empty space, a button, the star) ends
    /// the click sequence: a following press with click count 2 on a row is
    /// a plain click.
    func testPressOutsideTheRowsBreaksTheSequence() {
        var state = populated()
        let key = UnifiedRowKey.conversation(sessionID: "h1")
        click(&state, key, count: 1)
        state.handle(.pointerDown(surfaceKey: true, searchFieldFocused: false, clickCount: 2, pressedAt: nil))
        // No row click for that press; the next press counts 3.
        XCTAssertEqual(click(&state, key, count: 3), [.scheduleDeferredDeselect(id: 1, pressedAt: nil), .focusList],
                       "a plain click on the accent row")
    }

    /// The pending deselect is cancelled by any other change of the
    /// selection or the page (↑ / ↓, the row leaving the list, → or View
    /// opening the detail page) and when the surface closes.
    func testPendingDeselectIsCancelledByOtherChanges() {
        let key = UnifiedRowKey.conversation(sessionID: "h2")
        let cancellers: [(String, UnifiedListEvent)] = [
            ("↓", .moveDown),
            ("↑", .moveUp),
            ("→ or View opens the detail page", .openDetail),
            ("the row leaves the list", .historyDelivered([UL.summary("h1")], isFiltered: true)),
            ("the surface closed", .surfaceHidden),
        ]
        for (name, event) in cancellers {
            var state = populated()
            click(&state, key)
            click(&state, key, count: 1)
            XCTAssertEqual(state.pendingDeselect, PendingDeselect(id: 1, key: key), name)
            state.handle(event)
            XCTAssertNil(state.pendingDeselect, name)
            let selectionBefore = state.selection
            let pageBefore = state.page
            XCTAssertEqual(state.handle(.deferredDeselectDue(id: 1)), [], name)
            XCTAssertEqual(state.selection, selectionBefore, "\(name): the late timer changes nothing")
            XCTAssertEqual(state.page, pageBefore, name)
        }
        // Changes that leave the selection and the page alone keep it.
        let keepers: [(String, UnifiedListEvent)] = [
            ("search field focus", .searchFieldFocusChanged(true)),
            ("key status", .surfaceKeyChanged(false)),
            ("clock", .clockTicked(now: UL.now + 1)),
            ("a press elsewhere", .pointerDown(surfaceKey: true, searchFieldFocused: false)),
        ]
        for (name, event) in keepers {
            var state = populated()
            click(&state, key)
            click(&state, key, count: 1)
            state.handle(event)
            XCTAssertNotNil(state.pendingDeselect, name)
            state.handle(.deferredDeselectDue(id: 1))
            XCTAssertNil(state.selection, name)
        }
    }

    /// An operation on the selected row that keeps it selected, within the
    /// double-click interval after the accent click, cancels the pending
    /// deselect: the row stays selected when the interval passes.
    func testPendingDeselectIsCancelledByAnOperationThatKeepsTheRowSelected() {
        struct Case {
            let name: String
            let key: UnifiedRowKey
            let operate: (inout UnifiedListState) -> [UnifiedListEffect]
        }
        let h2 = UnifiedRowKey.conversation(sessionID: "h2")
        let t2 = UnifiedRowKey.running(target: "t2")
        let cases: [Case] = [
            Case(name: "Enter runs the primary button (Resume)", key: h2, operate: { $0.perform(.primary) }),
            Case(name: "⌘Enter runs Branch", key: h2, operate: { $0.perform(.branch) }),
            Case(name: "Enter runs Jump", key: t2, operate: { $0.perform(.primary) }),
            Case(name: "the row's more button", key: h2, operate: { $0.handle(.moreButtonClicked(h2)) }),
            Case(name: "the row's star", key: h2, operate: { $0.handle(.starToggled(sessionID: "h2")) }),
        ]
        for testCase in cases {
            var state = populated()
            click(&state, testCase.key)
            click(&state, testCase.key, count: 1)
            XCTAssertEqual(state.pendingDeselect, PendingDeselect(id: 1, key: testCase.key), testCase.name)
            let effects = testCase.operate(&state)
            XCTAssertFalse(effects.isEmpty, "\(testCase.name): the operation ran")
            XCTAssertNil(state.pendingDeselect, testCase.name)
            state.handle(.deferredDeselectDue(id: 1))
            XCTAssertEqual(state.selection?.key, testCase.key, "\(testCase.name): stays selected")
        }

        // A disabled button runs nothing and leaves the pending deselect.
        var disabled = populated()
        disabled.handle(.agentsUpdated([UL.agent("t0", status: .waiting, session: "", message: "Permission")]))
        let t0 = UnifiedRowKey.running(target: "t0")
        click(&disabled, t0)
        click(&disabled, t0, count: 1)
        XCTAssertEqual(disabled.perform(.branch), [])
        XCTAssertNotNil(disabled.pendingDeselect)
    }

    /// A newer deferred deselect replaces an older one: only the newest
    /// timer acts.
    func testOnlyTheNewestDeferredDeselectActs() {
        var state = populated()
        let key = UnifiedRowKey.conversation(sessionID: "h1")
        click(&state, key)
        XCTAssertEqual(click(&state, key, count: 1).first, .scheduleDeferredDeselect(id: 1, pressedAt: nil))
        XCTAssertEqual(click(&state, key, count: 1).first, .scheduleDeferredDeselect(id: 2, pressedAt: nil))
        state.handle(.deferredDeselectDue(id: 1))
        XCTAssertEqual(state.selection?.key, key, "the older timer is stale")
        state.handle(.deferredDeselectDue(id: 2))
        XCTAssertNil(state.selection)
    }

    /// The `SurfaceKeyAtPress` decision: a key status gained at or after the
    /// press's own time was gained by that click.
    func testSurfaceKeyAtPress() {
        let cases: [(name: String, isKeyNow: Bool, becameKeyAt: TimeInterval?, pressedAt: TimeInterval, expected: Bool)] = [
            ("not key", false, nil, 100, false),
            ("not key, became key earlier", false, 50, 100, false),
            ("key since before the press", true, 99.5, 100, true),
            ("key, time unknown", true, nil, 100, true),
            ("became key at the press time", true, 100, 100, false),
            ("became key after the press (activation)", true, 100.02, 100, false),
        ]
        for testCase in cases {
            XCTAssertEqual(SurfaceKeyAtPress.wasKey(isKeyNow: testCase.isKeyNow, becameKeyAt: testCase.becameKeyAt,
                                                    pressedAt: testCase.pressedAt),
                           testCase.expected, testCase.name)
        }
    }

    /// §4.5 "opening the detail page", §4.6 "bottom panel": the View
    /// button's input is the same as → with list focus. Both open the
    /// selected row's detail page in one column (the focus moves to the
    /// conversation pane) and do nothing without a selection or in two
    /// columns.
    func testViewButtonActsLikeTheRightArrow() {
        struct Case {
            let name: String
            let columns: ColumnMode
            let selected: UnifiedRowKey?
            let expectedPage: ListPage
            let expectedEffects: [UnifiedListEffect]
        }
        let cases = [
            Case(name: "one column, a row selected", columns: .one, selected: .conversation(sessionID: "h2"),
                 expectedPage: .detail, expectedEffects: [.loadConversation(sessionID: "h2"), .focusConversationPane]),
            Case(name: "one column, a Running row selected", columns: .one, selected: .running(target: "t2"),
                 expectedPage: .detail, expectedEffects: [.loadConversation(sessionID: "s2"), .focusConversationPane]),
            Case(name: "one column, empty session_id", columns: .one, selected: .running(target: "t0"),
                 expectedPage: .detail, expectedEffects: [.focusConversationPane]),
            Case(name: "one column, no selection", columns: .one, selected: nil,
                 expectedPage: .list, expectedEffects: []),
            Case(name: "two columns, a row selected", columns: .two, selected: .conversation(sessionID: "h2"),
                 expectedPage: .list, expectedEffects: []),
        ]
        for testCase in cases {
            var base = populated(columns: testCase.columns)
            base.handle(.agentsUpdated([
                UL.agent("t0", status: .waiting, session: "", message: "Permission", createdAt: 5),
                UL.agent("t1", session: "s1", createdAt: 20),
                UL.agent("t2", session: "s2", createdAt: 10),
            ]))
            if let selected = testCase.selected {
                base.handle(.rowClicked(selected))
            }
            let selectionBefore = base.selection

            var viaView = base
            let viewEffects = viaView.handle(.openDetail)
            XCTAssertEqual(viaView.page, testCase.expectedPage, testCase.name)
            XCTAssertEqual(viaView.selection, selectionBefore, "\(testCase.name): the selection stays")
            XCTAssertEqual(viewEffects, testCase.expectedEffects, testCase.name)

            var viaKey = base
            let keyEffects: [UnifiedListEffect]
            switch UnifiedListKeys.decide(key: .rightArrow, modifiers: [],
                                          context: viaKey.keyContext(isPopover: false, hasMarkedText: false)) {
            case .perform(let command): keyEffects = viaKey.perform(command)
            default: keyEffects = []
            }
            XCTAssertEqual(viaKey, viaView, "\(testCase.name): → leaves the same state")
            XCTAssertEqual(keyEffects, viewEffects, "\(testCase.name): → runs the same effects")
        }
    }

    func testRowClickTwoColumnsShowsTheConversation() {
        var state = populated(columns: .two)
        let effects = state.handle(.rowClicked(.running(target: "t2")))
        XCTAssertEqual(state.selection?.key, .running(target: "t2"))
        XCTAssertEqual(state.page, .list)
        XCTAssertEqual(effects, [.focusList, .loadConversation(sessionID: "s2")])
        // Re-clicking the shown conversation deselects it (nothing to load).
        XCTAssertEqual(state.handle(.rowClicked(.running(target: "t2"))), [.focusList])
        XCTAssertEqual(state.paneContent, .noSelection)
    }

    func testRowClickOnUnknownKeyIsIgnored() {
        var state = populated()
        XCTAssertEqual(state.handle(.rowClicked(.conversation(sessionID: "nope"))), [])
        XCTAssertNil(state.selection)
    }

    /// §4.5 "row click": a row with an empty session_id is selected like
    /// any other row (nothing to load).
    func testRowClickSelectsARowWithoutSessionID() {
        var state = UnifiedListState(home: UL.home, now: UL.now)
        state.handle(.agentsUpdated([UL.agent("t", status: .waiting, session: "", message: "Permission")]))
        XCTAssertEqual(state.handle(.rowClicked(.running(target: "t"))), [.focusList])
        XCTAssertEqual(state.selection, RowSelection(key: .running(target: "t"), sessionID: ""))
        XCTAssertEqual(state.page, .list)
        XCTAssertEqual(state.listBottomPanel?.buttons?.branch.isEnabled, false)
        XCTAssertEqual(state.listBottomPanel?.buttons?.primary.isEnabled, true)
    }

    // MARK: - Keys: → / ←, Enter from the search field, key hints

    /// → opens the detail page (one-column list page, with a selection);
    /// ← goes back (one-column detail page). Two columns: nothing.
    func testOpenDetailAndBackInOneColumnOnly() {
        var state = populated()
        XCTAssertEqual(state.handle(.openDetail), [], "no selection: nothing")
        XCTAssertEqual(state.page, .list)
        state.handle(.moveDown)
        XCTAssertEqual(state.handle(.openDetail), [.loadConversation(sessionID: "s1"), .focusConversationPane])
        XCTAssertEqual(state.page, .detail)
        XCTAssertEqual(state.handle(.openDetail), [], "already on the detail page")
        XCTAssertEqual(state.handle(.back), [.scrollSelectionIntoView, .focusList])
        XCTAssertEqual(state.page, .list)
        XCTAssertEqual(state.handle(.back), [], "already on the list page")

        var two = populated(columns: .two)
        two.handle(.moveDown)
        XCTAssertEqual(two.handle(.openDetail), [])
        XCTAssertEqual(two.handle(.back), [])
        XCTAssertEqual(two.page, .list)
    }

    /// §4.5: Enter in the search field moves focus to the list; with no
    /// selection it selects the first row (no rows: nothing).
    func testEnterFromSearchField() {
        struct Case {
            let name: String
            let columns: ColumnMode
            let preselected: UnifiedRowKey?
            let empty: Bool
            let expectedSelection: UnifiedRowKey?
            let expectedEffects: [UnifiedListEffect]
        }
        let cases = [
            Case(name: "one column, no selection", columns: .one, preselected: nil, empty: false,
                 expectedSelection: .running(target: "t1"), expectedEffects: [.focusList, .scrollSelectionIntoView]),
            Case(name: "one column, a selection", columns: .one, preselected: .conversation(sessionID: "h2"), empty: false,
                 expectedSelection: .conversation(sessionID: "h2"), expectedEffects: [.focusList]),
            Case(name: "one column, no rows", columns: .one, preselected: nil, empty: true,
                 expectedSelection: nil, expectedEffects: []),
            Case(name: "two columns, no selection", columns: .two, preselected: nil, empty: false,
                 expectedSelection: .running(target: "t1"),
                 expectedEffects: [.focusList, .loadConversation(sessionID: "s1"), .scrollSelectionIntoView]),
            Case(name: "two columns, a selection", columns: .two, preselected: .conversation(sessionID: "h2"), empty: false,
                 expectedSelection: .conversation(sessionID: "h2"), expectedEffects: [.focusList]),
            Case(name: "two columns, no rows", columns: .two, preselected: nil, empty: true,
                 expectedSelection: nil, expectedEffects: []),
        ]
        for testCase in cases {
            var state = testCase.empty ? UnifiedListState(home: UL.home, now: UL.now) : populated(columns: testCase.columns)
            state.handle(.columnsChanged(testCase.columns))
            if let preselected = testCase.preselected {
                state.handle(.rowClicked(preselected))
            }
            state.handle(.searchFieldFocusChanged(true))
            let effects = state.perform(.enterFromSearchField)
            XCTAssertEqual(state.selection?.key, testCase.expectedSelection, testCase.name)
            XCTAssertEqual(effects, testCase.expectedEffects, testCase.name)
            XCTAssertEqual(state.page, .list, "\(testCase.name): never opens the detail page")
        }
    }

    /// §4.5 "global hotkey" / §8.66: opened (or raised) by the hotkey, the
    /// list takes focus and the selection does not change (no selection
    /// stays none); no rows: the search field. The one-column detail page
    /// stays and the conversation pane takes focus.
    func testOpenedByHotKeyFocusRule() {
        struct Case {
            let name: String
            let columns: ColumnMode
            let preselected: UnifiedRowKey?
            let detailPage: Bool
            let empty: Bool
            let expectedSelection: UnifiedRowKey?
            let expectedPage: ListPage
            let expectedEffects: [UnifiedListEffect]
        }
        let cases = [
            Case(name: "one column, a selection", columns: .one, preselected: .conversation(sessionID: "h2"),
                 detailPage: false, empty: false,
                 expectedSelection: .conversation(sessionID: "h2"), expectedPage: .list, expectedEffects: [.focusList]),
            Case(name: "one column, no selection", columns: .one, preselected: nil,
                 detailPage: false, empty: false,
                 expectedSelection: nil, expectedPage: .list, expectedEffects: [.focusList]),
            Case(name: "one column, no rows", columns: .one, preselected: nil,
                 detailPage: false, empty: true,
                 expectedSelection: nil, expectedPage: .list, expectedEffects: [.focusSearchField]),
            Case(name: "one column, detail page", columns: .one, preselected: .conversation(sessionID: "h2"),
                 detailPage: true, empty: false,
                 expectedSelection: .conversation(sessionID: "h2"), expectedPage: .detail,
                 expectedEffects: [.focusConversationPane]),
            Case(name: "two columns, a selection", columns: .two, preselected: .conversation(sessionID: "h2"),
                 detailPage: false, empty: false,
                 expectedSelection: .conversation(sessionID: "h2"), expectedPage: .list, expectedEffects: [.focusList]),
            Case(name: "two columns, no selection", columns: .two, preselected: nil,
                 detailPage: false, empty: false,
                 expectedSelection: nil, expectedPage: .list, expectedEffects: [.focusList]),
            Case(name: "two columns, no rows", columns: .two, preselected: nil,
                 detailPage: false, empty: true,
                 expectedSelection: nil, expectedPage: .list, expectedEffects: [.focusSearchField]),
        ]
        for testCase in cases {
            var state = testCase.empty ? UnifiedListState(home: UL.home, now: UL.now) : populated(columns: testCase.columns)
            state.handle(.columnsChanged(testCase.columns))
            if let preselected = testCase.preselected {
                if testCase.detailPage {
                    state.openDetailPage(preselected)
                } else {
                    state.handle(.rowClicked(preselected))
                }
            }
            // The tray click's open focused the search field before.
            state.handle(.searchFieldFocusChanged(!testCase.detailPage))
            let effects = state.handle(.openedByHotKey)
            XCTAssertEqual(state.selection?.key, testCase.expectedSelection, testCase.name)
            XCTAssertEqual(state.page, testCase.expectedPage, testCase.name)
            XCTAssertEqual(effects, testCase.expectedEffects, testCase.name)
        }
    }

    /// While a just-ended Running row awaits the refetch the selection
    /// stays (not listed): Enter in the search field only moves focus.
    func testEnterFromSearchFieldWhileAwaitingKeepsTheSelection() {
        var state = populated()
        state.handle(.rowClicked(.running(target: "t2")))
        state.handle(.agentsUpdated([UL.agent("t1", session: "s1", createdAt: 20)]))
        XCTAssertTrue(state.isAwaitingRefetch)
        XCTAssertEqual(state.perform(.enterFromSearchField), [.focusList])
        XCTAssertEqual(state.selection?.key, .running(target: "t2"))
    }

    /// §4.5 "key hints": `↩ List` alone while the search field has focus,
    /// `↑↓ Move` alone with list focus (→ is shown in the View button).
    /// §4.6 "bottom panel": the buttons are shown only while a row is
    /// selected and the search field does not have focus, in one column and
    /// in two (the panel keeps its height — the view draws placeholders).
    /// The one-column list page's panel orders View, Branch, the primary
    /// button; the conversation pane's panel (detail page, right column) has
    /// no View.
    func testHintsAndBottomPanelButtonsFollowFocus() {
        struct Case {
            let name: String
            let columns: ColumnMode
            let select: Bool
            let searchFieldFocused: Bool
            let expected: [KeyHint]
        }
        let cases = [
            Case(name: "one column, no selection, list focus", columns: .one, select: false, searchFieldFocused: false,
                 expected: [.move]),
            Case(name: "one column, no selection, search field", columns: .one, select: false, searchFieldFocused: true,
                 expected: [.list]),
            Case(name: "one column, selection, list focus", columns: .one, select: true, searchFieldFocused: false,
                 expected: [.move]),
            Case(name: "one column, selection, search field", columns: .one, select: true, searchFieldFocused: true,
                 expected: [.list]),
            Case(name: "two columns, selection, list focus", columns: .two, select: true, searchFieldFocused: false,
                 expected: [.move]),
            Case(name: "two columns, no selection, search field", columns: .two, select: false, searchFieldFocused: true,
                 expected: [.list]),
            Case(name: "two columns, selection, search field", columns: .two, select: true, searchFieldFocused: true,
                 expected: [.list]),
            Case(name: "two columns, no selection, list focus", columns: .two, select: false, searchFieldFocused: false,
                 expected: [.move]),
        ]
        for testCase in cases {
            var state = populated(columns: testCase.columns)
            if testCase.select {
                state.handle(.rowClicked(.conversation(sessionID: "h1")))
            }
            XCTAssertEqual(state.handle(.searchFieldFocusChanged(testCase.searchFieldFocused)), [], testCase.name)
            XCTAssertEqual(state.isSearchFieldFocused, testCase.searchFieldFocused, testCase.name)
            XCTAssertEqual(state.footerHints, testCase.expected, testCase.name)
            let showsButtons = testCase.select && !testCase.searchFieldFocused
            if testCase.columns == .one {
                XCTAssertEqual(state.listBottomPanel?.hints, testCase.expected, testCase.name)
                XCTAssertEqual(state.listBottomPanel?.buttons != nil, showsButtons, testCase.name)
                XCTAssertEqual(state.listBottomPanel?.slots, [.view, .branch, .primary], testCase.name)
            } else if testCase.select {
                // The right column's panel: no hints, buttons by focus.
                guard case .conversation(let pane) = state.paneContent else { return XCTFail("expected a pane") }
                XCTAssertEqual(pane.bottomPanel.hints, [], testCase.name)
                XCTAssertEqual(pane.bottomPanel.buttons != nil, showsButtons, testCase.name)
                XCTAssertEqual(pane.bottomPanel.slots, [.branch, .primary], "\(testCase.name): no View")
                XCTAssertNil(state.listBottomPanel, testCase.name)
            } else {
                XCTAssertEqual(state.paneContent, .noSelection, testCase.name)
            }
            // The focus report changes no selection and no page.
            XCTAssertEqual(state.selection?.key, testCase.select ? .conversation(sessionID: "h1") : nil, testCase.name)
            XCTAssertEqual(state.page, .list, testCase.name)
        }
        // The detail page's hints do not depend on focus.
        var detail = populated()
        detail.openDetailPage(.conversation(sessionID: "h1"))
        for focused in [false, true] {
            detail.handle(.searchFieldFocusChanged(focused))
            guard case .conversation(let pane) = detail.paneContent else { return XCTFail("expected a pane") }
            XCTAssertEqual(pane.hints, [.prevNext, .back])
            XCTAssertEqual(pane.bottomPanel.slots, [.branch, .primary], "the detail page has no View")
        }
    }

    func testRowWithoutSessionIDOpensButLoadsNothing() {
        var state = UnifiedListState(home: UL.home, now: UL.now)
        state.handle(.agentsUpdated([UL.agent(
            "t", status: .waiting, session: "", cwd: "/Users/example/work/demo/api", message: "Permission")]))
        let effects = state.openDetailPage(.running(target: "t"))
        XCTAssertEqual(effects, [.focusList, .focusConversationPane], "nothing to load")
        XCTAssertEqual(state.page, .detail)
        guard case .conversation(let pane) = state.paneContent else { return XCTFail("expected a pane") }
        XCTAssertFalse(pane.showsMessages)
        XCTAssertEqual(pane.title, "Permission")
        // §4.6 / §4.5 "row click": line 1 is the row's label, line 2 the
        // row's title text.
        XCTAssertEqual(pane.labelAndElapsed, "demo/api \u{00B7} 4m ago")
        XCTAssertEqual(pane.branchButton.isEnabled, false)
        XCTAssertEqual(pane.primaryButton.isEnabled, true)
    }

    // MARK: - Search changes

    func testSearchKeepsTheSelectionWhileItIsInTheResults() {
        var state = populated()
        state.openDetailPage(.conversation(sessionID: "h2"))
        let effects = state.handle(.historyDelivered([UL.summary("h2"), UL.summary("h3")], isFiltered: true))
        XCTAssertEqual(state.selection?.key, .conversation(sessionID: "h2"))
        XCTAssertEqual(state.page, .detail)
        XCTAssertEqual(effects, [], "the pane is not reloaded")
    }

    func testSearchDropsTheSelectionWhenItLeavesTheResults() {
        var state = populated()
        state.openDetailPage(.conversation(sessionID: "h2"))
        let effects = state.handle(.historyDelivered([UL.summary("h3")], isFiltered: true))
        XCTAssertNil(state.selection)
        XCTAssertEqual(state.page, .list, "the detail page returns to the list")
        XCTAssertEqual(effects, [.focusList], "back on the list page, the focus is the list")
        XCTAssertEqual(state.footerHints, [.move])
    }

    func testSearchDropsASelectedRunningRowNotInTheResults() {
        var state = populated(columns: .two)
        state.handle(.rowClicked(.running(target: "t1")))
        state.handle(.historyDelivered([UL.summary("s2")], isFiltered: true))
        XCTAssertNil(state.selection)
        XCTAssertEqual(state.paneContent, .noSelection)
    }

    func testRefetchThatDropsTheShownConversationReturnsToList() {
        var state = populated()
        state.openDetailPage(.conversation(sessionID: "h3"))
        state.handle(.historyDelivered([UL.summary("h1"), UL.summary("h2")], isFiltered: false))
        XCTAssertNil(state.selection)
        XCTAssertEqual(state.page, .list)
        XCTAssertEqual(state.paneContent, .hidden)
    }

    func testFullBuildHidesHistoryAndDropsAHistorySelection() {
        var state = populated(columns: .two)
        state.handle(.rowClicked(.conversation(sessionID: "h1")))
        state.handle(.fullBuildChanged(true))
        XCTAssertEqual(state.recentRows, [])
        XCTAssertEqual(state.runningRows.count, 2, "Running does not wait for the index")
        XCTAssertNil(state.selection)
    }

    // MARK: - A selected Running row ends (§4.5)

    func testEndedRunningRowCarriesOverToHistory() {
        var state = populated()
        state.openDetailPage(.running(target: "t2"))
        XCTAssertEqual(state.page, .detail)

        let removal = state.handle(.agentsUpdated([UL.agent("t1", session: "s1", createdAt: 20)]))
        XCTAssertEqual(removal, UL.endedRowRefetches)
        XCTAssertTrue(state.isAwaitingRefetch)
        XCTAssertEqual(state.selection?.key, .running(target: "t2"), "unchanged until the refetch completes")
        XCTAssertEqual(state.page, .detail)
        guard case .conversation(let pane) = state.paneContent else { return XCTFail("expected a pane") }
        XCTAssertNil(pane.positionText, "no position while awaiting")
        XCTAssertFalse(pane.primaryButton.isEnabled)
        XCTAssertFalse(pane.branchButton.isEnabled)
        XCTAssertFalse(pane.canGoPrevious)
        XCTAssertFalse(pane.canGoNext)
        XCTAssertEqual(state.perform(.primary), [])
        XCTAssertEqual(state.handle(.moveDown), [], "arrows wait for the refetch (assumption)")

        let delivered = state.handle(.historyDelivered(
            [UL.summary("s2", cwd: "/Users/example/demo/api"), UL.summary("s1", live: true), UL.summary("h1")],
            isFiltered: false))
        XCTAssertFalse(state.isAwaitingRefetch)
        XCTAssertEqual(state.selection, RowSelection(key: .conversation(sessionID: "s2"), sessionID: "s2"))
        XCTAssertEqual(state.page, .detail)
        XCTAssertEqual(delivered, [], "same conversation: the pane is not reloaded")
        guard case .conversation(let after) = state.paneContent else { return XCTFail("expected a pane") }
        XCTAssertEqual(after.positionText, "2 / 3")
        XCTAssertEqual(after.primaryButton.kind, .resume)
        XCTAssertTrue(after.primaryButton.isEnabled)
    }

    func testEndedRunningRowWithoutHistoryMatchDeselects() {
        var state = populated()
        state.openDetailPage(.running(target: "t2"))
        state.handle(.agentsUpdated([UL.agent("t1", session: "s1", createdAt: 20)]))
        state.handle(.historyDelivered([UL.summary("h1")], isFiltered: false))
        XCTAssertNil(state.selection)
        XCTAssertEqual(state.page, .list)
        XCTAssertFalse(state.isAwaitingRefetch)
    }

    func testEndedRunningRowWithFailedRefetchDeselects() {
        var state = populated(columns: .two)
        state.handle(.rowClicked(.running(target: "t2")))
        state.handle(.agentsUpdated([UL.agent("t1", session: "s1", createdAt: 20)]))
        XCTAssertTrue(state.isAwaitingRefetch)
        state.handle(.historyFetchFailed)
        XCTAssertNil(state.selection)
        XCTAssertEqual(state.paneContent, .noSelection)
    }

    func testFailedFetchWithoutPendingKeepsEverything() {
        var state = populated()
        state.handle(.rowClicked(.conversation(sessionID: "h1")))
        let before = state
        XCTAssertEqual(state.handle(.historyFetchFailed), [])
        XCTAssertEqual(state, before)
    }

    func testEndedRunningRowWithoutSessionIDDeselectsAtOnce() {
        var state = UnifiedListState(home: UL.home, now: UL.now)
        state.handle(.agentsUpdated([UL.agent("t", session: "")]))
        state.handle(.rowClicked(.running(target: "t")))
        let effects = state.handle(.agentsUpdated([]))
        XCTAssertEqual(effects, UL.endedRowRefetches)
        XCTAssertNil(state.selection)
        XCTAssertFalse(state.isAwaitingRefetch)
    }

    func testRemovalOfAnUnselectedRowRefetchesWithoutTouchingTheSelection() {
        var state = populated()
        state.handle(.rowClicked(.conversation(sessionID: "h1")))
        let effects = state.handle(.agentsUpdated([UL.agent("t2", session: "s2", createdAt: 10)]))
        XCTAssertEqual(effects, UL.endedRowRefetches)
        XCTAssertEqual(state.selection?.key, .conversation(sessionID: "h1"))
        XCTAssertFalse(state.isAwaitingRefetch)
    }

    func testStatusChangeDoesNotRefetchOrMove() {
        var state = populated()
        state.handle(.rowClicked(.running(target: "t1")))
        let effects = state.handle(.agentsUpdated([
            UL.agent("t1", status: .working, session: "s1", createdAt: 20),
            UL.agent("t2", session: "s2", createdAt: 10),
        ]))
        XCTAssertEqual(effects, [])
        XCTAssertEqual(state.selection?.key, .running(target: "t1"))
        XCTAssertEqual(state.runningRows.map(\.id), [.running(target: "t1"), .running(target: "t2")])
    }

    /// §4.5: a selected History row whose conversation moves to Running
    /// (after Resume, for example) keeps the selection and the shown page,
    /// matched by session_id; the pane is not reloaded.
    func testHistoryRowMovingToRunningKeepsSelectionAndPage() {
        struct Case {
            let name: String
            let columns: ColumnMode
            /// Open the detail page (one column) before the move.
            let openDetail: Bool
            /// Deliver a filtered result containing h1 before the move.
            let filtered: Bool
            let expectedPage: ListPage
        }
        let cases = [
            Case(name: "one column, detail page", columns: .one, openDetail: true, filtered: false, expectedPage: .detail),
            Case(name: "one column, list page", columns: .one, openDetail: false, filtered: false, expectedPage: .list),
            Case(name: "two columns", columns: .two, openDetail: false, filtered: false, expectedPage: .list),
            Case(name: "one column, detail page, searching", columns: .one, openDetail: true, filtered: true, expectedPage: .detail),
        ]
        for testCase in cases {
            var state = populated(columns: testCase.columns)
            if testCase.filtered {
                state.handle(.historyDelivered([UL.summary("s1", live: true), UL.summary("h1")], isFiltered: true))
            }
            let key = UnifiedRowKey.conversation(sessionID: "h1")
            if testCase.openDetail {
                state.openDetailPage(key)
            } else {
                state.handle(.rowClicked(key))
            }
            let effects = state.handle(.agentsUpdated([
                UL.agent("t1", session: "s1", createdAt: 20),
                UL.agent("t2", session: "s2", createdAt: 10),
                UL.agent("t9", session: "h1", createdAt: 30),
            ]))
            XCTAssertEqual(state.selection, RowSelection(key: .running(target: "t9"), sessionID: "h1"), testCase.name)
            XCTAssertEqual(state.page, testCase.expectedPage, testCase.name)
            XCTAssertEqual(effects, [], "\(testCase.name): same conversation, no reload")
            XCTAssertFalse(state.recentRows.contains { $0.sessionID == "h1" }, testCase.name)
            XCTAssertEqual(state.selectedRow?.primaryButton.kind, .jump, testCase.name)
            XCTAssertEqual(state.footerHints, [.move], testCase.name)
        }
    }

    /// The carry-over needs a Running row: an agent with an unknown status
    /// produces none, so the History row stays (and stays selected).
    func testHistoryRowWithUnknownStatusAgentStaysSelected() {
        var state = populated()
        state.openDetailPage(.conversation(sessionID: "h1"))
        state.handle(.agentsUpdated([
            UL.agent("t1", session: "s1", createdAt: 20),
            UL.agent("t2", session: "s2", createdAt: 10),
            UL.agent("t9", status: .unknown, session: "h1", createdAt: 30),
        ]))
        XCTAssertEqual(state.selection?.key, .conversation(sessionID: "h1"))
        XCTAssertEqual(state.page, .detail)
    }

    // MARK: - Width changes (§4.5)

    func testWideningFromTheDetailPageKeepsTheConversation() {
        var state = populated()
        state.openDetailPage(.conversation(sessionID: "h3"))
        let effects = state.handle(.columnsChanged(.two))
        XCTAssertEqual(state.columns, .two)
        XCTAssertEqual(state.page, .list)
        XCTAssertEqual(state.selection?.key, .conversation(sessionID: "h3"))
        XCTAssertEqual(effects, [.scrollSelectionIntoView], "no reload; the list reappears")
        guard case .conversation(let pane) = state.paneContent else { return XCTFail("expected a pane") }
        XCTAssertNil(pane.positionText)
        XCTAssertFalse(pane.showsBackButton)
        XCTAssertEqual(pane.hints, [])
    }

    func testNarrowingShowsTheListPageAndKeepsTheSelection() {
        var state = populated(columns: .two)
        state.handle(.rowClicked(.conversation(sessionID: "h2")))
        let effects = state.handle(.columnsChanged(.one))
        XCTAssertEqual(state.page, .list)
        XCTAssertEqual(state.selection?.key, .conversation(sessionID: "h2"))
        XCTAssertEqual(effects, [])
        XCTAssertEqual(state.paneContent, .hidden)
        // Opening the detail page again loads the conversation.
        XCTAssertEqual(state.handle(.openDetail), [.loadConversation(sessionID: "h2"), .focusConversationPane])
    }

    func testSameColumnModeIsANoOp() {
        var state = populated()
        state.openDetailPage(.conversation(sessionID: "h1"))
        XCTAssertEqual(state.handle(.columnsChanged(.one)), [])
        XCTAssertEqual(state.page, .detail, "popover reopening keeps the detail page")
    }

    // MARK: - Detail pane model

    func testDetailPaneModelInOneColumn() {
        var state = populated()
        state.openDetailPage(.running(target: "t1"))
        guard case .conversation(let first) = state.paneContent else { return XCTFail("expected a pane") }
        XCTAssertEqual(first.positionText, "1 / 5")
        XCTAssertFalse(first.canGoPrevious)
        XCTAssertTrue(first.canGoNext)
        XCTAssertTrue(first.showsBackButton)
        XCTAssertTrue(first.showsButtons)
        XCTAssertEqual(first.hints, [.prevNext, .back])
        XCTAssertEqual(first.primaryButton.kind, .jump)
        state.openDetailPage(.conversation(sessionID: "h3"))
        guard case .conversation(let last) = state.paneContent else { return XCTFail("expected a pane") }
        XCTAssertEqual(last.positionText, "5 / 5")
        XCTAssertTrue(last.canGoPrevious)
        XCTAssertFalse(last.canGoNext)
    }

    /// §4.6 "hit navigation": the one-column detail page's find bar reads
    /// `Matches for “tag”` (the query trimmed, in typographic quotes).
    func testFindBarQueryText() {
        XCTAssertEqual(FindBarQueryText.prefix, "Matches for")
        XCTAssertEqual(FindBarQueryText.quotedTerm("tag"), "\u{201C}tag\u{201D}")
        XCTAssertEqual(FindBarQueryText.quotedTerm("  tag search \n"), "\u{201C}tag search\u{201D}")
    }

    // MARK: - Bottom panel (§4.6 "bottom panel", §4.5 "fixed footer")

    /// The one-column list page's bottom panel: the list's key hints on the
    /// left, the selected row's buttons on the right, none while nothing is
    /// selected. Two columns have no list-page panel (the left column shows
    /// the key hints only; the buttons are in the right column's pane).
    func testListPageBottomPanel() {
        let resumeH1 = RowButton(kind: .resume, invocation: .resume(sessionID: "h1", cwd: "/Users/example/demo/web"), tooltip: "Resume")
        let branchH1 = RowButton(kind: .branch, invocation: .branch(sessionID: "h1", cwd: "/Users/example/demo/web"), tooltip: "Branch")
        let jumpT2 = RowButton(kind: .jump, invocation: .jump(target: "t2"), tooltip: "Jump")
        let branchS2 = RowButton(kind: .branch, invocation: .branch(sessionID: "s2", cwd: "/Users/example/demo/api"), tooltip: "Branch")
        let liveJump = RowButton(kind: .jump, invocation: nil, tooltip: RowButton.untrackedRunningTooltip)
        let branchLive = RowButton(kind: .branch, invocation: .branch(sessionID: "live", cwd: "/Users/example/demo/web"), tooltip: "Branch")
        struct Case {
            let name: String
            let columns: ColumnMode
            let selected: UnifiedRowKey?
            /// End the selected Running row t2 (awaiting the refetch).
            let endSelectedRunningRow: Bool
            let expected: BottomPanelModel?
        }
        let cases = [
            Case(name: "one column, no selection", columns: .one, selected: nil, endSelectedRunningRow: false,
                 expected: BottomPanelModel(hints: [.move], buttons: nil, showsViewButton: true)),
            Case(name: "one column, Running row", columns: .one, selected: .running(target: "t2"), endSelectedRunningRow: false,
                 expected: BottomPanelModel(hints: [.move],
                                            buttons: BottomPanelButtons(primary: jumpT2, branch: branchS2),
                                            showsViewButton: true)),
            Case(name: "one column, History row", columns: .one, selected: .conversation(sessionID: "h1"), endSelectedRunningRow: false,
                 expected: BottomPanelModel(hints: [.move],
                                            buttons: BottomPanelButtons(primary: resumeH1, branch: branchH1),
                                            showsViewButton: true)),
            Case(name: "one column, disabled primary (live in History)", columns: .one, selected: .conversation(sessionID: "live"),
                 endSelectedRunningRow: false,
                 expected: BottomPanelModel(hints: [.move],
                                            buttons: BottomPanelButtons(primary: liveJump, branch: branchLive),
                                            showsViewButton: true)),
            Case(name: "one column, pending refetch", columns: .one, selected: .running(target: "t2"), endSelectedRunningRow: true,
                 expected: BottomPanelModel(hints: [.move],
                                            buttons: BottomPanelButtons(primary: jumpT2.disabled(), branch: branchS2.disabled()),
                                            showsViewButton: true)),
            Case(name: "two columns, no selection", columns: .two, selected: nil, endSelectedRunningRow: false, expected: nil),
            Case(name: "two columns, History row", columns: .two, selected: .conversation(sessionID: "h1"), endSelectedRunningRow: false,
                 expected: nil),
        ]
        for testCase in cases {
            var state = populated(columns: testCase.columns)
            state.handle(.historyDelivered(
                [UL.summary("s1", live: true), UL.summary("h1"), UL.summary("live", live: true)],
                isFiltered: false))
            if let selected = testCase.selected {
                state.handle(.rowClicked(selected))
            }
            if testCase.endSelectedRunningRow {
                state.handle(.agentsUpdated([UL.agent("t1", session: "s1", createdAt: 20)]))
                XCTAssertTrue(state.isAwaitingRefetch, testCase.name)
            }
            XCTAssertEqual(state.listBottomPanel, testCase.expected, testCase.name)
            if testCase.columns == .one {
                XCTAssertEqual(state.paneContent, .hidden, "\(testCase.name): still the list page")
            }
        }
    }

    /// §4.6 "bottom panel" / §8.55: the buttons show only while a row is
    /// selected and the search field does not have focus.
    func testBottomPanelShowsButtonsRule() {
        XCTAssertFalse(BottomPanelModel.showsButtons(hasSelection: false, searchFieldFocused: false))
        XCTAssertFalse(BottomPanelModel.showsButtons(hasSelection: false, searchFieldFocused: true))
        XCTAssertTrue(BottomPanelModel.showsButtons(hasSelection: true, searchFieldFocused: false))
        XCTAssertFalse(BottomPanelModel.showsButtons(hasSelection: true, searchFieldFocused: true))
    }

    /// The one-column detail page's panel follows the same rule; its key
    /// hints stay.
    func testDetailPagePanelHidesTheButtonsWhileTheSearchFieldHasFocus() {
        var state = populated()
        state.openDetailPage(.conversation(sessionID: "h1"))
        state.handle(.searchFieldFocusChanged(true))
        guard case .conversation(let focused) = state.paneContent else { return XCTFail("expected the detail page") }
        XCTAssertEqual(focused.bottomPanel, BottomPanelModel(hints: [.prevNext, .back], buttons: nil, showsViewButton: false))
        state.handle(.searchFieldFocusChanged(false))
        guard case .conversation(let listFocused) = state.paneContent else { return XCTFail("expected the detail page") }
        XCTAssertNotNil(listFocused.bottomPanel.buttons)
    }

    /// The pane's bottom panel uses the same model: the detail page's key
    /// hints, the two-column right column without hints, buttons always.
    func testPaneBottomPanel() {
        var one = populated()
        one.openDetailPage(.conversation(sessionID: "h1"))
        guard case .conversation(let detail) = one.paneContent else { return XCTFail("expected the detail page") }
        XCTAssertEqual(detail.bottomPanel, BottomPanelModel(
            hints: [.prevNext, .back],
            buttons: BottomPanelButtons(primary: detail.primaryButton, branch: detail.branchButton),
            showsViewButton: false))
        XCTAssertEqual(detail.bottomPanel.buttons?.primary.kind, .resume)
        XCTAssertEqual(one.listBottomPanel?.buttons, detail.bottomPanel.buttons,
                       "the list page and the detail page show the same buttons")

        var two = populated(columns: .two)
        two.handle(.rowClicked(.running(target: "t1")))
        guard case .conversation(let right) = two.paneContent else { return XCTFail("expected the right column") }
        XCTAssertEqual(right.bottomPanel.hints, [])
        XCTAssertEqual(right.bottomPanel.buttons?.primary.kind, .jump)
        XCTAssertEqual(two.footerHints, [.move], "the left column keeps the key hints")
    }

    // MARK: - Focus search, stars, clock, perform

    func testFocusSearchReturnsToTheListPage() {
        var state = populated()
        state.openDetailPage(.conversation(sessionID: "h1"))
        XCTAssertEqual(state.handle(.focusSearch), [.focusSearchField, .scrollSelectionIntoView])
        XCTAssertEqual(state.page, .list)
        XCTAssertEqual(state.handle(.focusSearch), [.focusSearchField])
    }

    func testStarToggleMovesTheRowBetweenSectionsWithoutSelecting() {
        var state = populated()
        let effects = state.handle(.starToggled(sessionID: "h3"))
        XCTAssertEqual(effects, [.persistStars(["h3"])])
        XCTAssertNil(state.selection)
        XCTAssertEqual(state.starredRows.map(\.sessionID), ["h3"])
        XCTAssertEqual(state.recentRows.map(\.sessionID), ["h1", "h2"])
        state.handle(.starToggled(sessionID: "h3"))
        XCTAssertEqual(state.starredRows.map(\.sessionID), [])
        XCTAssertEqual(state.recentRows.map(\.sessionID), ["h1", "h2", "h3"])
    }

    func testStarToggleKeepsAnExistingSelection() {
        var state = populated()
        state.openDetailPage(.conversation(sessionID: "h1"))
        state.handle(.starToggled(sessionID: "h2"))
        XCTAssertEqual(state.selection?.key, .conversation(sessionID: "h1"))
        XCTAssertEqual(state.page, .detail)
    }

    func testClockTickUpdatesElapsedOnly() {
        var state = populated()
        state.handle(.rowClicked(.running(target: "t1")))
        XCTAssertEqual(state.runningRows.first?.elapsedText, "4m")
        XCTAssertEqual(state.handle(.clockTicked(now: UL.now + 60)), [])
        XCTAssertEqual(state.runningRows.first?.elapsedText, "5m")
        XCTAssertEqual(state.runningRows.first?.labelLine, "demo/api", "the label line carries no elapsed time")
        XCTAssertEqual(state.selection?.key, .running(target: "t1"))
    }

    func testPerformMapsCommandsToEffects() {
        var state = populated()
        XCTAssertEqual(state.perform(.primary), [], "no selection: nothing")
        XCTAssertEqual(state.perform(.branch), [])
        state.openDetailPage(.conversation(sessionID: "h1"))
        XCTAssertEqual(state.perform(.primary), [.invoke(.resume(sessionID: "h1", cwd: "/Users/example/demo/web"))])
        XCTAssertEqual(state.perform(.branch), [.invoke(.branch(sessionID: "h1", cwd: "/Users/example/demo/web"))])
        XCTAssertEqual(state.perform(.nextMatch), [.nextMatch])
        XCTAssertEqual(state.perform(.previousMatch), [.previousMatch])
        XCTAssertEqual(state.perform(.closePopover), [.closePopover])
        XCTAssertEqual(state.perform(.increaseTextSize), [.increaseTextSize])
        XCTAssertEqual(state.perform(.decreaseTextSize), [.decreaseTextSize])
        XCTAssertEqual(state.perform(.resetTextSize), [.resetTextSize])
        XCTAssertEqual(state.perform(.back), [.scrollSelectionIntoView, .focusList])
        XCTAssertEqual(state.page, .list)
        XCTAssertEqual(state.perform(.openDetail), [.loadConversation(sessionID: "h1"), .focusConversationPane])
        XCTAssertEqual(state.perform(.focusSearch), [.focusSearchField, .scrollSelectionIntoView])
        state.handle(.rowClicked(.running(target: "t2")))
        XCTAssertEqual(state.perform(.primary), [.invoke(.jump(target: "t2"))])
    }

    func testKeyContextReflectsTheState() {
        var state = populated(columns: .two)
        XCTAssertEqual(state.keyContext(isPopover: false, hasMarkedText: false), ListKeyContext(
            columns: .two, page: .list, searchFieldFocused: false, hasRows: true,
            hasSelection: false, primaryEnabled: false, branchEnabled: false,
            conversationPaneVisible: false, isPopover: false, hasMarkedText: false))
        state.handle(.rowClicked(.conversation(sessionID: "h1")))
        state.handle(.searchFieldFocusChanged(true))
        XCTAssertEqual(state.keyContext(isPopover: false, hasMarkedText: true), ListKeyContext(
            columns: .two, page: .list, searchFieldFocused: true, hasRows: true,
            hasSelection: true, primaryEnabled: true, branchEnabled: true,
            conversationPaneVisible: true, isPopover: false, hasMarkedText: true))
        let empty = UnifiedListState(home: UL.home, now: UL.now)
        XCTAssertFalse(empty.keyContext(isPopover: true, hasMarkedText: false).hasRows)
    }
}

extension UnifiedListState {
    /// Opens a row's detail page the way the user does in one column: a
    /// click selects the row (skipped when it is already selected, where a
    /// click would deselect it), then View / → opens the page (§4.5 "opening
    /// the detail page").
    @discardableResult
    mutating func openDetailPage(_ key: UnifiedRowKey) -> [UnifiedListEffect] {
        var effects: [UnifiedListEffect] = []
        if selection?.key != key {
            effects += handle(.rowClicked(key))
        }
        effects += handle(.openDetail)
        return effects
    }
}
