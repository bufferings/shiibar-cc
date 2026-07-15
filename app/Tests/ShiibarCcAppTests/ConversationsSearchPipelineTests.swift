import ShiibarCcCore
import XCTest
@testable import ShiibarCcApp

/// The Conversations list-search pipeline (M39 T7): keystroke -> debounce ->
/// cancel -> subprocess -> result application, driven with a stubbed
/// launcher. Reproduction target: the owner's IME case — a query that jumps
/// several characters at once (composition commits) must always end with
/// the FINAL query's results on screen. CJK fixture text is written as
/// unicode escapes to keep the source ASCII (repo language rule).
@MainActor
final class ConversationsSearchPipelineTests: XCTestCase {
    /// One dispatched search the stub captured.
    private struct Dispatched {
        let arguments: [String]
        let completion: @MainActor (CLIRunResult) -> Void
    }

    private final class Stub {
        var dispatched: [Dispatched] = []
        /// `show` subprocess arguments the stub captured (auto-select-on-open
        /// drives a show exactly as a click does — §4.6/§8.46).
        var showArguments: [[String]] = []
        /// Captured index-on-open completions, so a test can finish the index
        /// (warm: exit 0, no progress) and let the post-index search run.
        var indexCompletions: [@MainActor (Int32) -> Void] = []
    }

    private var stub = Stub()

    private func makeViewModel() -> ConversationsViewModel {
        let viewModel = ConversationsViewModel(appState: nil)
        stub = Stub()
        viewModel.searchProcessLauncher = { [stub] arguments, _, completion in
            stub.dispatched.append(Dispatched(arguments: arguments, completion: completion))
            // An idle Process was never launched; cancel() is a safe no-op.
            return ConversationsProcess(process: Process())
        }
        viewModel.indexProcessLauncher = { [stub] _, _, _, completion in
            stub.indexCompletions.append(completion)
            return ConversationsProcess(process: Process())
        }
        viewModel.showProcessLauncher = { [stub] arguments, _, _ in
            // Capture the show fetch; never complete it — the tests assert on
            // selection, not on decoded detail (which would need a WebView).
            stub.showArguments.append(arguments)
            return ConversationsProcess(process: Process())
        }
        return viewModel
    }

    /// Drive a window open with a warm index (exit 0, no progress lines) so
    /// the post-index search dispatches, then return once it is captured.
    private func openWindowAndAwaitSearch(_ viewModel: ConversationsViewModel) {
        viewModel.windowOpened()
        XCTAssertEqual(stub.indexCompletions.count, 1, "open runs the index once")
        stub.indexCompletions[0](0)
        waitForDispatches(1)
    }

    private func resultJSON(_ sessionIDs: [String]) -> String {
        let rows = sessionIDs.map {
            #"{"session_id":"\#($0)","cwd":"/Users/example/demo","title":"title \#($0)","updated_at":1,"live":false}"#
        }
        return #"{"conversations":[\#(rows.joined(separator: ","))]}"#
    }

