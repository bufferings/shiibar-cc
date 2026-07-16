import ShiibarCcCore
import XCTest
@testable import ShiibarCcApp

/// The Conversations bottom-panel Jump behavior (M41 T2, DESIGN.md
/// §4.6/§8.48): derivation happens only at selection and list delivery (a live
/// agent change alone never moves the button), Jump focuses the derived target
/// through the shared row-click path, and only a focus exit 2 requests the
/// no-match sheet — whose Refresh re-runs the search exactly like ⟳ while
/// Cancel does nothing. Driven with stubbed launchers and an injected agent
/// snapshot — no real subprocess, osascript, or NSAlert.
@MainActor
final class ConversationsJumpTests: XCTestCase {
    private struct Dispatched {
        let arguments: [String]
        let completion: @MainActor (CLIRunResult) -> Void
    }

    private final class Stub {
        var dispatched: [Dispatched] = []
        var showArguments: [[String]] = []
        var indexCompletions: [@MainActor (Int32) -> Void] = []
        /// (target, completion) for each focus the Jump requested.
        var focusCalls: [(target: String, completion: @MainActor (Int32) -> Void)] = []
        /// The agent list the view model reads at derivation time — mutable so
        /// a test can change it BETWEEN derivations.
        var agents: [Agent] = []
    }

    private var stub = Stub()

    private func makeViewModel() -> ConversationsViewModel {
        let viewModel = ConversationsViewModel(appState: nil)
        stub = Stub()
        viewModel.searchProcessLauncher = { [stub] arguments, _, completion in
            stub.dispatched.append(Dispatched(arguments: arguments, completion: completion))
            return ConversationsProcess(process: Process())
        }
        viewModel.indexProcessLauncher = { [stub] _, _, _, completion in
            stub.indexCompletions.append(completion)
            return ConversationsProcess(process: Process())
        }
        viewModel.showProcessLauncher = { [stub] arguments, _, _ in
            stub.showArguments.append(arguments)
            return ConversationsProcess(process: Process())
        }
        viewModel.agentsSnapshot = { [stub] in stub.agents }
        viewModel.focusAction = { [stub] target, completion in
            stub.focusCalls.append((target: target, completion: completion))
        }
        return viewModel
    }

    private func agent(sessionID: String, target: String) -> Agent {
        Agent(
            target: target,
            status: .idle,
            unreviewed: false,
            sessionId: sessionID,
            cwd: "/Users/example/demo",
            task: nil,
            message: nil,
            since: 0,
            lastSeen: 0
        )
    }

    private func summaryJSON(_ id: String, live: Bool) -> String {
        #"{"session_id":"\#(id)","cwd":"/Users/example/demo","title":"t \#(id)","updated_at":1,"live":\#(live)}"#
    }

    private func listJSON(_ rows: [(id: String, live: Bool)]) -> String {
        let joined = rows.map { summaryJSON($0.id, live: $0.live) }.joined(separator: ",")
        return #"{"conversations":[\#(joined)]}"#
    }

