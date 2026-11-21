import XCTest

@testable import ShiibarCcCore

/// A session running in a terminal the app cannot drive (a `process:`
/// target — DESIGN.md §2, §3.6) shows like any other session: the spec
/// does not split the display by target kind (§4.5 "Running rows", "tray
/// icon", "collapsing sections"; §4.6 "Recent section"). Only the primary
/// button differs (the disabled Jump — §4.5 "action buttons").
final class ProcessTargetRowTests: XCTestCase {
    private let home = "/Users/example"

    private func agent(
        _ target: String, session: String = "s1", status: AgentStatus = .idle, unreviewed: Bool = false,
        task: String? = "fix the build", message: String? = nil, createdAt: Int64 = 1
    ) -> Agent {
        Agent(target: target, status: status, unreviewed: unreviewed, sessionId: session,
              cwd: "/Users/example/src/demo", task: task, message: message, createdAt: createdAt,
              since: 40, lastSeen: 90)
    }

    private func summary(_ sessionID: String, live: Bool = false) -> ConversationSummary {
        ConversationSummary(sessionID: sessionID, cwd: "/Users/example/src/demo", title: "title \(sessionID)",
                            updatedAt: 10, live: live, lastPrompt: "last prompt")
    }

    // MARK: - Running row content

    /// Label, title, last prompt, status symbol, unreviewed dot, elapsed
    /// time, header lines and Branch are the same as for a session in a
    /// supported terminal; only the primary button is the disabled Jump.
    func testProcessRowShowsTheSameContentAsASupportedTerminalRow() {
        let cases: [(AgentStatus, Bool, String?)] = [
            (.idle, false, nil), (.working, true, nil), (.waiting, true, "Claude needs your permission"),
        ]
        for (status, unreviewed, message) in cases {
            let supported = UnifiedListBuilder.runningRow(
                agent: agent("iterm2:w0t0p0:U1", status: status, unreviewed: unreviewed, message: message),
                title: "title s1", now: 100, home: home)
            let process = UnifiedListBuilder.runningRow(
                agent: agent("process:4242", status: status, unreviewed: unreviewed, message: message),
                title: "title s1", now: 100, home: home)
            guard let supported, let process else { return XCTFail("rows expected for \(status)") }
            XCTAssertEqual(process.id, .running(target: "process:4242"))
            XCTAssertEqual(process.section, .running)
            XCTAssertEqual(process.title, supported.title, "\(status)")
            XCTAssertEqual(process.label, supported.label)
            XCTAssertEqual(process.labelLine, supported.labelLine)
            XCTAssertEqual(process.showsRunningMark, supported.showsRunningMark)
            XCTAssertEqual(process.lastPrompt, supported.lastPrompt)
            XCTAssertEqual(process.symbol, supported.symbol, "status symbol and unreviewed dot")
            XCTAssertEqual(process.symbol, .status(RowSymbol.kind(for: status)!, unreviewed: unreviewed))
            XCTAssertEqual(process.elapsedText, supported.elapsedText)
            XCTAssertEqual(process.headerTitle, supported.headerTitle)
            XCTAssertEqual(process.headerLabelAndElapsed, supported.headerLabelAndElapsed)
            XCTAssertEqual(process.branchButton, supported.branchButton)
            XCTAssertEqual(process.menuItems, supported.menuItems)
            XCTAssertEqual(process.primaryButton, .undrivableJump)
            XCTAssertEqual(supported.primaryButton.invocation, .jump(target: "iterm2:w0t0p0:U1"))
        }
    }

    /// The row is in the Running section, in `created_at` order among the
    /// other rows.
    func testProcessRowIsListedInRunning() {
        var state = UnifiedListState(home: home, now: 100)
        _ = state.handle(.agentsUpdated([
            agent("iterm2:w0t0p0:U1", session: "s1", createdAt: 1),
            agent("process:4242", session: "s2", createdAt: 3),
            agent("apple-terminal:/dev/ttys004", session: "s3", createdAt: 2),
        ]))
        XCTAssertEqual(state.runningRows.map(\.id), [
            .running(target: "process:4242"),
            .running(target: "apple-terminal:/dev/ttys004"),
            .running(target: "iterm2:w0t0p0:U1"),
        ])
    }

    // MARK: - Tray icon and the closed Running mark

