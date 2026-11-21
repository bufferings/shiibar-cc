import XCTest
@testable import ShiibarCcCore

/// The pure decisions behind the conversation pane reload (DESIGN.md §4.6
/// "conversation pane reload", §8.65, §9): which agent-table update is a
/// status-change trigger, and how a fetched message list relates to the one
/// on screen.
final class ConversationPaneReloadTests: XCTestCase {
    // MARK: - Fixtures

    private let target = "iterm2:T1"

    /// Two columns, with `select` (when given) clicked: the pane shows the
    /// selected row's conversation.
    private func state(
        agents: [Agent], history: [ConversationSummary] = [], select key: UnifiedRowKey? = nil,
        columns: ColumnMode = .two
    ) -> UnifiedListState {
        var state = UnifiedListState(home: UL.home, now: UL.now)
        state.handle(.columnsChanged(columns))
        state.handle(.agentsUpdated(agents))
        state.handle(.historyDelivered(history, isFiltered: false))
        if let key { state.handle(.rowClicked(key)) }
        return state
    }

    private func updated(_ state: UnifiedListState, to agents: [Agent]) -> UnifiedListState {
        var after = state
        after.handle(.agentsUpdated(agents))
        return after
    }

    private func trigger(from before: [Agent], to after: [Agent], select key: UnifiedRowKey? = nil) -> String? {
        let start = state(agents: before, select: key ?? .running(target: target))
        return ConversationPaneReload.statusChangeTrigger(before: start, after: updated(start, to: after))
    }

    // MARK: - Trigger 1: a status change of the shown Running row

    func testEveryChangeBetweenTheThreeStatusesIsATrigger() {
        let statuses: [AgentStatus] = [.working, .waiting, .idle]
        for from in statuses {
            for to in statuses where to != from {
                XCTAssertEqual(
                    trigger(from: [UL.agent(target, status: from, session: "s1")],
                            to: [UL.agent(target, status: to, session: "s1")]),
                    "s1", "\(from) -> \(to)")
            }
        }
    }

    func testTheSameStatusIsNoTrigger() {
        XCTAssertNil(trigger(from: [UL.agent(target, status: .working, session: "s1")],
                             to: [UL.agent(target, status: .working, session: "s1")]))
    }

    func testAnUnreviewedChangeAloneIsNoTrigger() {
        XCTAssertNil(trigger(from: [UL.agent(target, status: .idle, session: "s1", unreviewed: false)],
                             to: [UL.agent(target, status: .idle, session: "s1", unreviewed: true)]))
    }

    func testAChangeOfOtherFieldsAloneIsNoTrigger() {
        XCTAssertNil(trigger(
            from: [UL.agent(target, status: .working, session: "s1", task: "old task", message: nil, since: 9_000)],
            to: [UL.agent(target, status: .working, session: "s1", task: "new task", message: "a message", since: 9_500)]))
    }

    func testAStatusChangeOfARowThePaneDoesNotShowIsNoTrigger() {
        XCTAssertNil(trigger(
            from: [UL.agent(target, status: .working, session: "s1"), UL.agent("iterm2:T2", status: .working, session: "s2")],
            to: [UL.agent(target, status: .working, session: "s1"), UL.agent("iterm2:T2", status: .idle, session: "s2")]))
    }

    func testRowsAppearingOrDisappearingAreNoTrigger() {
        XCTAssertNil(trigger(
            from: [UL.agent(target, status: .working, session: "s1")],
            to: [UL.agent(target, status: .working, session: "s1"), UL.agent("iterm2:T2", status: .idle, session: "s2")]))
        XCTAssertNil(trigger(
            from: [UL.agent(target, status: .working, session: "s1"), UL.agent("iterm2:T2", status: .idle, session: "s2")],
            to: [UL.agent(target, status: .working, session: "s1")]))
    }

    func testTheShownRowDisappearingIsNoTrigger() {
        XCTAssertNil(trigger(from: [UL.agent(target, status: .working, session: "s1")], to: []))
    }

    func testAHistoryRowsConversationIsNoTrigger() {
        // The same session also runs in a terminal the daemon tracks under
        // another target, but the pane shows the History row.
        let start = state(
            agents: [UL.agent(target, status: .working, session: "s1")],
            history: [UL.summary("h1")],
            select: .conversation(sessionID: "h1"))
        XCTAssertNotNil(start.selection)
        XCTAssertNil(ConversationPaneReload.statusChangeTrigger(
            before: start, after: updated(start, to: [UL.agent(target, status: .idle, session: "s1")])))
    }

