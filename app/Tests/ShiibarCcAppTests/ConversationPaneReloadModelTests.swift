import ShiibarCcCore
import XCTest
@testable import ShiibarCcApp

/// The conversation pane reload through the shared model (DESIGN.md §4.6
/// "conversation pane" / "conversation pane reload", §8.65, §9): the three
/// triggers, the procedures (index then show; search then show), the
/// follow-up reload, the collapsing of triggers, and how a result is
/// applied. Every subprocess is a spy that never runs; the scheduler and the
/// clock are injected; defaults are in memory.
@MainActor
final class ConversationPaneReloadModelTests: XCTestCase {
    private struct OneShot {
        let arguments: [String]
        let completion: @MainActor (CLIRunResult) -> Void
    }

    private struct IndexRun {
        let arguments: [String]
        let onLine: @MainActor (String) -> Void
        let completion: @MainActor (Int32) -> Void
        let process: ConversationsProcess
    }

    private final class Spy {
        var searches: [OneShot] = []
        var shows: [OneShot] = []
        /// The index on open / on key (`--json`).
        var openIndexes: [IndexRun] = []
        /// The conversation pane's own index runs.
        var paneIndexes: [IndexRun] = []
        var scheduled: [(seconds: Double, action: @MainActor () -> Void)] = []
    }

    private var spy = Spy()
    private var defaults = InMemoryDefaults()
    private let now: Int64 = 10_000
    private let target = "iterm2:T1"

    override func setUp() {
        super.setUp()
        defaults = InMemoryDefaults()
    }

    private func makeModel() -> MainSurfaceModel {
        spy = Spy()
        let spy = self.spy
        let launchers = ConversationsLaunchers(
            search: { arguments, _, completion in
                spy.searches.append(OneShot(arguments: arguments, completion: completion))
                return ConversationsProcess(process: Process())
            },
            show: { arguments, _, completion in
                spy.shows.append(OneShot(arguments: arguments, completion: completion))
                return ConversationsProcess(process: Process())
            },
            index: { arguments, _, onLine, completion in
                let run = IndexRun(arguments: arguments, onLine: onLine, completion: completion,
                                   process: ConversationsProcess(process: Process()))
                if arguments.contains("--json") {
                    spy.openIndexes.append(run)
                } else {
                    spy.paneIndexes.append(run)
                }
                return run.process
            }
        )
        let fixedNow = TimeInterval(now)
        return MainSurfaceModel(
            home: "/Users/example",
            defaults: defaults,
            textSize: TextSizeStore(defaults: defaults),
            launchers: launchers,
            runCommand: { _, _ in },
            clock: { Date(timeIntervalSince1970: fixedNow) },
            schedule: { seconds, action in spy.scheduled.append((seconds: seconds, action: action)) },
            markReadSchedule: { _, _ in }
        )
    }

    // MARK: - Fixtures

    private func ok(_ stdout: String) -> CLIRunResult { CLIRunResult(exitCode: 0, stdout: stdout, stderr: "") }
    private func exit(_ code: Int32) -> CLIRunResult { CLIRunResult(exitCode: code, stdout: "", stderr: "") }

    private func resultJSON(_ ids: [String], updatedAt: Int64 = 1) -> String {
        let items = ids.map {
            #"{"session_id":"\#($0)","cwd":"/Users/example/demo","title":"t","updated_at":\#(updatedAt),"live":false,"last_prompt":null}"#
        }
        return #"{"conversations":[\#(items.joined(separator: ","))]}"#
    }

