import XCTest
@testable import ShiibarCcCore

/// DESIGN.md §4.5 "operations that lower the unreviewed flag", "desktop
/// notifications" (`rekey`, notification click), §8.66, §9.
final class SelectionMarkReadTests: XCTestCase {
    private let running = UnifiedRowKey.running(target: "process:4242")
    private let otherRunning = UnifiedRowKey.running(target: "iterm2:ABC")
    private let history = UnifiedRowKey.conversation(sessionID: "h1")

    func testTheDelayIsTheSection9Constant() {
        XCTAssertEqual(SelectionMarkRead.delaySeconds, 1)
    }

    // MARK: - Starting and cancelling

    func testDecisionTable() {
        struct Case {
            let name: String
            let trigger: SelectionMarkRead.Trigger
            let before: UnifiedRowKey?
            let after: UnifiedRowKey?
            let expected: SelectionMarkRead.Decision
        }
        let cases: [Case] = [
            Case(name: "user selects a Running row", trigger: .userSelection, before: nil, after: running,
                 expected: .start),
            Case(name: "user selects the selected Running row again", trigger: .userSelection,
                 before: running, after: running, expected: .start),
            Case(name: "user moves to another Running row", trigger: .userSelection,
                 before: running, after: otherRunning, expected: .start),
            Case(name: "user selects a History row", trigger: .userSelection, before: running, after: history,
                 expected: .cancel),
            Case(name: "accent click deselects", trigger: .deselectClick, before: running, after: running,
                 expected: .cancel),
            Case(name: "surface closed", trigger: .surfaceClosed, before: running, after: running,
                 expected: .cancel),
            Case(name: "rekey carries the selection over", trigger: .rekey, before: running, after: otherRunning,
                 expected: .keep),
            Case(name: "same row kept", trigger: .other, before: running, after: running, expected: .keep),
            Case(name: "selection cleared", trigger: .other, before: running, after: nil, expected: .cancel),
            Case(name: "kept selection moved into Running (not the user)", trigger: .other, before: history,
                 after: running, expected: .cancel),
            Case(name: "nothing selected", trigger: .other, before: nil, after: nil, expected: .keep),
        ]
        for testCase in cases {
            XCTAssertEqual(
                SelectionMarkRead.decide(trigger: testCase.trigger, before: testCase.before, after: testCase.after),
                testCase.expected, testCase.name)
        }
    }

    // MARK: - When the time has passed

    func testMarksOnlyAnUnreviewedRunningRow() {
        let unreviewed = [UL.agent("process:4242", session: "s", unreviewed: true)]
        let reviewed = [UL.agent("process:4242", session: "s", unreviewed: false)]
        XCTAssertEqual(SelectionMarkRead.targetToMarkRead(selection: running, awaitingRefetch: false, agents: unreviewed),
                       "process:4242")
        XCTAssertNil(SelectionMarkRead.targetToMarkRead(selection: running, awaitingRefetch: false, agents: reviewed))
        XCTAssertNil(SelectionMarkRead.targetToMarkRead(selection: history, awaitingRefetch: false, agents: unreviewed))
        XCTAssertNil(SelectionMarkRead.targetToMarkRead(selection: nil, awaitingRefetch: false, agents: unreviewed))
        XCTAssertNil(SelectionMarkRead.targetToMarkRead(selection: running, awaitingRefetch: true, agents: unreviewed),
                     "an ended row awaiting the refetch has no entry to mark")
    }

    // MARK: - Rekey map

    func testRekeyMapFollowsAChainOfThree() {
        var map = TargetRekeyMap()
        XCTAssertEqual(map.resolve("A"), "A")
        map.record(from: "A", to: "B")
        XCTAssertEqual(map.resolve("A"), "B")
        map.record(from: "B", to: "C")
        XCTAssertEqual(map.resolve("A"), "C", "A -> B, B -> C")
        XCTAssertEqual(map.resolve("B"), "C")
        XCTAssertEqual(map.resolve("C"), "C")
        XCTAssertEqual(map.sources(resolvingTo: "C"), ["A", "B"])
        map.record(from: "D", to: "D")
        XCTAssertEqual(map.count, 2, "a target mapped to itself is not recorded")
    }