    private func waitForDispatches(_ count: Int, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, stub.dispatched.count < count {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// Open with a warm index and deliver `rows` as the first list; returns
    /// once the delivery has been applied. Auto-select picks the newest (first)
    /// row (§8.46), which derives its verb.
    private func openAndDeliver(_ viewModel: ConversationsViewModel, _ rows: [(id: String, live: Bool)]) {
        viewModel.windowOpened()
        XCTAssertEqual(stub.indexCompletions.count, 1)
        stub.indexCompletions[0](0)
        waitForDispatches(1)
        stub.dispatched[0].completion(CLIRunResult(exitCode: 0, stdout: listJSON(rows), stderr: ""))
    }

    // MARK: - Derivation timing (§4.6/§8.48)

    /// A live agent change alone must NOT re-derive the displayed verb: the
    /// value is snapshotted at selection/delivery and held.
    func testAgentsChangeAloneDoesNotAlterDisplayedAction() {
        let viewModel = makeViewModel()
        stub.agents = [agent(sessionID: "live1", target: "iterm2:TAB")]
        openAndDeliver(viewModel, [(id: "live1", live: true), (id: "past1", live: false)])
        // Auto-select took the newest row (live1) and derived Jump.
        XCTAssertEqual(viewModel.selectedSessionID, "live1")
        XCTAssertEqual(viewModel.selectedAction, .jump(target: "iterm2:TAB"))

        // The agent list changes underneath (the match disappears) — but no
        // selection or delivery happens, so the held verb must not move.
        stub.agents = []
        XCTAssertEqual(
            viewModel.selectedAction, .jump(target: "iterm2:TAB"),
            "a live agent change alone must not re-derive the button (§8.48)"
        )
    }

    /// Changing the selected row re-derives from the current snapshot.
    func testSelectionChangeReDerives() {
        let viewModel = makeViewModel()
        stub.agents = [agent(sessionID: "live1", target: "iterm2:TAB")]
        openAndDeliver(viewModel, [(id: "live1", live: true), (id: "past1", live: false)])
        XCTAssertEqual(viewModel.selectedAction, .jump(target: "iterm2:TAB"))

        let past = try! XCTUnwrap(viewModel.summaries.first { $0.sessionID == "past1" })
        viewModel.selectConversation(past)
        XCTAssertEqual(viewModel.selectedAction, .resume, "selecting a past row re-derives to Resume")
    }

    /// A list delivery re-derives a KEPT selection: the same conversation
    /// flips running -> past, and the held verb follows the delivered list —
    /// not the (still-matching) agent snapshot.
    func testListDeliveryReDerives() {
        let viewModel = makeViewModel()
        stub.agents = [agent(sessionID: "live1", target: "iterm2:TAB")]
        openAndDeliver(viewModel, [(id: "live1", live: true)])
        XCTAssertEqual(viewModel.selectedAction, .jump(target: "iterm2:TAB"))

        // A ⟳ re-run delivers live1 now as a past row. The agent entry still
        // matches, but the delivered row is authoritative.
        viewModel.refreshTapped()
        waitForDispatches(2)
        stub.dispatched[1].completion(CLIRunResult(exitCode: 0, stdout: listJSON([(id: "live1", live: false)]), stderr: ""))
        XCTAssertEqual(viewModel.selectedSessionID, "live1", "the selection is kept")
        XCTAssertEqual(viewModel.selectedAction, .resume, "list delivery re-derives to Resume")
    }

    // MARK: - Jump focuses the derived target (§4.6/§8.48)

    func testJumpPassesTheDerivedTargetToFocus() {
        let viewModel = makeViewModel()
        stub.agents = [agent(sessionID: "live1", target: "iterm2:TAB-42")]
        openAndDeliver(viewModel, [(id: "live1", live: true)])
        XCTAssertEqual(viewModel.selectedAction, .jump(target: "iterm2:TAB-42"))

        viewModel.jump()
        XCTAssertEqual(stub.focusCalls.map(\.target), ["iterm2:TAB-42"],
                       "Jump focuses the target derived at selection time")
        // Jump never re-runs the search (§8.48): only the index+first search
        // ran, no third dispatch.
        XCTAssertEqual(stub.dispatched.count, 1, "a Jump does not re-run the search")
    }

    func testDisabledJumpDoesNotFocus() {
        let viewModel = makeViewModel()
        stub.agents = [] // no match for the live row
        openAndDeliver(viewModel, [(id: "live1", live: true)])
        XCTAssertEqual(viewModel.selectedAction, .jumpDisabled)

        viewModel.jump()
        XCTAssertTrue(stub.focusCalls.isEmpty, "a disabled Jump focuses nothing")
    }

    // MARK: - The no-match sheet is requested only on exit 2 (§4.6/§8.48)

    func testSheetRequestedOnlyOnFocusExit2() {
        for code: Int32 in [0, 1, 2, 3] {
            let viewModel = makeViewModel()
            stub.agents = [agent(sessionID: "live1", target: "iterm2:TAB")]
            openAndDeliver(viewModel, [(id: "live1", live: true)])
            viewModel.jump()
            XCTAssertEqual(stub.focusCalls.count, 1)
            stub.focusCalls[0].completion(code)
            XCTAssertEqual(
                viewModel.jumpFailureAlertRequested, code == 2,
                "the sheet is requested only on exit 2 (got exit \(code))"
            )
        }
    }

    // MARK: - Sheet response wiring (§4.6/§8.48)

    /// Refresh on the sheet re-runs the search exactly like the ⟳ button (same
    /// path), and Cancel touches nothing.
    func testRefreshChosenReRunsSearchAndCancelDoesNothing() {
        let viewModel = makeViewModel()
        stub.agents = [agent(sessionID: "live1", target: "iterm2:TAB")]
        openAndDeliver(viewModel, [(id: "live1", live: true)])
        let before = stub.dispatched.count

        // Cancel: no new search.
        viewModel.jumpFailureCancelChosen()
        XCTAssertEqual(stub.dispatched.count, before, "Cancel must not re-run the search")

        // Refresh: the same search re-run as ⟳ (a fresh dispatch, and the
        // in-flight refresh state the ⟳ button raises).
        viewModel.jumpFailureRefreshChosen()
        XCTAssertTrue(viewModel.isRefreshing, "Refresh uses the ⟳ path (raises the in-flight state)")
        waitForDispatches(before + 1)
        XCTAssertEqual(stub.dispatched.count, before + 1, "Refresh re-runs the search")
    }
}