    /// A `show --json` payload; messages alternate user / assistant from
    /// seq 0. `updatedAt` nil omits the field.
    private func showJSON(_ id: String, texts: [String], updatedAt: Int64? = 9_000) -> String {
        let messages = texts.enumerated().map { index, text in
            #"{"seq":\#(index),"role":"\#(index % 2 == 0 ? "user" : "assistant")","text":"\#(text)"}"#
        }
        let updated = updatedAt.map { #""updated_at":\#($0),"# } ?? ""
        return #"{"session_id":"\#(id)","cwd":"/Users/example/demo","title":"t",\#(updated)"messages":[\#(messages.joined(separator: ","))]}"#
    }

    private func agent(_ status: AgentStatus, session: String = "s1", unreviewed: Bool = false,
                       task: String? = nil) -> Agent {
        Agent(target: target, status: status, unreviewed: unreviewed, sessionId: session,
              cwd: "/Users/example/demo", task: task, message: nil, createdAt: 1, since: 0, lastSeen: 0)
    }

    /// The window in two columns with `agents` running and `ids` as History
    /// (the open index and its search completed).
    private func openWindow(_ model: MainSurfaceModel, agents: [Agent] = [], delivering ids: [String] = ["a"]) {
        model.agentsUpdated(agents)
        model.windowColumnsChanged(.two)
        model.windowDidBecomeKey()
        XCTAssertEqual(model.visibleSurface, .window)
        spy.openIndexes.last?.completion(0)
        spy.searches.last?.completion(ok(resultJSON(ids)))
    }

    /// The Running row selected and its first load (index, show) done.
    private func showRunningRow(_ model: MainSurfaceModel, texts: [String] = ["hello", "hi"]) {
        openWindow(model, agents: [agent(.idle)])
        model.rowClicked(.running(target: target))
        spy.paneIndexes.last?.completion(0)
        spy.shows.last?.completion(ok(showJSON("s1", texts: texts)))
        XCTAssertEqual(model.lastPaneRender, .load)
    }

    private var scheduledFollowUps: Int {
        spy.scheduled.filter { $0.seconds == ConversationPaneReload.followUpSeconds }.count
    }

    // MARK: - Trigger 1: index, then show

    func testAStatusChangeRunsIndexThenShowAndNoSearch() {
        let model = makeModel()
        showRunningRow(model)
        let searches = spy.searches.count
        model.agentsUpdated([agent(.working)])
        XCTAssertEqual(spy.paneIndexes.count, 2)
        XCTAssertEqual(spy.paneIndexes[1].arguments, ["conversations", "index"])
        XCTAssertEqual(spy.shows.count, 1, "show waits for the index")
        spy.paneIndexes[1].completion(1)
        XCTAssertEqual(spy.shows.count, 2, "show runs whatever the index's exit code")
        XCTAssertEqual(spy.shows[1].arguments, ["conversations", "show", "s1", "--json"])
        XCTAssertEqual(spy.searches.count, searches, "no search")
    }

    func testOnlyAStatusChangeIsATrigger() {
        let model = makeModel()
        showRunningRow(model)
        model.agentsUpdated([agent(.idle, unreviewed: true)])
        model.agentsUpdated([agent(.idle, unreviewed: true, task: "another task")])
        XCTAssertEqual(spy.paneIndexes.count, 1, "unreviewed and other fields alone are no trigger")
    }

    func testThePaneIndexAndTheOpenIndexNeverCancelEachOther() {
        let model = makeModel()
        model.agentsUpdated([agent(.idle)])
        model.windowColumnsChanged(.two)
        model.windowDidBecomeKey()
        // The open index is still running when the Running row is selected.
        model.rowClicked(.running(target: target))
        XCTAssertEqual(spy.paneIndexes.count, 1)
        XCTAssertFalse(spy.openIndexes[0].process.wasCancelled, "the pane's index leaves the open index alone")
        spy.paneIndexes[0].completion(0)
        spy.shows.last?.completion(ok(showJSON("s1", texts: ["hello"])))

        model.agentsUpdated([agent(.working)])
        XCTAssertEqual(spy.paneIndexes.count, 2)
        XCTAssertFalse(spy.openIndexes[0].process.wasCancelled)
        model.windowDidBecomeKey()
        XCTAssertEqual(spy.openIndexes.count, 2)
        XCTAssertFalse(spy.paneIndexes[1].process.wasCancelled, "the open index leaves the pane's index alone")
    }

    func testThePaneIndexOutputChangesNoListState() {
        let model = makeModel()
        showRunningRow(model)
        XCTAssertNil(model.messageText)
        model.agentsUpdated([agent(.working)])
        let run = spy.paneIndexes[1]
        run.onLine(#"{"event":"start","total":120,"full_build":true}"#)
        run.onLine(#"{"event":"progress","done":60,"total":120}"#)
        run.onLine(#"{"event":"error","message":"boom"}"#)
        XCTAssertNil(model.messageText, "no Indexing N of M")
        XCTAssertFalse(model.list.isFullBuild, "the search field stays enabled")
        run.completion(1)
        XCTAssertNil(model.messageText, "no Indexing failed")
        XCTAssertNil(model.messageError)
        XCTAssertFalse(model.list.isFullBuild)
        XCTAssertEqual(model.list.recentRows.map(\.sessionID), ["a"], "History stays")
    }

    func testAStatusChangeWhileNoSurfaceIsShownRunsNothing() {
        let model = makeModel()
        showRunningRow(model)
        model.surfaceDidHide(.window)
        model.agentsUpdated([agent(.working)])
        XCTAssertEqual(spy.paneIndexes.count, 1)
        XCTAssertEqual(spy.shows.count, 1)
    }

    // MARK: - The follow-up reload after trigger 1

    /// Run trigger 1 to completion and return the index of its follow-up
    /// in `spy.scheduled`.
    private func completeStatusChangeReload(_ model: MainSurfaceModel, to status: AgentStatus = .working) -> Int {
        let follow = scheduledFollowUps
        model.agentsUpdated([agent(status)])
        spy.paneIndexes.last?.completion(0)
        spy.shows.last?.completion(ok(showJSON("s1", texts: ["hello", "hi"])))
        XCTAssertEqual(scheduledFollowUps, follow + 1, "the follow-up is scheduled after the reload completed")
        return spy.scheduled.lastIndex { $0.seconds == ConversationPaneReload.followUpSeconds } ?? -1
    }

    func testTheFollowUpRunsOnceAfterTheDelay() {
        let model = makeModel()
        showRunningRow(model)
        let followUp = completeStatusChangeReload(model)
        XCTAssertEqual(spy.scheduled[followUp].seconds, 2)
        let indexes = spy.paneIndexes.count
        spy.scheduled[followUp].action()
        XCTAssertEqual(spy.paneIndexes.count, indexes + 1, "the follow-up: index")
        spy.paneIndexes.last?.completion(0)
        XCTAssertEqual(spy.shows.last?.arguments, ["conversations", "show", "s1", "--json"])
        let follow = scheduledFollowUps
        spy.shows.last?.completion(ok(showJSON("s1", texts: ["hello", "hi"])))
        XCTAssertEqual(scheduledFollowUps, follow, "no further follow-up after the follow-up")
    }

    func testTheFollowUpDoesNotRunAfterAnotherReloadStarted() {
        let model = makeModel()
        showRunningRow(model)
        let followUp = completeStatusChangeReload(model)
        model.refresh()
        spy.searches.last?.completion(ok(resultJSON(["a"])))
        spy.shows.last?.completion(ok(showJSON("s1", texts: ["hello", "hi"])))
        let indexes = spy.paneIndexes.count
        let shows = spy.shows.count
        spy.scheduled[followUp].action()
        XCTAssertEqual(spy.paneIndexes.count, indexes)
        XCTAssertEqual(spy.shows.count, shows)
    }

    func testTheFollowUpDoesNotRunAfterTheConversationChanged() {
        let model = makeModel()
        showRunningRow(model)
        let followUp = completeStatusChangeReload(model)
        model.rowClicked(.conversation(sessionID: "a"))
        let indexes = spy.paneIndexes.count
        let shows = spy.shows.count
        spy.scheduled[followUp].action()
        XCTAssertEqual(spy.paneIndexes.count, indexes)
        XCTAssertEqual(spy.shows.count, shows)
    }

    func testTheFollowUpDoesNotRunWhileNoSurfaceIsShown() {
        let model = makeModel()
        showRunningRow(model)
        let followUp = completeStatusChangeReload(model)
        model.surfaceDidHide(.window)
        let indexes = spy.paneIndexes.count
        spy.scheduled[followUp].action()
        XCTAssertEqual(spy.paneIndexes.count, indexes)
    }

    // MARK: - The first load of a conversation

    func testARunningRowsFirstLoadRunsIndexThenShow() {
        let model = makeModel()
        openWindow(model, agents: [agent(.idle)])
        model.rowClicked(.running(target: target))
        XCTAssertEqual(spy.paneIndexes.map(\.arguments), [["conversations", "index"]])
        XCTAssertTrue(spy.shows.isEmpty)
        spy.paneIndexes[0].completion(1)
        XCTAssertEqual(spy.shows.map(\.arguments), [["conversations", "show", "s1", "--json"]])
    }

    func testAHistoryRowsFirstLoadRunsShowOnly() {
        let model = makeModel()
        openWindow(model, delivering: ["a"])
        model.rowClicked(.conversation(sessionID: "a"))
        XCTAssertTrue(spy.paneIndexes.isEmpty)
        XCTAssertEqual(spy.shows.map(\.arguments), [["conversations", "show", "a", "--json"]])
    }

    func testAnArchiveViewRowsFirstLoadRunsShowOnly() {
        defaults.set(["a"], forKey: MainSurfaceDefaultsKeys.archivedSessionList)
        let model = makeModel()
        openWindow(model, delivering: ["a", "b"])
        model.archivedMenuItemChosen()
        model.rowClicked(.conversation(sessionID: "a"))
        XCTAssertTrue(spy.paneIndexes.isEmpty)
        XCTAssertEqual(spy.shows.map(\.arguments), [["conversations", "show", "a", "--json"]])
    }

    // MARK: - Triggers 2 and 3: the search, then show

    func testShowingTheWindowAgainReloadsARunningRowAfterItsSearch() {
        let model = makeModel()
        showRunningRow(model)
        model.windowDidBecomeKey()
        XCTAssertEqual(spy.shows.count, 1)
        spy.openIndexes.last?.completion(0)
        XCTAssertEqual(spy.shows.count, 1, "not before the search result")
        spy.searches.last?.completion(ok(resultJSON(["a"])))
        XCTAssertEqual(spy.shows.count, 2)
        XCTAssertEqual(spy.shows[1].arguments, ["conversations", "show", "s1", "--json"])
        XCTAssertEqual(spy.paneIndexes.count, 1, "the search caught the index up")
    }

    func testShowingThePopoverReloadsARunningRowAfterItsSearchFailure() {
        let model = makeModel()
        showRunningRow(model)
        model.surfaceDidHide(.window)
        model.windowColumnsChanged(.two)
        model.surfaceDidShow(.window)
        spy.openIndexes.last?.completion(0)
        spy.searches.last?.completion(exit(1))
        XCTAssertEqual(spy.shows.count, 2, "a failed search also stands for the trigger's search")
    }

    func testShowFollowsTheIndexWhenTheSurfaceShownIndexFails() {
        let model = makeModel()
        showRunningRow(model)
        let searches = spy.searches.count
        model.windowDidBecomeKey()
        spy.openIndexes.last?.completion(1)
        XCTAssertEqual(spy.searches.count, searches, "a failed open index runs no search")
        XCTAssertEqual(spy.shows.count, 2, "show follows the index")
    }

    func testShowingTheWindowAgainDoesNotReloadAHistoryRow() {
        let model = makeModel()
        openWindow(model, delivering: ["a"])
        model.rowClicked(.conversation(sessionID: "a"))
        spy.shows[0].completion(ok(showJSON("a", texts: ["hello"])))
        model.windowDidBecomeKey()
        spy.openIndexes.last?.completion(0)
        spy.searches.last?.completion(ok(resultJSON(["a"])))
        XCTAssertEqual(spy.shows.count, 1)
    }

    func testRefreshReloadsARunningRowAfterItsSearch() {
        let model = makeModel()
        showRunningRow(model)
        model.refresh()
        XCTAssertEqual(spy.shows.count, 1)
        spy.searches.last?.completion(exit(1))
        XCTAssertEqual(spy.shows.count, 2, "after the search, failed or not")
    }

    func testRefreshReloadsAHistoryRowAndAnArchiveViewRow() {
        defaults.set(["b"], forKey: MainSurfaceDefaultsKeys.archivedSessionList)
        let model = makeModel()
        openWindow(model, delivering: ["a", "b"])
        model.rowClicked(.conversation(sessionID: "a"))
        spy.shows[0].completion(ok(showJSON("a", texts: ["hello"])))
        model.refresh()
        spy.searches.last?.completion(ok(resultJSON(["a", "b"])))
        XCTAssertEqual(spy.shows.map(\.arguments).last, ["conversations", "show", "a", "--json"])
        XCTAssertEqual(spy.shows.count, 2)
        spy.shows[1].completion(ok(showJSON("a", texts: ["hello"])))
        // Refresh needs its reconcile to finish before the next one; start
        // over with a fresh model for the Archive view.
        let archived = makeModel()
        openWindow(archived, delivering: ["a", "b"])
        archived.archivedMenuItemChosen()
        archived.rowClicked(.conversation(sessionID: "b"))
        spy.shows[0].completion(ok(showJSON("b", texts: ["hello"])))
        archived.refresh()
        spy.searches.last?.completion(ok(resultJSON(["a", "b"])))
        XCTAssertEqual(spy.shows.count, 2)
        XCTAssertEqual(spy.shows[1].arguments, ["conversations", "show", "b", "--json"])
    }

    func testAReplacingSearchStandsForTheTriggersSearch() {
        let model = makeModel()
        showRunningRow(model)
        model.refresh()
        let refreshSearch = spy.searches.count
        // A one-character query browses, so the Running row stays listed.
        model.query = "n"
        pump { spy.searches.count > refreshSearch }
        XCTAssertEqual(spy.searches.count, refreshSearch + 1, "typing replaced Refresh's search")
        spy.searches.last?.completion(ok(resultJSON(["a"])))
        XCTAssertEqual(spy.shows.count, 2, "show follows the first result received")
    }

    // MARK: - Collapsing triggers

    func testTriggersDuringAStatusChangeReloadCollapseIntoOneRerun() {
        let model = makeModel()
        showRunningRow(model)
        model.agentsUpdated([agent(.working)])
        XCTAssertEqual(spy.paneIndexes.count, 2)
        // While the index runs: another status change and Refresh.
        model.agentsUpdated([agent(.waiting)])
        model.refresh()
        spy.searches.last?.completion(ok(resultJSON(["a"])))
        XCTAssertEqual(spy.paneIndexes.count, 2)
        XCTAssertEqual(spy.shows.count, 1)
        spy.paneIndexes[1].completion(0)
        XCTAssertEqual(spy.shows.count, 2)
        // While show runs: one more status change.
        model.agentsUpdated([agent(.working)])
        XCTAssertEqual(spy.paneIndexes.count, 2)
        spy.shows[1].completion(ok(showJSON("s1", texts: ["hello", "hi"])))
        XCTAssertEqual(spy.paneIndexes.count, 3, "one rerun, index first")
        XCTAssertEqual(spy.shows.count, 2)
        spy.paneIndexes[2].completion(0)
        XCTAssertEqual(spy.shows.count, 3)
        spy.shows[2].completion(ok(showJSON("s1", texts: ["hello", "hi"])))
        XCTAssertEqual(spy.paneIndexes.count, 3, "only one rerun")
    }

    /// §4.6: a status-change reload merged with other triggers still gets
    /// its follow-up, after the merged reload completes — whether the status
    /// change was the completed load or one of the merged triggers.
    func testAStatusChangeMergedWithOtherTriggersSchedulesTheFollowUpAfterTheRerun() {
        // The completed load was the status change; only Refresh arrived
        // during it.
        let model = makeModel()
        showRunningRow(model)
        model.agentsUpdated([agent(.working)])
        model.refresh()
        spy.searches.last?.completion(ok(resultJSON(["a"])))
        spy.paneIndexes[1].completion(0)
        spy.shows[1].completion(ok(showJSON("s1", texts: ["hello", "hi"])))
        XCTAssertEqual(scheduledFollowUps, 0, "not yet: the rerun is in flight")
        XCTAssertEqual(spy.paneIndexes.count, 3)
        spy.paneIndexes[2].completion(0)
        spy.shows[2].completion(ok(showJSON("s1", texts: ["hello", "hi"])))
        XCTAssertEqual(scheduledFollowUps, 1, "after the merged reload completed")

        // The status change was merged into a Refresh reload.
        let other = makeModel()
        showRunningRow(other)
        other.refresh()
        other.agentsUpdated([agent(.working)])
        spy.searches.last?.completion(ok(resultJSON(["a"])))
        spy.shows[1].completion(ok(showJSON("s1", texts: ["hello", "hi"])))
        XCTAssertEqual(scheduledFollowUps, 0)
        spy.paneIndexes[1].completion(0)
        spy.shows[2].completion(ok(showJSON("s1", texts: ["hello", "hi"])))
        XCTAssertEqual(scheduledFollowUps, 1)
    }

    func testTriggersDuringARefreshReloadRerunWithIndexThenShow() {
        let model = makeModel()
        showRunningRow(model)
        model.refresh()
        // While Refresh's search is pending: two status changes.
        model.agentsUpdated([agent(.working)])
        model.agentsUpdated([agent(.idle)])
        XCTAssertEqual(spy.paneIndexes.count, 1, "collapsed while waiting for the search")
        spy.searches.last?.completion(ok(resultJSON(["a"])))
        XCTAssertEqual(spy.shows.count, 2)
        spy.shows[1].completion(ok(showJSON("s1", texts: ["hello", "hi"])))
        XCTAssertEqual(spy.paneIndexes.count, 2, "the rerun runs the index")
        XCTAssertEqual(spy.shows.count, 2)
        spy.paneIndexes[1].completion(0)
        XCTAssertEqual(spy.shows.count, 3)
    }

    func testATriggerDuringTheFirstLoadRunsAfterIt() {
        let model = makeModel()
        openWindow(model, agents: [agent(.idle)])
        model.rowClicked(.running(target: target))
        model.agentsUpdated([agent(.working)])
        XCTAssertEqual(spy.paneIndexes.count, 1, "the first load is not cancelled")
        XCTAssertFalse(spy.paneIndexes[0].process.wasCancelled)
        spy.paneIndexes[0].completion(0)
        spy.shows[0].completion(ok(showJSON("s1", texts: ["hello"])))
        XCTAssertEqual(model.lastPaneRender, .load)
        XCTAssertEqual(spy.paneIndexes.count, 2, "the trigger runs after the first load")
        spy.paneIndexes[1].completion(0)
        XCTAssertEqual(spy.shows.count, 2)
    }

    func testAResultArrivingAfterTheConversationChangedIsDropped() {
        let model = makeModel()
        showRunningRow(model)
        model.agentsUpdated([agent(.working)])
        spy.paneIndexes[1].completion(0)
        model.rowClicked(.conversation(sessionID: "a"))
        // The stale reload result: as the History row's show, exit 2 would
        // be the one-line error.
        spy.shows[1].completion(exit(2))
        XCTAssertNil(model.paneLoadError)
        XCTAssertEqual(spy.shows.count, 3)
        spy.shows[2].completion(ok(showJSON("a", texts: ["other"])))
        XCTAssertEqual(model.lastPaneRender, .load)
        XCTAssertEqual(spy.paneIndexes.count, 2, "nothing reruns for the dropped result")
    }

    func testARowWithoutASessionIDNeverReloads() {
        let model = makeModel()
        openWindow(model, agents: [agent(.idle, session: "")])
        model.rowClicked(.running(target: target))
        XCTAssertNotNil(model.list.selection)
        model.agentsUpdated([agent(.working, session: "")])
        model.refresh()
        spy.searches.last?.completion(ok(resultJSON(["a"])))
        XCTAssertTrue(spy.paneIndexes.isEmpty)
        XCTAssertTrue(spy.shows.isEmpty)
    }

    // MARK: - Applying the result

    func testAReloadKeepsTheContentAndHitsUntilItsResult() {
        let model = makeModel()
        showRunningRow(model, texts: ["a needle", "reply"])
        model.query = "needle"
        XCTAssertEqual(model.hits.count, 1)
        model.agentsUpdated([agent(.working)])
        spy.paneIndexes[1].completion(0)
        XCTAssertEqual(model.hits.count, 1, "nothing is cleared while reloading")
        XCTAssertNil(model.paneLoadError)
        XCTAssertFalse(model.paneShowsNoConversation)
    }

    func testAFailedReloadKeepsTheConversationAndShowsNoError() {
        let failures = [exit(1), exit(2), ok("not json")]
        for failure in failures {
            let model = makeModel()
            showRunningRow(model, texts: ["a needle", "reply"])
            model.query = "needle"
            model.agentsUpdated([agent(.working)])
            spy.paneIndexes[1].completion(0)
            spy.shows[1].completion(failure)
            XCTAssertNil(model.paneLoadError, "\(failure.exitCode)")
            XCTAssertFalse(model.paneShowsNoConversation)
            XCTAssertEqual(model.hits.count, 1)
            XCTAssertEqual(model.lastPaneRender, .load, "the page is not touched")
        }
    }

    func testAFailedReloadKeepsNoConversationToShow() {
        let model = makeModel()
        openWindow(model, agents: [agent(.idle)])
        model.rowClicked(.running(target: target))
        spy.paneIndexes[0].completion(0)
        spy.shows[0].completion(exit(2))
        XCTAssertTrue(model.paneShowsNoConversation)
        model.agentsUpdated([agent(.working)])
        XCTAssertTrue(model.paneShowsNoConversation, "kept while reloading")
        spy.paneIndexes[1].completion(0)
        spy.shows[1].completion(exit(1))
        XCTAssertTrue(model.paneShowsNoConversation)
        XCTAssertNil(model.paneLoadError)
    }

    func testASuccessfulReloadShowsTheConversationInsteadOfNoConversationToShow() {
        let model = makeModel()
        openWindow(model, agents: [agent(.idle)])
        model.rowClicked(.running(target: target))
        spy.paneIndexes[0].completion(0)
        spy.shows[0].completion(exit(2))
        model.agentsUpdated([agent(.working)])
        spy.paneIndexes[1].completion(0)
        spy.shows[1].completion(ok(showJSON("s1", texts: ["first prompt"])))
        XCTAssertFalse(model.paneShowsNoConversation)
        XCTAssertNil(model.paneLoadError)
        XCTAssertEqual(model.lastPaneRender, .load, "shown from the start")
    }

    /// Reload once more with `texts` (trigger 1, full procedure).
    private func reload(_ model: MainSurfaceModel, texts: [String], updatedAt: Int64? = 9_000,
                        status: AgentStatus) {
        model.agentsUpdated([agent(status)])
        spy.paneIndexes.last?.completion(0)
        spy.shows.last?.completion(ok(showJSON("s1", texts: texts, updatedAt: updatedAt)))
    }

    func testTheUpdateFollowsHowTheMessagesChanged() {
        let model = makeModel()
        showRunningRow(model, texts: ["hello", "hi"])
        reload(model, texts: ["hello", "hi"], status: .working)
        XCTAssertEqual(model.lastPaneRender, .update(.unchanged))
        reload(model, texts: ["hello", "hi", "next", "answer"], status: .idle)
        XCTAssertEqual(model.lastPaneRender, .update(.appended(firstNewIndex: 2)))
        reload(model, texts: ["hello", "edited", "next"], status: .working)
        XCTAssertEqual(model.lastPaneRender, .update(.replaced(keptIndices: [0: 0, 2: 2])))
    }

    func testAppendingKeepsTheCurrentHitAndAddsToTheCount() {
        let model = makeModel()
        showRunningRow(model, texts: ["needle one", "x", "needle two"])
        model.query = "needle"
        XCTAssertEqual(model.hitCounterText, "2 of 2")
        model.navigateToOlderHit()
        XCTAssertEqual(model.hitCounterText, "1 of 2")
        reload(model, texts: ["needle one", "x", "needle two", "needle three"], status: .working)
        XCTAssertEqual(model.hitCounterText, "1 of 3", "N stays, M grows")
        reload(model, texts: ["needle one", "x", "needle two", "needle three"], status: .idle)
        XCTAssertEqual(model.hitCounterText, "1 of 3", "unchanged messages keep the position too")
    }

    func testRenderingAgainOrHavingNoHitBeforeMovesToTheLatestHit() {
        let model = makeModel()
        showRunningRow(model, texts: ["needle one", "x", "needle two"])
        model.query = "needle"
        model.navigateToOlderHit()
        XCTAssertEqual(model.hitCounterText, "1 of 2")
        reload(model, texts: ["needle one", "changed", "needle two"], status: .working)
        XCTAssertEqual(model.hitCounterText, "2 of 2", "rendered again: the latest occurrence")

        let fresh = makeModel()
        showRunningRow(fresh, texts: ["hello", "hi"])
        fresh.query = "needle"
        XCTAssertNil(fresh.hitCounterText)
        reload(fresh, texts: ["hello", "hi", "needle a", "needle b"], status: .working)
        XCTAssertEqual(fresh.hitCounterText, "2 of 2", "no hit before: the latest occurrence")
    }

    func testTheElapsedTimeComesFromShowsUpdatedAt() {
        let model = makeModel()
        openWindow(model, agents: [agent(.idle)])
        model.rowClicked(.running(target: target))
        spy.paneIndexes[0].completion(0)
        spy.shows[0].completion(ok(showJSON("s1", texts: ["hello"], updatedAt: now - 120)))
        XCTAssertEqual(model.paneElapsedText, ElapsedTime.format(seconds: 120), "first load")
        reload(model, texts: ["hello", "hi"], updatedAt: now - 30, status: .working)
        XCTAssertEqual(model.paneElapsedText, ElapsedTime.format(seconds: 30), "reload")
    }

    func testWithoutUpdatedAtTheSearchResultsValueIsUsed() {
        let model = makeModel()
        openWindow(model, delivering: ["a"])
        model.rowClicked(.conversation(sessionID: "a"))
        spy.shows[0].completion(ok(showJSON("a", texts: ["hello"], updatedAt: nil)))
        // `resultJSON` gives every conversation `updated_at` 1.
        XCTAssertEqual(model.paneElapsedText, ElapsedTime.format(seconds: now - 1))
    }

    // MARK: - Helpers

    private func pump(timeout: TimeInterval = 3, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
}