    /// A re-key back to an earlier target: the newest destination is the
    /// entry's current target, whichever direction the move went.
    func testRekeyBackToAnEarlierTargetEndsAtTheCurrentTarget() {
        var forward = TargetRekeyMap()
        forward.record(from: "ghostty:X", to: "process:7")
        forward.record(from: "process:7", to: "ghostty:X")
        XCTAssertEqual(forward.resolve("process:7"), "ghostty:X")
        XCTAssertEqual(forward.resolve("ghostty:X"), "ghostty:X")
        XCTAssertEqual(forward.count, 1)

        var backward = TargetRekeyMap()
        backward.record(from: "process:7", to: "ghostty:X")
        backward.record(from: "ghostty:X", to: "process:7")
        XCTAssertEqual(backward.resolve("ghostty:X"), "process:7")
        XCTAssertEqual(backward.resolve("process:7"), "process:7")
    }

    /// With an unrelated third mapping, the walk bound (the number of
    /// mappings) no longer stops a cycle early, so a cycle would end on
    /// the wrong target; `record` never creates one.
    func testRekeyBackWithAnUnrelatedMappingStillEndsAtTheCurrentTarget() {
        var map = TargetRekeyMap()
        map.record(from: "iterm2:Z", to: "process:9")
        map.record(from: "ghostty:X", to: "process:7")
        map.record(from: "process:7", to: "ghostty:X")
        XCTAssertEqual(map.resolve("ghostty:X"), "ghostty:X")
        XCTAssertEqual(map.resolve("process:7"), "ghostty:X")
        XCTAssertEqual(map.resolve("iterm2:Z"), "process:9")
    }

    /// A -> B, B -> C, then C -> A: every former target ends at A.
    func testRekeyChainComingBackToItsStartEndsThere() {
        var map = TargetRekeyMap()
        map.record(from: "A", to: "B")
        map.record(from: "B", to: "C")
        map.record(from: "C", to: "A")
        for target in ["A", "B", "C"] {
            XCTAssertEqual(map.resolve(target), "A", target)
        }
        XCTAssertEqual(map.sources(resolvingTo: "A"), ["B", "C"])
    }

    /// A new entry under a target that was a former target of another
    /// entry (a reused `process:<pid>`) is not redirected.
    func testATargetThatIsCurrentAgainIsNotRedirected() {
        var map = TargetRekeyMap()
        map.record(from: "process:7", to: "ghostty:X")
        map.targetIsCurrent("process:7")
        XCTAssertEqual(map.resolve("process:7"), "process:7")
        XCTAssertEqual(map.resolve("ghostty:X"), "ghostty:X")
        XCTAssertEqual(map.sources(resolvingTo: "ghostty:X"), [])
        XCTAssertEqual(map.count, 0)
    }

    // MARK: - Resend after a rekey