    func testNoSelectionIsNoTrigger() {
        let start = state(agents: [UL.agent(target, status: .working, session: "s1")])
        XCTAssertNil(start.selection)
        XCTAssertNil(ConversationPaneReload.statusChangeTrigger(
            before: start, after: updated(start, to: [UL.agent(target, status: .idle, session: "s1")])))
    }

    func testARowWithoutASessionIDIsNoTrigger() {
        XCTAssertNil(trigger(from: [UL.agent(target, status: .working, session: "")],
                             to: [UL.agent(target, status: .idle, session: "")]))
    }

    func testTheOneColumnListPageShowsNoPaneSoNoTrigger() {
        let start = state(agents: [UL.agent(target, status: .working, session: "s1")],
                          select: .running(target: target), columns: .one)
        XCTAssertEqual(start.page, .list)
        XCTAssertNil(ConversationPaneReload.statusChangeTrigger(
            before: start, after: updated(start, to: [UL.agent(target, status: .idle, session: "s1")])))
    }

    func testTheFollowUpDelayIsTwoSeconds() {
        XCTAssertEqual(ConversationPaneReload.followUpSeconds, 2)
    }

    func testThePaneIndexRunsWithoutTheProgressStream() {
        XCTAssertEqual(ConversationPaneReload.indexArguments, ["conversations", "index"])
    }

    // MARK: - Applying the result: same / appended / replaced

    private func message(_ seq: Int64, _ role: String = "user", _ text: String? = nil) -> ConversationMessage {
        ConversationMessage(seq: seq, role: role, text: text ?? "text \(seq)")
    }

    func testTheSameMessagesAreUnchanged() {
        let messages = [message(1), message(2, "assistant")]
        XCTAssertEqual(ConversationPaneUpdate.classify(displayed: messages, fetched: messages), .unchanged)
        XCTAssertEqual(ConversationPaneUpdate.classify(displayed: [], fetched: []), .unchanged)
    }

    func testMessagesAddedAtTheEndAreAppended() {
        let displayed = [message(1), message(2, "assistant")]
        XCTAssertEqual(
            ConversationPaneUpdate.classify(displayed: displayed, fetched: displayed + [message(3), message(4, "assistant")]),
            .appended(firstNewIndex: 2))
    }

    func testAChangedMessageReplacesTheList() {
        let displayed = [message(1), message(2, "assistant"), message(3)]
        // The text of the middle message changed; the others stay the same.
        let fetched = [message(1), message(2, "assistant", "edited"), message(3), message(4, "assistant")]
        XCTAssertEqual(ConversationPaneUpdate.classify(displayed: displayed, fetched: fetched),
                       .replaced(keptIndices: [0: 0, 2: 2]))
    }

    func testFewerMessagesReplaceTheList() {
        let displayed = [message(1), message(2, "assistant"), message(3)]
        XCTAssertEqual(ConversationPaneUpdate.classify(displayed: displayed, fetched: [message(1), message(2, "assistant")]),
                       .replaced(keptIndices: [0: 0, 1: 1]))
    }

    func testARoleOrSeqDifferenceIsADifferentMessage() {
        let displayed = [message(1), message(2, "assistant", "same text")]
        XCTAssertEqual(
            ConversationPaneUpdate.classify(displayed: displayed, fetched: [message(1), message(2, "user", "same text")]),
            .replaced(keptIndices: [0: 0]))
        XCTAssertEqual(
            ConversationPaneUpdate.classify(displayed: displayed, fetched: [message(1), message(5, "assistant", "same text")]),
            .replaced(keptIndices: [0: 0]))
    }

    func testKeptMessagesMapToTheirNewPositions() {
        // A message was removed from the front: the rest shift by one.
        let displayed = [message(1), message(2, "assistant"), message(3)]
        XCTAssertEqual(ConversationPaneUpdate.classify(displayed: displayed, fetched: [message(2, "assistant"), message(3)]),
                       .replaced(keptIndices: [1: 0, 2: 1]))
    }

    // MARK: - show --json `updated_at` (§4.4)

    func testShowDecodesUpdatedAt() {
        let json = #"{"session_id":"s1","cwd":"/Users/example/demo","title":"t","updated_at":1700000000,"messages":[]}"#
        XCTAssertEqual(ConversationDetail.decode(json)?.updatedAt, 1_700_000_000)
    }

    func testShowWithoutUpdatedAtStillDecodes() {
        let json = #"{"session_id":"s1","cwd":"/Users/example/demo","title":"t","messages":[{"seq":1,"role":"user","text":"hi"}]}"#
        let detail = ConversationDetail.decode(json)
        XCTAssertNotNil(detail)
        XCTAssertNil(detail?.updatedAt)
        XCTAssertEqual(detail?.messages.count, 1)
    }
}