    /// A `process:` entry counts toward the tray icon's glyph and dot.
    func testProcessEntryCountsTowardTheTrayIcon() {
        XCTAssertEqual(
            Rollup.icon(agents: [agent("process:4242", status: .waiting)], daemonConnected: true),
            Rollup.icon(statuses: [.waiting], hasUnreviewed: false, daemonConnected: true))
        XCTAssertEqual(Rollup.icon(agents: [agent("process:4242", status: .waiting)], daemonConnected: true).glyph,
                       .waiting)
        let mixed = Rollup.icon(agents: [
            agent("iterm2:w0t0p0:U1", status: .idle),
            agent("process:4242", status: .working, unreviewed: true),
        ], daemonConnected: true)
        XCTAssertEqual(mixed.glyph, .working)
        XCTAssertEqual(mixed.dot, .unreviewed)
        XCTAssertEqual(Rollup.icon(agents: [agent("process:4242")], daemonConnected: true).glyph, .idle)
    }

    /// While Running is closed, a `process:` row's waiting state or
    /// unreviewed flag shows in the Running mark.
    func testProcessRowCountsTowardTheClosedRunningMark() {
        var state = UnifiedListState(home: home, now: 100, collapsedSections: [.running])
        _ = state.handle(.agentsUpdated([agent("process:4242", status: .working, unreviewed: true)]))
        XCTAssertEqual(state.runningAttentionMark, .unreviewed)
        _ = state.handle(.agentsUpdated([agent("process:4242", status: .waiting, unreviewed: true)]))
        XCTAssertEqual(state.runningAttentionMark, .waiting)
        _ = state.handle(.agentsUpdated([agent("process:4242", status: .idle)]))
        XCTAssertNil(state.runningAttentionMark)
    }

    // MARK: - Rows sharing a session_id with History

    /// A live History conversation with the session_id of a `process:`
    /// Running row is left out of History (§4.6 "Recent section").
    func testHistoryLeavesOutTheConversationOfAProcessRow() {
        var state = UnifiedListState(home: home, now: 100)
        _ = state.handle(.agentsUpdated([agent("process:4242", session: "s1")]))
        _ = state.handle(.historyDelivered([summary("s1", live: true), summary("s2")], isFiltered: false))
        XCTAssertEqual(state.recentRows.map(\.sessionID), ["s2"])
        XCTAssertEqual(state.runningRows.map(\.sessionID), ["s1"])
    }

    /// A selected History row whose conversation starts running in an
    /// undrivable terminal (e.g. after Resume) keeps the selection on the
    /// `process:` Running row with the same session_id (§4.5 "row
    /// selection").
    func testSelectionMovesFromHistoryToTheProcessRow() {
        var state = UnifiedListState(home: home, now: 100)
        _ = state.handle(.historyDelivered([summary("s1"), summary("s2")], isFiltered: false))
        _ = state.handle(.rowClicked(.conversation(sessionID: "s1")))
        XCTAssertEqual(state.selection?.key, .conversation(sessionID: "s1"))
        _ = state.handle(.agentsUpdated([agent("process:4242", session: "s1")]))
        XCTAssertEqual(state.selection, RowSelection(key: .running(target: "process:4242"), sessionID: "s1"))
    }

    /// An archived conversation that is running in an undrivable terminal
    /// leaves the archived list (§4.6 "Archive": automatic unarchive).
    func testProcessRowUnarchivesItsConversation() {
        var state = UnifiedListState(home: home, now: 100, archived: ArchivedList(["s1", "s2"]))
        _ = state.handle(.historyDelivered([summary("s1"), summary("s2")], isFiltered: false))
        _ = state.handle(.agentsUpdated([agent("process:4242", session: "s1")]))
        XCTAssertEqual(state.archived.sessionIDs, ["s2"])
    }

    /// The `process:` row's session_id changes with a `status_changed` of
    /// the same target (a reconcile overwrite, a `/clear`): the row stays
    /// in place and stays selected, and the selection follows the new
    /// session_id.
    func testSessionIDChangeOnTheSameProcessTargetKeepsTheRowAndTheSelection() {
        var state = UnifiedListState(home: home, now: 100)
        let others = [
            agent("iterm2:w0t0p0:U1", session: "s0", createdAt: 3),
            agent("apple-terminal:/dev/ttys004", session: "s9", createdAt: 1),
        ]
        _ = state.handle(.agentsUpdated(others + [agent("process:4242", session: "s1", createdAt: 2)]))
        _ = state.handle(.historyDelivered([summary("s1", live: true)], isFiltered: false))
        _ = state.handle(.rowClicked(.running(target: "process:4242")))
        let order = state.runningRows.map(\.id)
        XCTAssertEqual(state.selection, RowSelection(key: .running(target: "process:4242"), sessionID: "s1"))

        _ = state.handle(.agentsUpdated(others + [agent("process:4242", session: "s5", createdAt: 2)]))
        XCTAssertEqual(state.runningRows.map(\.id), order, "the row does not move")
        XCTAssertEqual(state.selection, RowSelection(key: .running(target: "process:4242"), sessionID: "s5"))
        XCTAssertEqual(state.selectedRow?.sessionID, "s5")
    }
}