    func testResendOnlyForARekeyWhileRunningAndOnlyToAnUnreviewedEntry() {
        let unreviewedNew = [UL.agent("ghostty:/dev/ttys004", session: "s", unreviewed: true)]
        let reviewedNew = [UL.agent("ghostty:/dev/ttys004", session: "s", unreviewed: false)]

        var tracker = SeenRequestTracker()
        let first = tracker.started(target: "process:4242")
        tracker.rekeyed(from: "process:4242", to: "ghostty:/dev/ttys004")
        XCTAssertEqual(tracker.finished(id: first, agents: unreviewedNew), "ghostty:/dev/ttys004")
        XCTAssertNil(tracker.finished(id: first, agents: unreviewedNew), "once only")
        XCTAssertTrue(tracker.isEmpty)

        let notUnreviewed = tracker.started(target: "process:4242")
        tracker.rekeyed(from: "process:4242", to: "ghostty:/dev/ttys004")
        XCTAssertNil(tracker.finished(id: notUnreviewed, agents: reviewedNew), "the new entry is not unreviewed")

        let noRekey = tracker.started(target: "process:4242")
        XCTAssertNil(tracker.finished(id: noRekey, agents: unreviewedNew))
        tracker.rekeyed(from: "process:4242", to: "ghostty:/dev/ttys004")
        XCTAssertTrue(tracker.isEmpty, "a rekey after the end resends nothing")

        let chained = tracker.started(target: "A")
        tracker.rekeyed(from: "A", to: "B")
        tracker.rekeyed(from: "B", to: "C")
        XCTAssertEqual(tracker.finished(id: chained, agents: [UL.agent("C", session: "s", unreviewed: true)]), "C")

        let otherTarget = tracker.started(target: "X")
        tracker.rekeyed(from: "Y", to: "Z")
        XCTAssertNil(tracker.finished(id: otherTarget, agents: [UL.agent("Z", session: "s", unreviewed: true)]))
    }

    // MARK: - agent_removed

    func testOnlyARekeyWithItsNewTargetMovesTheEntry() {
        XCTAssertEqual(AgentRemovalHandling.decide(reason: .rekey, to: "ghostty:/dev/ttys004"),
                       .rekey(to: "ghostty:/dev/ttys004"))
        XCTAssertEqual(AgentRemovalHandling.decide(reason: .rekey, to: nil), .remove(sweepReason: .remove))
        for reason in [RemovalReason.sessionEnd, .stale, .remove, .prune, .unknown] {
            XCTAssertEqual(AgentRemovalHandling.decide(reason: reason, to: nil), .remove(sweepReason: reason), "\(reason)")
        }
    }

    func testAgentTableAfterARekeyRenamesOrMerges() {
        let moving = UL.agent("process:4242", session: "s", unreviewed: true, createdAt: 10)
        let other = UL.agent("iterm2:A", session: "a", createdAt: 20)
        let renamed = AgentRemovalHandling.agentsAfterRekey([other, moving], from: "process:4242", to: "ghostty:/dev/ttys004")
        XCTAssertEqual(renamed, [other, moving.withTarget("ghostty:/dev/ttys004")], "renamed in place, attributes kept")

        let existing = UL.agent("ghostty:/dev/ttys004", session: "s", createdAt: 5)
        let merged = AgentRemovalHandling.agentsAfterRekey([other, moving, existing], from: "process:4242",
                                                           to: "ghostty:/dev/ttys004")
        XCTAssertEqual(merged, [other, existing], "the entry already under the new target stays")

        XCTAssertEqual(AgentRemovalHandling.agentsAfterRekey([other, moving], from: "process:4242", to: "process:4242"),
                       [other, moving])
    }

    // MARK: - Notification click

    func testNotificationClickJumpsOrSelectsByTarget() {
        for target in ["iterm2:ABC", "apple-terminal:/dev/ttys001", "ghostty:/dev/ttys002", "ABC", "w0t1p2:ABC"] {
            XCTAssertEqual(NotificationClickAction.decide(target: target), .focus(target: target), target)
        }
        for target in ["process:4242", "unknown:x"] {
            XCTAssertEqual(NotificationClickAction.decide(target: target), .selectRow(target: target), target)
        }
    }
}

/// The mark-read timer in the list state (§4.5 "operations that lower the
/// unreviewed flag"). The app answers each new `markReadTimerID` with
/// `.markReadDue(id:)` after §9's time; these tests send that answer
/// themselves, so no test waits on the clock.
final class UnifiedListMarkReadTests: XCTestCase {
    private let jumpable = UnifiedRowKey.running(target: "iterm2:A")
    private let undrivable = UnifiedRowKey.running(target: "process:4242")