    /// Pump the run loop until the stub has `count` dispatches (debounce is
    /// 200ms real time) or the deadline passes.
    private func waitForDispatches(_ count: Int, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, stub.dispatched.count < count {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// "left-navi" in katakana, and its prefix steps as an IME would grow
    /// them (composition commits can change the query several characters at
    /// a time).
    private let steps = [
        "\u{30EC}",                                     // 1 char (browse — too short)
        "\u{30EC}\u{30D5}",                             // 2 chars
        "\u{30EC}\u{30D5}\u{30C8}",                     // "left"
        "\u{30EC}\u{30D5}\u{30C8}\u{30CA}",
        "\u{30EC}\u{30D5}\u{30C8}\u{30CA}\u{30D3}",     // "left-navi"
    ]
    private var finalQuery: String { steps[4] }

    // MARK: - Rapid IME-style transitions: exactly one dispatch, the final query

    func testRapidImeTransitionsDispatchOnlyTheFinalQuery() {
        let viewModel = makeViewModel()
        for step in steps {
            viewModel.query = step
            viewModel.queryChanged()
            viewModel.queryChangedForPreview()
        }
        waitForDispatches(1)
        XCTAssertEqual(stub.dispatched.count, 1, "rapid keystrokes inside the debounce collapse to one search")
        XCTAssertEqual(
            stub.dispatched.first?.arguments,
            ["conversations", "search", finalQuery, "--json"]
        )

        stub.dispatched[0].completion(CLIRunResult(exitCode: 0, stdout: resultJSON(["navi-hit"]), stderr: ""))
        XCTAssertEqual(viewModel.summaries.map(\.sessionID), ["navi-hit"],
                       "the final query's results must land")
        XCTAssertEqual(viewModel.statusText, "1 of 0 conversations")
    }

    // MARK: - Slow transitions with out-of-order completions: the stale
    // result must never overwrite the newest query's

    func testStaleResultArrivingLateNeverOverwritesTheNewestResult() {
        let viewModel = makeViewModel()
        viewModel.query = steps[2] // "left"
        viewModel.queryChanged()
        waitForDispatches(1)
        XCTAssertEqual(stub.dispatched.count, 1)

        viewModel.query = finalQuery // "left-navi"
        viewModel.queryChanged()
        waitForDispatches(2)
        XCTAssertEqual(stub.dispatched.count, 2)
        XCTAssertEqual(stub.dispatched[1].arguments[2], finalQuery)

        // The newest search completes first...
        stub.dispatched[1].completion(CLIRunResult(exitCode: 0, stdout: resultJSON(["navi-hit"]), stderr: ""))
        XCTAssertEqual(viewModel.summaries.map(\.sessionID), ["navi-hit"])
        // ...then the cancelled older search's completion arrives late,
        // successful and full of its own results.
        stub.dispatched[0].completion(CLIRunResult(exitCode: 0, stdout: resultJSON(["left-a", "left-b"]), stderr: ""))
        XCTAssertEqual(viewModel.summaries.map(\.sessionID), ["navi-hit"],
                       "a stale result must never overwrite the newest query's results")
    }

    // MARK: - A cancelled search's failure exit must not flag an error over
    // the newest results

    func testCancelledSearchFailureDoesNotDisturbTheNewestResults() {
        let viewModel = makeViewModel()
        viewModel.query = steps[2]
        viewModel.queryChanged()
        waitForDispatches(1)
        viewModel.query = finalQuery
        viewModel.queryChanged()
        waitForDispatches(2)

        stub.dispatched[1].completion(CLIRunResult(exitCode: 0, stdout: resultJSON(["navi-hit"]), stderr: ""))
        // SIGTERM'd predecessor reports failure late.
        stub.dispatched[0].completion(CLIRunResult(exitCode: 15, stdout: "", stderr: ""))
        XCTAssertEqual(viewModel.summaries.map(\.sessionID), ["navi-hit"])
        XCTAssertEqual(viewModel.statusText, "1 of 0 conversations", "no stale error may cover the counts")
    }

    // MARK: - The ⟳ minimum turn (§9/§8.43/§8.44): an instant result must not
    // end the in-flight look before one full 0.6s turn

    func testRefreshHoldsInFlightForTheMinimumTurnDespiteInstantResult() {
        let viewModel = makeViewModel()
        viewModel.refreshTapped()
        XCTAssertTrue(viewModel.isRefreshing)
        XCTAssertEqual(viewModel.statusText, "Refreshing\u{2026}")
        waitForDispatches(1)
        // The result lands within tens of milliseconds — like the real CLI.
        stub.dispatched[0].completion(CLIRunResult(exitCode: 0, stdout: resultJSON(["r1"]), stderr: ""))

        // The results apply immediately, but the in-flight state persists…
        XCTAssertEqual(viewModel.summaries.map(\.sessionID), ["r1"])
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(viewModel.isRefreshing, "the turn is not done at 0.3s")
        XCTAssertEqual(viewModel.statusText, "Refreshing\u{2026}")
        // …a re-click during the turn is ignored (no second dispatch)…
        viewModel.refreshTapped()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(stub.dispatched.count, 1, "a re-click during the turn must be ignored")

        // …and by 1.1s the button settles and the transient shows.
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline, viewModel.isRefreshing {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(viewModel.isRefreshing, "the run settles after the minimum turn")
        XCTAssertEqual(viewModel.statusText, "Updated \u{00B7} 1 conversations")
    }

    func testRefreshFailureAlsoSettlesOnlyAfterTheMinimumTurn() {
        let viewModel = makeViewModel()
        viewModel.refreshTapped()
        waitForDispatches(1)
        stub.dispatched[0].completion(CLIRunResult(exitCode: 1, stdout: "", stderr: ""))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(viewModel.isRefreshing, "even a failure keeps the turn visible")
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline, viewModel.isRefreshing {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(viewModel.isRefreshing)
        XCTAssertEqual(viewModel.statusText, "Search failed", "failure shows the error, no transient")
    }

    // MARK: - Auto-select on open (§4.6/§8.46)

    /// The first list delivery after the window opens selects the newest row
    /// (the list is always newest-first) and fetches its show, exactly as a
    /// click would.
    func testFirstDeliveryAfterOpenAutoSelectsTheNewest() {
        let viewModel = makeViewModel()
        openWindowAndAwaitSearch(viewModel)
        XCTAssertEqual(stub.dispatched.count, 1, "the post-index search dispatches once")
        stub.dispatched[0].completion(CLIRunResult(exitCode: 0, stdout: resultJSON(["newest", "older"]), stderr: ""))
        XCTAssertEqual(viewModel.selectedSessionID, "newest",
                       "the first list delivery after open auto-selects the newest row")
        XCTAssertEqual(stub.showArguments, [["conversations", "show", "newest", "--json"]],
                       "auto-select fetches the show exactly as a click does")
    }

    /// Zero conversations stays in the empty state — nothing is selected and
    /// no show is fetched.
    func testOpenWithZeroConversationsSelectsNothing() {
        let viewModel = makeViewModel()
        openWindowAndAwaitSearch(viewModel)
        stub.dispatched[0].completion(CLIRunResult(exitCode: 0, stdout: #"{"conversations":[]}"#, stderr: ""))
        XCTAssertNil(viewModel.selectedSessionID, "an empty list selects nothing")
        XCTAssertTrue(stub.showArguments.isEmpty, "no show is fetched for an empty list")
        XCTAssertEqual(viewModel.statusText, "0 conversations (0 running)")
    }

    /// A later delivery must NOT auto-select after the existing rule cleared
    /// the preview because the selection dropped out of the results: the open
    /// already spent the single auto-select trigger.
    func testLaterSearchDeliveryDoesNotAutoSelectAfterDropOutClear() {
        let viewModel = makeViewModel()
        openWindowAndAwaitSearch(viewModel)
        stub.dispatched[0].completion(CLIRunResult(exitCode: 0, stdout: resultJSON(["sel"]), stderr: ""))
        XCTAssertEqual(viewModel.selectedSessionID, "sel")
        XCTAssertEqual(stub.showArguments.count, 1)

        // The user types; the new search's results drop the selected id.
        viewModel.query = "zz"
        viewModel.queryChanged()
        waitForDispatches(2)
        stub.dispatched[1].completion(CLIRunResult(exitCode: 0, stdout: resultJSON(["other"]), stderr: ""))
        XCTAssertNil(viewModel.selectedSessionID,
                     "drop-out clears the preview and nothing is re-selected (§8.46)")
        XCTAssertEqual(stub.showArguments.count, 1, "no auto-select show on a keystroke delivery")
    }

    /// Reopening with a selection still held keeps it — auto-select only fires
    /// when nothing is selected, so the reopen delivery re-selects nothing.
    func testHeldSelectionSurvivesReopenWithoutReselect() {
        let viewModel = makeViewModel()
        openWindowAndAwaitSearch(viewModel)
        stub.dispatched[0].completion(CLIRunResult(exitCode: 0, stdout: resultJSON(["sel", "older"]), stderr: ""))
        XCTAssertEqual(viewModel.selectedSessionID, "sel")
        XCTAssertEqual(stub.showArguments.count, 1)

        // Close and reopen with the selection still held; the id is still in
        // the results, so it is neither cleared nor re-selected.
        viewModel.windowClosed()
        viewModel.windowOpened()
        XCTAssertEqual(stub.indexCompletions.count, 2, "reopen runs the index again")
        stub.indexCompletions[1](0)
        waitForDispatches(2)
        stub.dispatched[1].completion(CLIRunResult(exitCode: 0, stdout: resultJSON(["sel", "older"]), stderr: ""))
        XCTAssertEqual(viewModel.selectedSessionID, "sel", "a held selection survives reopen")
        XCTAssertEqual(stub.showArguments.count, 1, "no re-select show fires on reopen")
    }

    // MARK: - In-body hits for the same query over rendered text

    func testInBodyHitsFindTheImeQueryInRenderedText() {
        // The right-pane half of the reported miss: the term must be found
        // in the rendered text exactly as displayed.
        let rendered = RenderedMessage(role: "assistant", text: "see \u{30EC}\u{30D5}\u{30C8}\u{30CA}\u{30D3} here")
        let hits = ConversationHits.locations(messageTexts: [rendered.renderedText], terms: [finalQuery])
        XCTAssertEqual(hits, [ConversationHit(messageIndex: 0, start: 4, length: 5)])
    }
}