    private func agents(unreviewedA: Bool = true, unreviewedP: Bool = true) -> [Agent] {
        [
            UL.agent("iterm2:A", session: "sa", unreviewed: unreviewedA, createdAt: 20),
            UL.agent("process:4242", session: "sp", unreviewed: unreviewedP, createdAt: 10),
        ]
    }

    private func populated(columns: ColumnMode = .one, unreviewedA: Bool = true, unreviewedP: Bool = true)
        -> UnifiedListState {
        var state = UnifiedListState(home: UL.home, now: UL.now)
        state.handle(.columnsChanged(columns))
        state.handle(.agentsUpdated(agents(unreviewedA: unreviewedA, unreviewedP: unreviewedP)))
        state.handle(.historyDelivered([UL.summary("h1"), UL.summary("h2")], isFiltered: false))
        return state
    }

    /// The answer of the running timer.
    @discardableResult
    private func fire(_ state: inout UnifiedListState) -> [UnifiedListEffect] {
        guard let id = state.markReadTimerID else { return [] }
        return state.handle(.markReadDue(id: id))
    }

    private func grayClick(_ state: inout UnifiedListState, _ key: UnifiedRowKey) {
        state.handle(.pointerDown(surfaceKey: false, searchFieldFocused: false))
        state.handle(.rowClicked(key))
    }

    // MARK: - Each selecting operation

    func testEverySelectingOperationMarksReadOnlyAfterTheTime() {
        struct Case {
            let name: String
            let select: (inout UnifiedListState) -> [UnifiedListEffect]
            let expected: String
        }
        let cases: [Case] = [
            Case(name: "click", select: { $0.handle(.rowClicked(.running(target: "process:4242"))) },
                 expected: "process:4242"),
            Case(name: "↓ with no selection", select: { $0.handle(.moveDown) }, expected: "iterm2:A"),
            Case(name: "Enter in the search field", select: {
                $0.handle(.searchFieldFocusChanged(true))
                return $0.handle(.enterFromSearchField)
            }, expected: "iterm2:A"),
            Case(name: "Enter with list focus", select: { $0.handle(.selectFirstRow) }, expected: "iterm2:A"),
            Case(name: "next conversation on the detail page", select: { state in
                state.openDetailPage(.running(target: "iterm2:A"))
                state.handle(.markReadDue(id: state.markReadTimerID ?? -1))
                return state.handle(.nextConversation)
            }, expected: "process:4242"),
            Case(name: "notification click",
                 select: { $0.handle(.notificationClicked(target: "process:4242", hasSearchText: false)) },
                 expected: "process:4242"),
        ]
        for testCase in cases {
            var state = populated()
            let effects = testCase.select(&state)
            XCTAssertFalse(effects.contains { if case .markRead = $0 { return true } else { return false } },
                           "\(testCase.name): selecting does not mark read")
            XCTAssertNotNil(state.markReadTimerID, testCase.name)
            XCTAssertEqual(fire(&state), [.markRead(target: testCase.expected)], testCase.name)
            XCTAssertNil(state.markReadTimerID, "\(testCase.name): one run per timer")
            XCTAssertEqual(fire(&state), [], "\(testCase.name): only once")
        }
    }

    func testNothingForARowThatIsNotUnreviewedOrAHistoryRow() {
        var reviewed = populated(unreviewedP: false)
        reviewed.handle(.rowClicked(undrivable))
        XCTAssertEqual(fire(&reviewed), [])

        var history = populated()
        history.handle(.rowClicked(.conversation(sessionID: "h1")))
        XCTAssertNil(history.markReadTimerID, "a History row has nothing to lower")
    }

    /// §4.5: unreviewed is read when the time has passed.
    func testUnreviewedIsDecidedWhenTheTimeHasPassed() {
        var risingDuring = populated(unreviewedP: false)
        risingDuring.handle(.rowClicked(undrivable))
        risingDuring.handle(.agentsUpdated(agents(unreviewedP: true)))
        XCTAssertEqual(fire(&risingDuring), [.markRead(target: "process:4242")], "rose while measuring")

        var risingAfter = populated(unreviewedP: false)
        risingAfter.handle(.rowClicked(undrivable))
        XCTAssertEqual(fire(&risingAfter), [])
        risingAfter.handle(.agentsUpdated(agents(unreviewedP: true)))
        XCTAssertNil(risingAfter.markReadTimerID, "a selected row becoming unreviewed starts nothing")
        XCTAssertEqual(risingAfter.selection?.key, undrivable)
    }

    // MARK: - Cancelling

    func testMovingDeselectingRemovingOrClosingCancels() {
        // ↑ / ↓ passing over a row: only the row the selection stops on.
        var passing = populated()
        passing.handle(.moveDown)
        let passedTimer = passing.markReadTimerID
        passing.handle(.moveDown)
        XCTAssertEqual(passing.handle(.markReadDue(id: passedTimer ?? -1)), [], "the passed row stays unreviewed")
        XCTAssertEqual(fire(&passing), [.markRead(target: "process:4242")])

        // Accent click on the selected row: deselects, nothing marked.
        var deselected = populated()
        deselected.handle(.rowClicked(undrivable))
        let timer = deselected.markReadTimerID
        deselected.handle(.rowClicked(undrivable))
        XCTAssertNil(deselected.selection)
        XCTAssertNil(deselected.markReadTimerID)
        XCTAssertEqual(deselected.handle(.markReadDue(id: timer ?? -1)), [])

        // The same with a press: the deselect waits for the double-click
        // interval, and the timer stops at the click.
        var deferred = populated()
        deferred.handle(.rowClicked(undrivable))
        let deferredTimer = deferred.markReadTimerID
        deferred.handle(.pointerDown(surfaceKey: true, searchFieldFocused: false, clickCount: 1, pressedAt: 1))
        deferred.handle(.rowClicked(undrivable))
        XCTAssertNotNil(deferred.pendingDeselect)
        XCTAssertEqual(deferred.handle(.markReadDue(id: deferredTimer ?? -1)), [])

        // The selected row left the list (the session ended).
        var removed = populated()
        removed.handle(.rowClicked(undrivable))
        let removedTimer = removed.markReadTimerID
        removed.handle(.agentsUpdated([UL.agent("iterm2:A", session: "sa", unreviewed: true, createdAt: 20)]))
        XCTAssertEqual(removed.handle(.markReadDue(id: removedTimer ?? -1)), [])

        // Closing the surface; reopening carries nothing over.
        var closed = populated()
        closed.handle(.rowClicked(undrivable))
        let closedTimer = closed.markReadTimerID
        closed.handle(.surfaceHidden)
        XCTAssertNil(closed.markReadTimerID)
        closed.handle(.columnsChanged(.two))
        closed.handle(.clockTicked(now: UL.now + 60))
        XCTAssertNil(closed.markReadTimerID, "a selection kept from before closing starts nothing")
        XCTAssertEqual(closed.selection?.key, undrivable)
        XCTAssertEqual(closed.handle(.markReadDue(id: closedTimer ?? -1)), [])
    }

    func testTheSurfaceStoppingBeingKeyKeepsMeasuring() {
        var state = populated()
        state.handle(.rowClicked(undrivable))
        state.handle(.surfaceKeyChanged(false))
        XCTAssertEqual(fire(&state), [.markRead(target: "process:4242")])
    }

    func testConversationPaneFocusAndSearchFocusDoNotMarkRead() {
        var state = populated(columns: .two)
        state.handle(.rowClicked(undrivable))
        XCTAssertEqual(fire(&state), [.markRead(target: "process:4242")])
        // The flag rises again; focus moves around without a selecting
        // operation.
        state.handle(.agentsUpdated(agents()))
        state.handle(.searchFieldFocusChanged(true))
        state.handle(.searchFieldFocusChanged(false))
        state.handle(.surfaceKeyChanged(true))
        XCTAssertNil(state.markReadTimerID)
    }

    // MARK: - Selections not made by the user

    func testAKeptSelectionMovingIntoRunningStartsNothing() {
        var state = UnifiedListState(home: UL.home, now: UL.now)
        state.handle(.agentsUpdated([]))
        state.handle(.historyDelivered([UL.summary("s9")], isFiltered: false))
        state.handle(.rowClicked(.conversation(sessionID: "s9")))
        XCTAssertNil(state.markReadTimerID)
        state.handle(.agentsUpdated([UL.agent("process:7", session: "s9", unreviewed: true)]))
        XCTAssertEqual(state.selection?.key, .running(target: "process:7"), "Resume: the selection follows")
        XCTAssertNil(state.markReadTimerID)
    }

    // MARK: - Starting over on the selected row

    func testOperationsOnTheSelectedRowStartOver() {
        // A gray selected row's click.
        var gray = populated()
        gray.handle(.rowClicked(undrivable))
        XCTAssertEqual(fire(&gray), [.markRead(target: "process:4242")])
        grayClick(&gray, undrivable)
        XCTAssertNotNil(gray.markReadTimerID)
        XCTAssertEqual(gray.selection?.key, undrivable)
        XCTAssertEqual(fire(&gray), [.markRead(target: "process:4242")])

        // A double-click on the selected row.
        var double = populated()
        double.handle(.rowClicked(undrivable))
        let firstTimer = double.markReadTimerID
        double.handle(.pointerDown(surfaceKey: true, searchFieldFocused: false, clickCount: 1, pressedAt: 1))
        double.handle(.rowClicked(undrivable))
        double.handle(.pointerDown(surfaceKey: true, searchFieldFocused: false, clickCount: 2, pressedAt: 1.1))
        double.handle(.rowClicked(undrivable))
        XCTAssertEqual(double.selection?.key, undrivable, "a double-click never deselects")
        XCTAssertNotEqual(double.markReadTimerID, firstTimer)
        XCTAssertEqual(double.handle(.markReadDue(id: firstTimer ?? -1)), [], "the earlier timer was replaced")
        XCTAssertEqual(fire(&double), [.markRead(target: "process:4242")])

        // Enter on a row that cannot be jumped to, on every page.
        let pages: [(String, ColumnMode, Bool)] = [
            ("one column, list page", .one, false), ("one column, detail page", .one, true),
            ("two columns", .two, false),
        ]
        for (name, columns, detail) in pages {
            var state = populated(columns: columns)
            if detail {
                state.openDetailPage(undrivable)
            } else {
                state.handle(.rowClicked(undrivable))
            }
            let before = state.markReadTimerID
            state.perform(.showConversation)
            XCTAssertNotNil(state.markReadTimerID, name)
            XCTAssertNotEqual(state.markReadTimerID, before, "\(name): started over")
            XCTAssertEqual(fire(&state), [.markRead(target: "process:4242")], name)
        }

        // Enter on a jumpable row runs Jump (the CLI lowers the flag).
        var jump = populated()
        jump.handle(.rowClicked(jumpable))
        let jumpTimer = jump.markReadTimerID
        XCTAssertEqual(jump.perform(.primary), [.invoke(.jump(target: "iterm2:A"))])
        XCTAssertEqual(jump.markReadTimerID, jumpTimer)
    }

    /// Enter showing the conversation, or a notification click for the
    /// row, within the double-click interval after the accent click: the
    /// pending deselect is cancelled, so the row stays selected, the pane
    /// stays, and the timer that operation started runs to the end.
    func testSelectingTheRowAgainCancelsAPendingDeselect() {
        let cases: [(String, (inout UnifiedListState) -> [UnifiedListEffect])] = [
            ("Enter shows the conversation", { $0.perform(.showConversation) }),
            ("notification click for the row",
             { $0.handle(.notificationClicked(target: "process:4242", hasSearchText: false)) }),
        ]
        for (name, operate) in cases {
            var state = populated(columns: .two)
            state.handle(.rowClicked(undrivable))
            state.handle(.pointerDown(surfaceKey: true, searchFieldFocused: false, clickCount: 1, pressedAt: 1))
            state.handle(.rowClicked(undrivable))
            guard let pending = state.pendingDeselect else { return XCTFail("\(name): the deselect waits") }
            XCTAssertNil(state.markReadTimerID, "\(name): the accent click stopped the timer")
            _ = operate(&state)
            XCTAssertNil(state.pendingDeselect, name)
            let timer = state.markReadTimerID
            XCTAssertNotNil(timer, name)
            XCTAssertEqual(state.handle(.deferredDeselectDue(id: pending.id)), [], name)
            XCTAssertEqual(state.selection?.key, undrivable, "\(name): stays selected")
            XCTAssertEqual(state.markReadTimerID, timer, "\(name): the timer keeps running")
            guard case .conversation = state.paneContent else { return XCTFail("\(name): the pane stays") }
            XCTAssertEqual(fire(&state), [.markRead(target: "process:4242")], name)
        }
    }

    // MARK: - rekey

    func testRekeyCarriesTheSelectionAndKeepsTheTimer() {
        var state = populated(columns: .two)
        state.handle(.rowClicked(undrivable))
        let timer = state.markReadTimerID
        let effects = state.handle(.targetRekeyed(from: "process:4242", to: "ghostty:/dev/ttys004"))
        XCTAssertEqual(effects, [], "no refetch, no reload of the pane")
        XCTAssertEqual(state.selection, RowSelection(key: .running(target: "ghostty:/dev/ttys004"), sessionID: "sp"))
        XCTAssertEqual(state.markReadTimerID, timer, "the timer keeps running")
        // The agent table that follows has the new target.
        let renamed = [
            UL.agent("iterm2:A", session: "sa", unreviewed: true, createdAt: 20),
            UL.agent("ghostty:/dev/ttys004", session: "sp", unreviewed: true, createdAt: 10),
        ]
        XCTAssertEqual(state.handle(.agentsUpdated(renamed)), [], "the row is not treated as gone")
        XCTAssertEqual(state.selection?.key, .running(target: "ghostty:/dev/ttys004"))
        guard case .conversation(let pane) = state.paneContent else { return XCTFail("the pane stays") }
        XCTAssertEqual(pane.row.sessionID, "sp")
        XCTAssertEqual(fire(&state), [.markRead(target: "ghostty:/dev/ttys004")], "marks the new target")
    }

    func testASelectionCarriedOverByRekeyStartsNothing() {
        var kept = populated()
        kept.handle(.rowClicked(undrivable))
        kept.handle(.surfaceHidden)
        kept.handle(.targetRekeyed(from: "process:4242", to: "ghostty:/dev/ttys004"))
        XCTAssertEqual(kept.selection?.key, .running(target: "ghostty:/dev/ttys004"))
        XCTAssertNil(kept.markReadTimerID)
    }

    /// Without a rekey, a row whose target disappeared is the ended row:
    /// its selection does not move to a new target with the same session.
    func testARemovalCarriesNothingOver() {
        var state = populated(columns: .two)
        state.handle(.rowClicked(undrivable))
        state.handle(.agentsUpdated([
            UL.agent("iterm2:A", session: "sa", unreviewed: true, createdAt: 20),
            UL.agent("ghostty:/dev/ttys004", session: "sp", unreviewed: true, createdAt: 10),
        ]))
        XCTAssertEqual(state.selection?.key, undrivable)
        XCTAssertTrue(state.isAwaitingRefetch, "treated as an ended row")
        XCTAssertEqual(fire(&state), [])
    }

    func testRekeyOfAnotherRowLeavesTheSelectionAlone() {
        var state = populated()
        state.handle(.rowClicked(jumpable))
        state.handle(.targetRekeyed(from: "process:4242", to: "ghostty:/dev/ttys004"))
        XCTAssertEqual(state.selection?.key, jumpable)
        XCTAssertEqual(state.runningRows.map(\.id), [jumpable, .running(target: "ghostty:/dev/ttys004")])
    }

    // MARK: - Notification click

    func testNotificationClickOpensTheRowFromAnyListState() {
        var state = populated(columns: .one)
        // Running closed, searching, a detail page of another conversation.
        state.handle(.headingClicked(.running))
        state.handle(.queryValidityChanged(true))
        state.handle(.historyDelivered([UL.summary("h1")], isFiltered: true))
        XCTAssertFalse(state.runningRows.contains { $0.id == undrivable }, "the filtered result hides it")
        state.openDetailPage(.conversation(sessionID: "h1"))
        let effects = state.handle(.notificationClicked(target: "process:4242", hasSearchText: true))
        XCTAssertEqual(state.selection?.key, undrivable)
        XCTAssertEqual(state.page, .list, "another conversation was shown: back to the list page")
        XCTAssertFalse(state.isSearching)
        XCTAssertTrue(state.isSectionShown(.running))
        XCTAssertTrue(effects.contains(.clearSearchText))
        XCTAssertTrue(effects.contains(.persistCollapsedSections([])))
        XCTAssertTrue(effects.contains(.focusList))
        XCTAssertTrue(effects.contains(.scrollSelectionIntoView))
        XCTAssertNotNil(state.markReadTimerID)
        // The browse result for the cleared search arrives.
        state.handle(.historyDelivered([UL.summary("h1"), UL.summary("h2")], isFiltered: false))
        XCTAssertEqual(state.selection?.key, undrivable)
    }

    func testNotificationClickFromTheArchiveView() {
        var state = UnifiedListState(home: UL.home, now: UL.now, archived: ArchivedList(["h2"]))
        state.handle(.agentsUpdated(agents()))
        state.handle(.historyDelivered([UL.summary("h1"), UL.summary("h2")], isFiltered: false))
        state.handle(.archivedMenuItemChosen)
        XCTAssertTrue(state.isArchiveView)
        state.handle(.notificationClicked(target: "process:4242", hasSearchText: false))
        XCTAssertFalse(state.isArchiveView)
        XCTAssertEqual(state.selection?.key, undrivable)
    }

    func testNotificationClickKeepsTheDetailPageOfTheSameConversationAndTheSelection() {
        var detail = populated()
        detail.openDetailPage(undrivable)
        let effects = detail.handle(.notificationClicked(target: "process:4242", hasSearchText: false))
        XCTAssertEqual(detail.page, .detail)
        XCTAssertEqual(detail.selection?.key, undrivable)
        XCTAssertFalse(effects.contains(.clearSearchText))

        // Already selected (accent): stays selected; the timer starts over.
        var selected = populated()
        selected.handle(.rowClicked(undrivable))
        let timer = selected.markReadTimerID
        selected.handle(.notificationClicked(target: "process:4242", hasSearchText: false))
        XCTAssertEqual(selected.selection?.key, undrivable, "never deselects")
        XCTAssertNotEqual(selected.markReadTimerID, timer)
        XCTAssertEqual(selected.handle(.markReadDue(id: timer ?? -1)), [])
        XCTAssertEqual(fire(&selected), [.markRead(target: "process:4242")])
    }

    func testNotificationClickForAnEntryThatIsGoneChangesNothing() {
        var state = populated()
        state.handle(.rowClicked(.conversation(sessionID: "h1")))
        state.handle(.headingClicked(.running))
        let before = state
        XCTAssertEqual(state.handle(.notificationClicked(target: "process:999", hasSearchText: true)), [])
        XCTAssertEqual(state.selection, before.selection)
        XCTAssertEqual(state.collapsedSections, before.collapsedSections)
    }
}
