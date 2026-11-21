import AppKit
import ShiibarCcCore
import Combine
import XCTest
@testable import ShiibarCcApp

/// The shared model of the popover and the window (M44; DESIGN.md §4.5 /
/// §4.6): the search pipeline (debounce, NFC, stale results, Refresh), index on
/// open, the row verbs and their outcomes, keys, stars, the pin, and the
/// message line. Every outward action is a spy — no real subprocess,
/// pasteboard, browser, state dir, or `UserDefaults.standard`. CJK fixture
/// text is written as unicode escapes (repo language rule).
@MainActor
final class MainSurfaceModelTests: XCTestCase {
    private struct Dispatched {
        let arguments: [String]
        let completion: @MainActor (CLIRunResult) -> Void
        var process: ConversationsProcess? = nil
    }

    /// One `conversations index` run of the conversation pane (no
    /// `--json`; §4.6 "conversation pane reload").
    private struct PaneIndexRun {
        let arguments: [String]
        let onLine: @MainActor (String) -> Void
        let completion: @MainActor (Int32) -> Void
        let process: ConversationsProcess
    }

    private final class Spy {
        var searches: [Dispatched] = []
        var shows: [Dispatched] = []
        /// The index on open (`--json`).
        var indexLines: [@MainActor (String) -> Void] = []
        var indexCompletions: [@MainActor (Int32) -> Void] = []
        var indexProcesses: [ConversationsProcess] = []
        /// The conversation pane's own index runs.
        var paneIndexes: [PaneIndexRun] = []
        var commands: [(arguments: [String], completion: @MainActor (Int32) -> Void)] = []
        var closePopoverCount = 0
        var permissionDeniedCount = 0
        var keepOnTopChanges: [Bool] = []
        var surfaceShownCount = 0
        /// `onFocusList` calls (the AppKit layer resigns the search field).
        var focusListSurfaces: [MainSurface] = []
        /// Delayed actions handed to the injected scheduler (never run by
        /// the clock — a test fires them explicitly).
        var scheduled: [(seconds: Double, action: @MainActor () -> Void)] = []
    }

    private var spy = Spy()
    private var defaults = InMemoryDefaults()

    override func setUp() {
        super.setUp()
        defaults = InMemoryDefaults()
    }

    private func makeModel() -> MainSurfaceModel {
        spy = Spy()
        let spy = self.spy
        let launchers = ConversationsLaunchers(
            search: { arguments, _, completion in
                spy.searches.append(Dispatched(arguments: arguments, completion: completion))
                return ConversationsProcess(process: Process())
            },
            show: { arguments, _, completion in
                let process = ConversationsProcess(process: Process())
                spy.shows.append(Dispatched(arguments: arguments, completion: completion, process: process))
                return process
            },
            index: { arguments, _, onLine, completion in
                let process = ConversationsProcess(process: Process())
                if arguments.contains("--json") {
                    spy.indexLines.append(onLine)
                    spy.indexCompletions.append(completion)
                    spy.indexProcesses.append(process)
                } else {
                    spy.paneIndexes.append(PaneIndexRun(
                        arguments: arguments, onLine: onLine, completion: completion, process: process))
                }
                return process
            }
        )
        let model = MainSurfaceModel(
            home: "/Users/example",
            defaults: defaults,
            textSize: TextSizeStore(defaults: defaults),
            launchers: launchers,
            runCommand: { arguments, completion in
                spy.commands.append((arguments: arguments, completion: completion))
            },
            resumeTerminal: { "apple-terminal" },
            schedule: { seconds, action in spy.scheduled.append((seconds: seconds, action: action)) },
            markReadSchedule: { _, _ in }
        )
        model.onClosePopover = { spy.closePopoverCount += 1 }
        model.onPermissionDenied = { spy.permissionDeniedCount += 1 }
        model.onKeepOnTopChanged = { spy.keepOnTopChanges.append($0) }
        model.onSurfaceShown = { spy.surfaceShownCount += 1 }
        model.onFocusList = { spy.focusListSurfaces.append($0) }
        return model
    }

    private func summaryJSON(_ id: String, live: Bool = false, cwd: String? = "/Users/example/demo") -> String {
        let cwdValue = cwd.map { "\"\($0)\"" } ?? "null"
        return #"{"session_id":"\#(id)","cwd":\#(cwdValue),"title":"title \#(id)","updated_at":1,"live":\#(live),"last_prompt":null}"#
    }

    private func resultJSON(_ ids: [String]) -> String {
        #"{"conversations":[\#(ids.map { summaryJSON($0) }.joined(separator: ","))]}"#
    }

    private func ok(_ stdout: String) -> CLIRunResult {
        CLIRunResult(exitCode: 0, stdout: stdout, stderr: "")
    }

    private func pump(until condition: () -> Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func waitForSearches(_ count: Int) {
        pump(until: { spy.searches.count >= count })
    }

    /// Show the popover with a warm index and deliver `ids` as History.
    private func openPopover(_ model: MainSurfaceModel, delivering ids: [String]) {
        model.surfaceDidShow(.popover)
        XCTAssertEqual(spy.indexCompletions.count, 1, "showing runs the index once")
        spy.indexCompletions.last?(0)
        XCTAssertEqual(spy.searches.count, 1, "the index is followed by a search")
        spy.searches[0].completion(ok(resultJSON(ids)))
    }

    private func agent(_ target: String, session: String) -> Agent {
        Agent(target: target, status: .idle, unreviewed: false, sessionId: session,
              cwd: "/Users/example/demo", task: nil, message: nil, createdAt: 1, since: 0, lastSeen: 0)
    }

    // "left-navi" in katakana; NFD writes hi (U+30D2) + combining dakuten.
    private let navNFD = "\u{30EC}\u{30D5}\u{30C8}\u{30CA}\u{30D2}\u{3099}"
    private let navNFC = "\u{30EC}\u{30D5}\u{30C8}\u{30CA}\u{30D3}"

    // MARK: - Search pipeline (§4.6)

    func testDecomposedQueryDispatchesComposed() {
        let model = makeModel()
        model.query = navNFD
        waitForSearches(1)
        XCTAssertEqual(spy.searches.first?.arguments, ["conversations", "search", navNFC, "--json"])
    }

    func testRapidTransitionsDispatchOnlyTheFinalQuery() {
        let model = makeModel()
        for step in ["\u{30EC}", "\u{30EC}\u{30D5}", "\u{30EC}\u{30D5}\u{30C8}", navNFC] {
            model.query = step
        }
        waitForSearches(1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(spy.searches.count, 1, "keystrokes inside the debounce collapse to one search")
        XCTAssertEqual(spy.searches[0].arguments, ["conversations", "search", navNFC, "--json"])
        spy.searches[0].completion(ok(resultJSON(["hit"])))
        XCTAssertEqual(model.list.recentRows.map(\.sessionID), ["hit"])
    }

    func testOneCharacterQueryBrowses() {
        let model = makeModel()
        model.query = "a"
        waitForSearches(1)
        XCTAssertEqual(spy.searches[0].arguments, ["conversations", "search", "--json"])
    }

    func testStaleResultNeverOverwritesTheNewest() {
        let model = makeModel()
        model.query = "left"
        waitForSearches(1)
        model.query = "left navi"
        waitForSearches(2)
        spy.searches[1].completion(ok(resultJSON(["new"])))
        spy.searches[0].completion(ok(resultJSON(["old-a", "old-b"])))
        XCTAssertEqual(model.list.recentRows.map(\.sessionID), ["new"])
    }

    func testCancelledSearchFailureDoesNotFlagAnError() {
        let model = makeModel()
        model.query = "left"
        waitForSearches(1)
        model.query = "left navi"
        waitForSearches(2)
        spy.searches[1].completion(ok(resultJSON(["new"])))
        spy.searches[0].completion(CLIRunResult(exitCode: 15, stdout: "", stderr: ""))
        XCTAssertNil(model.messageError)
        XCTAssertNil(model.messageText)
    }

    func testSearchFailureKeepsThePreviousListAndShowsTheError() {
        let model = makeModel()
        openPopover(model, delivering: ["a", "b"])
        model.query = "zz"
        waitForSearches(2)
        spy.searches[1].completion(CLIRunResult(exitCode: 1, stdout: "", stderr: ""))
        XCTAssertEqual(model.list.recentRows.map(\.sessionID), ["a", "b"])
        XCTAssertEqual(model.messageText, "Search failed")
        // §4.6: the error clears on the next successful fetch.
        model.refresh()
        waitForSearches(3)
        spy.searches[2].completion(ok(resultJSON(["a"])))
        XCTAssertNil(model.messageError)
    }

    /// A notification click clears the search: a filtered result of a
    /// search started before the click is dropped, so the clicked row
    /// stays in Running and selected until the browse result of the search
    /// started after the click arrives.
    func testFilteredResultInFlightAtANotificationClickIsDropped() {
        let model = makeModel()
        model.agentsUpdated([agent("process:4242", session: "sp")])
        openPopover(model, delivering: ["h1"])
        let clicked = UnifiedRowKey.running(target: "process:4242")
        model.query = "needle"
        waitForSearches(2)
        spy.searches[1].completion(ok(resultJSON(["h1"])))
        XCTAssertFalse(model.list.runningRows.contains { $0.id == clicked }, "the filtered result hides the row")
        model.query = "needle more"
        waitForSearches(3)

        model.notificationClicked(target: "process:4242")
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.list.selection?.key, clicked)
        spy.searches[2].completion(ok(resultJSON(["h1"])))
        XCTAssertEqual(model.list.selection?.key, clicked, "the result of the earlier search is dropped")
        XCTAssertTrue(model.list.runningRows.contains { $0.id == clicked })

        waitForSearches(4)
        XCTAssertEqual(spy.searches[3].arguments, ["conversations", "search", "--json"])
        spy.searches[3].completion(ok(resultJSON(["h1", "h2"])))
        XCTAssertEqual(model.list.selection?.key, clicked)
        XCTAssertTrue(model.list.runningRows.contains { $0.id == clicked })
        XCTAssertEqual(model.list.recentRows.map(\.sessionID), ["h1", "h2"])
    }

    // MARK: - Refresh: the header row's Refresh button and ⌘R (§4.6 / §9)

    /// The `shiibar-cc` runs Refresh started (the row verbs go through the
    /// same runner).
    private var reconciles: [(arguments: [String], completion: @MainActor (Int32) -> Void)] {
        spy.commands.filter { $0.arguments == ["reconcile"] }
    }

    func testRefreshShowsRefreshingAtTheStartAndStartsTheSearchAndTheReconcile() {
        let model = makeModel()
        model.refresh()
        XCTAssertTrue(model.isRefreshing)
        XCTAssertEqual(model.messageText, "Refreshing\u{2026}")
        XCTAssertEqual(spy.searches.map(\.arguments), [["conversations", "search", "--json"]],
                       "the search runs at once, without the debounce")
        XCTAssertEqual(spy.commands.map(\.arguments), [["reconcile"]])
    }

    /// No minimum display time: the result replaces `Refreshing…` as soon
    /// as both have finished.
    func testRefreshWaitsForBothAndShowsTheResultAtOnce() {
        let model = makeModel()
        model.refresh()
        spy.searches[0].completion(ok(resultJSON(["r1"])))
        XCTAssertEqual(model.list.recentRows.map(\.sessionID), ["r1"], "the result applies at once")
        XCTAssertTrue(model.isRefreshing, "the reconcile has not finished")
        XCTAssertEqual(model.messageText, "Refreshing\u{2026}")
        reconciles[0].completion(0)
        XCTAssertFalse(model.isRefreshing, "both finished")
        XCTAssertEqual(model.messageText, "\u{2713} Refresh done")
    }

    func testRefreshWithOnlyTheReconcileFinishedStaysInFlight() {
        let model = makeModel()
        model.refresh()
        reconciles[0].completion(0)
        XCTAssertTrue(model.isRefreshing, "the search has not finished")
        XCTAssertEqual(model.messageText, "Refreshing\u{2026}")
        spy.searches[0].completion(ok(resultJSON(["r1"])))
        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(model.messageText, "\u{2713} Refresh done")
    }

    /// §4.6: a Refresh (from the button or ⌘R) while one runs starts
    /// nothing.
    func testRefreshIgnoresARefreshInFlight() {
        let model = makeModel()
        model.refresh()
        model.refresh()
        XCTAssertEqual(key(model, .other(charactersIgnoringModifiers: "r"), [.command]), .consumed)
        XCTAssertEqual(spy.searches.count, 1, "a Refresh during the run starts no search")
        XCTAssertEqual(spy.commands.count, 1, "a Refresh during the run starts no reconcile")
        spy.searches[0].completion(ok(resultJSON(["r1"])))
        reconciles[0].completion(0)
        XCTAssertFalse(model.isRefreshing)
        model.refresh()
        XCTAssertEqual(spy.commands.count, 2, "after the run, a Refresh starts again")
    }

    /// §9: the finished transient clears after 2 seconds, timed by the
    /// injected scheduler; a newer transient is not cleared by an older
    /// timer.
    func testRefreshResultClearsAfterTheDisplayTime() {
        let model = makeModel()
        model.refresh()
        spy.searches[0].completion(ok(resultJSON(["r1"])))
        reconciles[0].completion(0)
        XCTAssertEqual(model.messageText, "\u{2713} Refresh done")
        XCTAssertEqual(spy.scheduled.map(\.seconds), [2])
        spy.scheduled[0].action()
        XCTAssertNil(model.messageText)

        model.refresh()
        spy.searches[1].completion(ok(resultJSON(["r1"])))
        reconciles[1].completion(1)
        XCTAssertEqual(model.messageText, "Refresh failed")
        model.refresh()
        XCTAssertEqual(model.messageText, "Refreshing\u{2026}")
        spy.scheduled[1].action()
        XCTAssertEqual(model.messageText, "Refreshing\u{2026}", "an older timer leaves a newer transient")
    }

    /// §4.6 "message line": `Refreshing…` shows over index progress and an
    /// error; the finished transient does not.
    func testRefreshingBeatsIndexProgressAndErrors() {
        let model = makeModel()
        openPopover(model, delivering: ["a"])
        model.query = "zz"
        waitForSearches(2)
        spy.searches[1].completion(CLIRunResult(exitCode: 1, stdout: "", stderr: ""))
        XCTAssertEqual(model.messageText, "Search failed")
        model.refresh()
        XCTAssertEqual(model.messageText, "Refreshing\u{2026}", "over the error")
        model.surfaceDidHide(.popover)
        model.surfaceDidShow(.popover)
        spy.indexLines[1](#"{"event":"start","total":4200,"full_build":true}"#)
        spy.indexLines[1](#"{"event":"progress","done":340,"total":4200}"#)
        XCTAssertEqual(model.messageText, "Refreshing\u{2026}", "over the index progress")
        reconciles[0].completion(0)
        spy.searches[2].completion(ok(resultJSON(["a"])))
        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(model.messageText, "Indexing 340 of 4,200\u{2026}", "the result does not beat the progress")
    }

    /// §4.6 table, as the model applies it: the transient, the TCC warning
    /// row, and `Search failed` from the search pipeline.
    func testRefreshOutcomes() {
        struct Case {
            let name: String
            let searchExit: Int32
            let reconcileExit: Int32
            let message: String?
            let permissionDenied: Int
        }
        let cases = [
            Case(name: "both succeed", searchExit: 0, reconcileExit: 0, message: "\u{2713} Refresh done", permissionDenied: 0),
            Case(name: "reconcile TCC", searchExit: 0, reconcileExit: 3, message: nil, permissionDenied: 1),
            Case(name: "reconcile fails", searchExit: 0, reconcileExit: 1, message: "Refresh failed", permissionDenied: 0),
            Case(name: "search fails", searchExit: 1, reconcileExit: 0, message: "Search failed", permissionDenied: 0),
            Case(name: "search fails, reconcile TCC", searchExit: 1, reconcileExit: 3, message: "Search failed",
                 permissionDenied: 1),
            Case(name: "search fails, reconcile fails", searchExit: 1, reconcileExit: 1, message: "Search failed",
                 permissionDenied: 0),
        ]
        for c in cases {
            let model = makeModel()
            model.refresh()
            let result = c.searchExit == 0 ? ok(resultJSON(["r1"])) : CLIRunResult(exitCode: c.searchExit, stdout: "", stderr: "")
            spy.searches[0].completion(result)
            reconciles[0].completion(c.reconcileExit)
            XCTAssertEqual(spy.permissionDeniedCount, c.permissionDenied, c.name)
            XCTAssertFalse(model.isRefreshing, c.name)
            XCTAssertEqual(model.messageText, c.message, c.name)
        }
    }

    /// §4.5 "key operations": ⌘R runs the same Refresh as the header row's
    /// button (`MainSurfaceModel.refresh`) — with the search field focused,
    /// with the list focused, on the detail page, and in the window.
    func testCommandRRunsTheSameRefreshAsTheButton() {
        struct Case {
            let name: String
            let surface: MainSurface
            let searchFieldFocused: Bool
            let detailPage: Bool
        }
        let cases = [
            Case(name: "popover, search field", surface: .popover, searchFieldFocused: true, detailPage: false),
            Case(name: "popover, list", surface: .popover, searchFieldFocused: false, detailPage: false),
            Case(name: "popover, detail page", surface: .popover, searchFieldFocused: false, detailPage: true),
            Case(name: "window, search field", surface: .window, searchFieldFocused: true, detailPage: false),
        ]
        for c in cases {
            let model = makeModel()
            if c.surface == .popover {
                openPopover(model, delivering: ["a"])
            } else {
                model.windowWidthChanged(900)
                model.windowDidBecomeKey()
                spy.indexCompletions.last?(0)
                spy.searches.last?.completion(ok(resultJSON(["a"])))
            }
            if c.detailPage { openDetailPage(model, .conversation(sessionID: "a")) }
            let searchesBefore = spy.searches.count
            XCTAssertEqual(key(model, .other(charactersIgnoringModifiers: "r"), [.command], surface: c.surface,
                               searchFieldFocused: c.searchFieldFocused), .consumed, c.name)
            XCTAssertTrue(model.isRefreshing, c.name)
            XCTAssertEqual(model.messageText, "Refreshing\u{2026}", c.name)
            XCTAssertEqual(spy.searches.count, searchesBefore + 1, c.name)
            XCTAssertEqual(reconciles.count, 1, c.name)
            XCTAssertEqual(model.list.page, c.detailPage ? .detail : .list, "\(c.name): the page stays")
        }
    }

    // MARK: - Surface form (§4.5 "surface form")

    func testSurfaceFormIsSavedAndReadBackOnlyByTheTwoButtons() {
        let model = makeModel()
        XCTAssertEqual(model.surfaceForm, .popover, "nothing stored: the popover form")
        var openInWindow = 0
        var openInPopover = 0
        model.onOpenInWindow = { openInWindow += 1 }
        model.onShowPopoverFromWindow = { openInPopover += 1 }

        model.openInWindowClicked()
        XCTAssertEqual(model.surfaceForm, .window)
        XCTAssertEqual(defaults.object(forKey: MainSurfaceDefaultsKeys.surfaceForm) as? String, "window",
                       "saved when it changes")
        XCTAssertEqual(openInWindow, 1)
        XCTAssertEqual(makeModel().surfaceForm, .window, "a new model reads the saved form")

        // Closing the window (every close path ends in `surfaceDidHide`)
        // and the other surface events leave the form alone.
        model.surfaceDidShow(.window)
        model.surfaceDidHide(.window)
        model.surfaceDidShow(.popover)
        model.surfaceDidHide(.popover)
        XCTAssertEqual(model.surfaceForm, .window)
        XCTAssertEqual(defaults.object(forKey: MainSurfaceDefaultsKeys.surfaceForm) as? String, "window")

        model.openInPopoverClicked()
        XCTAssertEqual(model.surfaceForm, .popover)
        XCTAssertEqual(defaults.object(forKey: MainSurfaceDefaultsKeys.surfaceForm) as? String, "popover")
        XCTAssertEqual(openInPopover, 1)
        XCTAssertEqual(makeModel().surfaceForm, .popover)
    }

    func testInvalidStoredSurfaceFormReadsAsThePopover() {
        for stored in ["sideways", 7, true] as [Any] {
            defaults.set(stored, forKey: MainSurfaceDefaultsKeys.surfaceForm)
            XCTAssertEqual(makeModel().surfaceForm, .popover, "\(stored)")
        }
        defaults.set("window", forKey: MainSurfaceDefaultsKeys.surfaceForm)
        XCTAssertEqual(makeModel().surfaceForm, .window)
    }

    /// §4.5 "window" / "global hotkey": after a tray click opens the window
    /// the search field takes focus; after the hotkey opens or raises it the
    /// list does; a tray click that raises it leaves the focus alone.
    func testFocusAfterOpeningOrRaisingTheWindow() {
        XCTAssertEqual(SurfaceToggleFocus.after(.openWindow, source: .trayClick), .initial)
        XCTAssertEqual(SurfaceToggleFocus.after(.openWindow, source: .hotKey), .list)
        XCTAssertEqual(SurfaceToggleFocus.after(.raiseWindow, source: .hotKey), .list)
        XCTAssertNil(SurfaceToggleFocus.after(.raiseWindow, source: .trayClick))
        XCTAssertEqual(SurfaceToggleFocus.after(.openPopover, source: .trayClick), .initial)
        XCTAssertEqual(SurfaceToggleFocus.after(.openPopover, source: .hotKey), .list)
        XCTAssertNil(SurfaceToggleFocus.after(.closeWindow, source: .trayClick))
        XCTAssertNil(SurfaceToggleFocus.after(.closeWindow, source: .hotKey))
        XCTAssertNil(SurfaceToggleFocus.after(.closePopover, source: .trayClick))
        XCTAssertNil(SurfaceToggleFocus.after(.closePopover, source: .hotKey))

        // What each request does in the window (list page, rows shown).
        let model = makeModel()
        model.surfaceDidShow(.window)
        spy.indexCompletions.last?(0)
        spy.searches.last?.completion(ok(resultJSON(["a", "b"])))
        let search = model.searchFocusRequests[.window] ?? 0
        model.requestInitialFocus()
        XCTAssertEqual(model.searchFocusRequests[.window], search + 1, "initial: the search field")
        XCTAssertTrue(spy.focusListSurfaces.isEmpty)
        model.openedByHotKey()
        XCTAssertEqual(spy.focusListSurfaces, [.window], "hotkey: the list")
        XCTAssertEqual(model.searchFocusRequests[.window], search + 1)
        XCTAssertNil(model.list.selection, "the selection does not change (§8.66)")
    }

    func testRefreshRunsNothingWhileAnInputMethodComposes() {
        let model = makeModel()
        openPopover(model, delivering: ["a"])
        XCTAssertEqual(key(model, .other(charactersIgnoringModifiers: "r"), [.command], marked: true,
                           searchFieldFocused: true), .passThrough)
        XCTAssertFalse(model.isRefreshing)
        XCTAssertTrue(reconciles.isEmpty)
    }

    // MARK: - Opening a surface (§4.5 / §4.6)

    func testShowingRunsIndexThenSearchAndSelectsNothing() {
        let model = makeModel()
        openPopover(model, delivering: ["newest", "older"])
        XCTAssertEqual(spy.surfaceShownCount, 1, "the permission check re-runs on show")
        XCTAssertNil(model.list.selection, "no auto-select (§8.49)")
        XCTAssertTrue(spy.shows.isEmpty)
        XCTAssertEqual(model.list.columns, .one)
    }

    func testFullBuildDisablesSearchShowsProgressAndHidesHistory() {
        let model = makeModel()
        openPopover(model, delivering: ["a"])
        model.surfaceDidHide(.popover)
        model.surfaceDidShow(.popover)
        spy.indexLines[1](#"{"event":"start","total":4200,"full_build":true}"#)
        spy.indexLines[1](#"{"event":"progress","done":340,"total":4200}"#)
        XCTAssertTrue(model.list.isFullBuild)
        XCTAssertEqual(model.messageText, "Indexing 340 of 4,200\u{2026}")
        XCTAssertEqual(model.list.recentRows, [])
        XCTAssertNil(model.list.emptyStateText, "no empty line during a full build")
        model.query = "ab"
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(spy.searches.count, 1, "keystrokes issue no search during a full build")
        spy.indexCompletions[1](0)
        XCTAssertFalse(model.list.isFullBuild)
        XCTAssertNil(model.messageText)
        XCTAssertEqual(spy.searches.count, 2)
        XCTAssertEqual(spy.searches[1].arguments, ["conversations", "search", "ab", "--json"])
    }

    /// §4.6: an index run that is not a full build (any total) keeps the
    /// previous History, the selection, the page, and the search field.
    func testIncrementalIndexRunKeepsHistorySelectionPageAndSearchField() {
        for line in [
            #"{"event":"start","total":3,"full_build":false}"#,
            #"{"event":"start","total":4200}"#, // missing key = not a full build
        ] {
            let model = makeModel()
            openPopover(model, delivering: ["a", "b"])
            openDetailPage(model, .conversation(sessionID: "b"))
            XCTAssertEqual(model.list.page, .detail)
            let showsBefore = spy.shows.count
            model.surfaceDidHide(.popover)
            model.surfaceDidShow(.popover)
            spy.indexLines[1](line)
            spy.indexLines[1](#"{"event":"progress","done":1,"total":3}"#)
            XCTAssertFalse(model.list.isFullBuild, line)
            XCTAssertEqual(model.messageText, "Indexing 1 of 3\u{2026}", "progress still shows")
            XCTAssertEqual(model.list.recentRows.map(\.sessionID), ["a", "b"], "History stays: \(line)")
            XCTAssertEqual(model.list.selection?.key, .conversation(sessionID: "b"), line)
            XCTAssertEqual(model.list.page, .detail, line)
            XCTAssertEqual(spy.shows.count, showsBefore, "the page is not reloaded")
            spy.indexCompletions[1](0)
            XCTAssertNil(model.messageText)
            XCTAssertEqual(spy.searches.count, 2, "the index is followed by a search")
            spy.searches[1].completion(ok(resultJSON(["a", "b"])))
            XCTAssertEqual(model.list.selection?.key, .conversation(sessionID: "b"))
            XCTAssertEqual(model.list.page, .detail)
        }
    }

    func testKeystrokeDuringIncrementalRunIsSearched() {
        let model = makeModel()
        openPopover(model, delivering: ["a"])
        model.surfaceDidHide(.popover)
        model.surfaceDidShow(.popover)
        spy.indexLines[1](#"{"event":"start","total":5,"full_build":false}"#)
        model.query = "ab"
        waitForSearches(2)
        XCTAssertEqual(spy.searches.count, 2, "typing during an incremental run is not dropped")
        XCTAssertEqual(spy.searches[1].arguments, ["conversations", "search", "ab", "--json"])
        // The index finishing re-runs the search with the same query.
        spy.indexCompletions[1](0)
        XCTAssertEqual(spy.searches.last?.arguments, ["conversations", "search", "ab", "--json"])
        spy.searches.last?.completion(ok(resultJSON(["ab-hit"])))
        XCTAssertEqual(model.list.recentRows.map(\.sessionID), ["ab-hit"])
    }

    func testLaterStartFollowsTheLatestFullBuildFlag() {
        // A relayed full build hands over to this process's own incremental
        // catch-up: the latest start decides (§4.4 "consumers draw the
        // latest line").
        let model = makeModel()
        model.surfaceDidShow(.popover)
        spy.indexLines[0](#"{"event":"start","total":10,"full_build":true}"#)
        XCTAssertTrue(model.list.isFullBuild)
        spy.indexLines[0](#"{"event":"start","total":0,"full_build":false}"#)
        XCTAssertFalse(model.list.isFullBuild)
    }

    func testIndexFailureShowsTheErrorAndKeepsHistory() {
        let model = makeModel()
        openPopover(model, delivering: ["a"])
        model.surfaceDidHide(.popover)
        model.surfaceDidShow(.popover)
        spy.indexCompletions[1](1)
        XCTAssertEqual(model.messageText, "Indexing failed")
        XCTAssertEqual(model.list.recentRows.map(\.sessionID), ["a"])
        XCTAssertEqual(spy.searches.count, 1)
    }

    func testWindowKeyReRunsIndexAndColumnsFollowTheWidth() {
        let model = makeModel()
        model.windowColumnsChanged(.two)
        model.windowDidBecomeKey()
        XCTAssertEqual(model.visibleSurface, .window)
        XCTAssertEqual(model.list.columns, .two)
        XCTAssertEqual(spy.indexCompletions.count, 1)
        model.windowDidBecomeKey()
        XCTAssertEqual(spy.indexCompletions.count, 2, "becoming key again re-runs index -> search")
        model.windowColumnsChanged(.one)
        XCTAssertEqual(model.list.columns, .one)
    }

    // MARK: - Selection, pane, refetch

    func testRowClickLoadsTheConversationAndShowErrorsShowInThePane() {
        let model = makeModel()
        openPopover(model, delivering: ["a", "b"])
        openDetailPage(model, .conversation(sessionID: "b"))
        XCTAssertEqual(model.list.page, .detail)
        XCTAssertEqual(spy.shows.map(\.arguments), [["conversations", "show", "b", "--json"]])
        spy.shows[0].completion(CLIRunResult(exitCode: 2, stdout: "", stderr: ""))
        XCTAssertEqual(model.paneLoadError, MainSurfaceModel.unavailableText)
        XCTAssertEqual(model.list.recentRows.map(\.sessionID), ["a", "b"], "the list stays")
    }

    func testRunningRowRemovalRefetchesHistoryNowAndAgainLater() {
        let model = makeModel()
        model.agentsUpdated([agent("iterm2:T1", session: "s1")])
        XCTAssertTrue(spy.searches.isEmpty)
        XCTAssertTrue(spy.scheduled.isEmpty)
        model.agentsUpdated([])
        XCTAssertEqual(spy.searches.count, 1, "a Running row disappearing re-runs the search (§4.6)")
        XCTAssertEqual(spy.scheduled.map(\.seconds), [2], "and schedules a second one 2 s later (§9)")
        spy.scheduled[0].action()
        XCTAssertEqual(spy.searches.count, 2, "the second refetch")
        XCTAssertEqual(spy.searches[1].arguments, ["conversations", "search", "--json"])
    }

    func testSecondRefetchShowsTheEndedConversationAsPast() {
        // The first refetch still sees the ending process alive (`live`);
        // the delayed one sees it ended.
        let model = makeModel()
        model.agentsUpdated([agent("iterm2:T1", session: "s1")])
        openPopover(model, delivering: [])
        model.agentsUpdated([])
        spy.searches[1].completion(ok(#"{"conversations":[\#(summaryJSON("s1", live: true))]}"#))
        XCTAssertFalse(model.list.recentRows[0].primaryButton.isEnabled, "live: disabled Jump")
        spy.scheduled[0].action()
        spy.searches[2].completion(ok(#"{"conversations":[\#(summaryJSON("s1", live: false))]}"#))
        XCTAssertEqual(model.list.recentRows[0].primaryButton.kind, .resume)
        XCTAssertTrue(model.list.recentRows[0].primaryButton.isEnabled)
    }

    func testANewerRemovalReplacesThePendingSecondRefetch() {
        let model = makeModel()
        model.agentsUpdated([agent("iterm2:T1", session: "s1"), agent("iterm2:T2", session: "s2")])
        model.agentsUpdated([agent("iterm2:T2", session: "s2")])
        model.agentsUpdated([])
        XCTAssertEqual(spy.searches.count, 2)
        XCTAssertEqual(spy.scheduled.count, 2)
        spy.scheduled[0].action()
        XCTAssertEqual(spy.searches.count, 2, "the replaced schedule does nothing")
        spy.scheduled[1].action()
        XCTAssertEqual(spy.searches.count, 3)
    }

    // MARK: - In-body hits (§4.6 "hit navigation")

    private func showJSON(_ id: String, texts: [String]) -> String {
        let messages = texts.enumerated().map { index, text in
            #"{"seq":\#(index),"role":"\#(index % 2 == 0 ? "user" : "assistant")","text":"\#(text)"}"#
        }
        return #"{"session_id":"\#(id)","cwd":"/Users/example/demo","title":"t","messages":[\#(messages.joined(separator: ","))]}"#
    }

    /// Open the popover, deliver `a` (for `query` when given), and open its
    /// detail page with `texts` as the conversation.
    private func openDetail(_ model: MainSurfaceModel, query: String? = nil, texts: [String]) {
        openPopover(model, delivering: ["a"])
        if let query {
            model.query = query
            waitForSearches(2)
            spy.searches[1].completion(ok(resultJSON(["a"])))
        }
        openDetailPage(model, .conversation(sessionID: "a"))
        XCTAssertEqual(spy.shows.last?.arguments, ["conversations", "show", "a", "--json"])
        spy.shows.last?.completion(ok(showJSON("a", texts: texts)))
    }

    func testHitsAreComputedAfterShowStartingAtTheLatest() {
        let model = makeModel()
        openDetail(model, query: "needle", texts: ["a needle here", "no match", "needle and needle"])
        XCTAssertEqual(model.hits.count, 3)
        XCTAssertEqual(model.hits.map(\.messageIndex), [0, 2, 2], "document order")
        XCTAssertEqual(model.currentHitIndex, 2, "the initial position is the latest hit")
        XCTAssertEqual(model.hitCounterText, "3 of 3", "N counts from the oldest hit as 1")
    }

    func testCommandGMovesThroughTheHits() {
        let model = makeModel()
        openDetail(model, query: "needle", texts: ["needle one", "needle two", "needle three"])
        XCTAssertEqual(model.currentHitIndex, 2)
        let shiftG = ListKey.other(charactersIgnoringModifiers: "G") // shift-g arrives as "G"
        XCTAssertEqual(key(model, shiftG, [.command, .shift]), .consumed)
        XCTAssertEqual(model.currentHitIndex, 1, "⇧⌘G: toward older")
        XCTAssertEqual(model.hitCounterText, "2 of 3")
        XCTAssertEqual(key(model, .other(charactersIgnoringModifiers: "g"), [.command]), .consumed)
        XCTAssertEqual(model.currentHitIndex, 2, "⌘G: toward newer")
        XCTAssertEqual(key(model, .other(charactersIgnoringModifiers: "g"), [.command], searchFieldFocused: true),
                       .consumed, "⌘G works in both focus states")
        XCTAssertEqual(model.currentHitIndex, 0, "⌘G past the newest wraps to the oldest")
        XCTAssertEqual(model.hitCounterText, "1 of 3")
    }

    func testRetypingRecomputesHitsAndClearsThem() {
        let model = makeModel()
        openDetail(model, texts: ["alpha beta", "beta"])
        XCTAssertTrue(model.hits.isEmpty, "an empty query has no hits")
        XCTAssertNil(model.hitCounterText)
        model.query = "beta"
        XCTAssertEqual(model.hits.count, 2, "hits follow the query at once (no search round-trip)")
        XCTAssertEqual(model.hitCounterText, "2 of 2")
        model.query = "b"
        XCTAssertTrue(model.hits.isEmpty, "a 1-character query has no valid term")
    }

    func testDecomposedImeQueryFindsComposedTextInTheBody() {
        let model = makeModel()
        openDetail(model, query: navNFD, texts: ["see \(navNFC) here"])
        XCTAssertEqual(model.hits, [ConversationHit(messageIndex: 0, start: 4, length: 5)])
        XCTAssertEqual(model.hitCounterText, "1 of 1")
    }

    // MARK: - Row verbs (§4.5 "action buttons" / §4.6 "bottom panel")

    /// Click a row (select only — §4.5 "row click") and return the bottom
    /// panel's buttons for it on the one-column list page.
    private func panelButtons(_ model: MainSurfaceModel, selecting key: UnifiedRowKey,
                              file: StaticString = #filePath, line: UInt = #line) -> BottomPanelButtons? {
        model.rowClicked(key)
        XCTAssertEqual(model.list.page, .list, "a row click stays on the list page", file: file, line: line)
        let buttons = model.list.listBottomPanel?.buttons
        XCTAssertNotNil(buttons, "the list page's bottom panel shows the selected row's buttons", file: file, line: line)
        return buttons
    }

    /// §4.5 "row click" / "opening the detail page": a click only selects;
    /// the bottom panel's View button opens the selected row's detail page
    /// (one column), the same as → with list focus.
    func testRowClickSelectsAndTheViewButtonOpensTheDetailPage() {
        let model = makeModel()
        openPopover(model, delivering: ["a", "b"])
        XCTAssertEqual(model.list.listBottomPanel, BottomPanelModel(hints: [.move], buttons: nil, showsViewButton: true))
        model.rowClicked(.conversation(sessionID: "a"))
        XCTAssertEqual(model.list.page, .list)
        XCTAssertEqual(model.list.selection?.key, .conversation(sessionID: "a"))
        XCTAssertTrue(spy.shows.isEmpty, "a click never opens (or loads) the detail page")
        XCTAssertEqual(spy.focusListSurfaces, [.popover], "a click moves focus to the list")
        XCTAssertEqual(model.list.listBottomPanel?.slots, [.view, .branch, .primary])
        XCTAssertNotNil(model.list.listBottomPanel?.buttons, "View shows with the other buttons")
        let paneFocus = model.paneFocusRequests[.popover] ?? 0
        model.viewClicked()
        XCTAssertEqual(model.list.page, .detail)
        XCTAssertEqual(model.list.selection?.key, .conversation(sessionID: "a"))
        XCTAssertEqual(spy.shows.map(\.arguments), [["conversations", "show", "a", "--json"]])
        XCTAssertEqual(model.paneFocusRequests[.popover], paneFocus + 1)
        XCTAssertTrue(spy.commands.isEmpty, "View runs no command")
        guard case .conversation(let pane) = model.list.paneContent else { return XCTFail("expected the detail page") }
        XCTAssertEqual(pane.bottomPanel.slots, [.branch, .primary], "the detail page has no View")

        // → with list focus does the same from the list page.
        let viaKey = makeModel()
        openPopover(viaKey, delivering: ["a", "b"])
        viaKey.rowClicked(.conversation(sessionID: "a"))
        XCTAssertEqual(key(viaKey, .rightArrow), .consumed)
        XCTAssertEqual(viaKey.list, model.list, "→ leaves the same state as View")
    }

    func testResumeRunsTheCliAndClosesThePopoverOnSuccess() {
        let model = makeModel()
        openPopover(model, delivering: ["a"])
        guard let buttons = panelButtons(model, selecting: .conversation(sessionID: "a")) else { return }
        model.buttonClicked(buttons.primary)
        XCTAssertEqual(spy.commands.map(\.arguments),
                       [["resume", "--cwd", "/Users/example/demo", "--terminal", "apple-terminal", "a"]])
        XCTAssertEqual(model.list.page, .list, "a button never changes the page")
        spy.commands[0].completion(0)
        XCTAssertEqual(spy.closePopoverCount, 1)
        XCTAssertEqual(spy.searches.count, 2, "a successful Resume re-runs the search")
    }

    func testBranchPassesForkAndJumpDoesNotRefetch() {
        let model = makeModel()
        model.agentsUpdated([agent("iterm2:T1", session: "s1")])
        openPopover(model, delivering: ["a"])
        guard let running = panelButtons(model, selecting: .running(target: "iterm2:T1")) else { return }
        model.buttonClicked(running.branch)
        XCTAssertEqual(spy.commands.last?.arguments,
                       ["resume", "--cwd", "/Users/example/demo", "--terminal", "apple-terminal", "--fork", "s1"])
        model.buttonClicked(running.primary)
        XCTAssertEqual(spy.commands.last?.arguments, ["focus", "iterm2:T1"])
        let searchesBefore = spy.searches.count
        spy.commands.last?.completion(0)
        XCTAssertEqual(spy.searches.count, searchesBefore, "Jump never re-runs the search")
        XCTAssertEqual(spy.closePopoverCount, 1)
    }

    func testFailureOutcomesKeepThePopoverOpen() {
        struct Case {
            let exitCode: Int32
            let jump: Bool
            let expectedMessage: String?
            let expectedPermissionDenied: Int
        }
        let cases = [
            Case(exitCode: 2, jump: true, expectedMessage: nil, expectedPermissionDenied: 0),
            Case(exitCode: 3, jump: true, expectedMessage: nil, expectedPermissionDenied: 1),
            Case(exitCode: 1, jump: true, expectedMessage: "Jump failed", expectedPermissionDenied: 0),
            Case(exitCode: 1, jump: false, expectedMessage: "Resume failed", expectedPermissionDenied: 0),
            Case(exitCode: 3, jump: false, expectedMessage: nil, expectedPermissionDenied: 1),
        ]
        for testCase in cases {
            let model = makeModel()
            model.agentsUpdated([agent("iterm2:T1", session: "s1")])
            openPopover(model, delivering: ["a"])
            let key: UnifiedRowKey = testCase.jump ? .running(target: "iterm2:T1") : .conversation(sessionID: "a")
            guard let buttons = panelButtons(model, selecting: key) else { return }
            model.buttonClicked(buttons.primary)
            spy.commands[0].completion(testCase.exitCode)
            XCTAssertEqual(spy.closePopoverCount, 0, "exit \(testCase.exitCode)")
            XCTAssertEqual(model.messageText, testCase.expectedMessage, "exit \(testCase.exitCode)")
            XCTAssertEqual(spy.permissionDeniedCount, testCase.expectedPermissionDenied, "exit \(testCase.exitCode)")
        }
    }

    func testSuccessInTheWindowDoesNotClosePopover() {
        let model = makeModel()
        model.windowDidBecomeKey()
        spy.indexCompletions[0](0)
        spy.searches[0].completion(ok(resultJSON(["a"])))
        guard let buttons = panelButtons(model, selecting: .conversation(sessionID: "a")) else { return }
        model.buttonClicked(buttons.primary)
        spy.commands[0].completion(0)
        XCTAssertEqual(spy.closePopoverCount, 0)
    }

    func testDisabledButtonRunsNothing() {
        let model = makeModel()
        model.surfaceDidShow(.popover)
        spy.indexCompletions[0](0)
        spy.searches[0].completion(ok(#"{"conversations":[\#(summaryJSON("x", cwd: nil))]}"#))
        guard let buttons = panelButtons(model, selecting: .conversation(sessionID: "x")) else { return }
        XCTAssertFalse(buttons.primary.isEnabled)
        XCTAssertFalse(buttons.branch.isEnabled)
        model.buttonClicked(buttons.primary)
        model.buttonClicked(buttons.branch)
        XCTAssertTrue(spy.commands.isEmpty)
    }

    /// §4.5 "action buttons" / "key operations" / "row double-click": the
    /// Running row of a session the app cannot jump to has a disabled Jump
    /// (with the untracked-terminal tooltip) and an enabled Branch. Enter
    /// and a double-click run no command; in one column they open the
    /// detail page (Enter on the detail page then does nothing), in two
    /// columns they move focus to the conversation pane.
    func testARowThatCannotJumpShowsItsConversationInsteadOfJumping() {
        let target = "process:48213"
        let popover = makeModel()
        popover.agentsUpdated([agent(target, session: "sp")])
        openPopover(popover, delivering: ["a"])
        guard let buttons = panelButtons(popover, selecting: .running(target: target)) else { return }
        XCTAssertFalse(buttons.primary.isEnabled)
        XCTAssertEqual(buttons.primary.kind, .jump)
        XCTAssertEqual(buttons.primary.tooltip, "Running in a terminal Shiibar CC can't drive")
        XCTAssertTrue(buttons.branch.isEnabled)
        popover.buttonClicked(buttons.primary)
        XCTAssertTrue(spy.commands.isEmpty, "the disabled Jump runs nothing")
        let paneFocus = popover.paneFocusRequests[.popover] ?? 0
        XCTAssertTrue(spy.paneIndexes.isEmpty)
        XCTAssertEqual(key(popover, .returnKey), .consumed)
        XCTAssertEqual(popover.list.page, .detail, "one column: Enter opens the detail page")
        XCTAssertEqual(spy.paneIndexes.count, 1, "the Running row's conversation starts loading (index first)")
        XCTAssertEqual(popover.paneFocusRequests[.popover], paneFocus + 1)
        XCTAssertEqual(key(popover, .returnKey), .consumed)
        XCTAssertEqual(popover.list.page, .detail, "the detail page: Enter does nothing more")
        XCTAssertEqual(popover.paneFocusRequests[.popover], paneFocus + 1)
        XCTAssertTrue(spy.commands.isEmpty, "Enter never runs Jump")
        XCTAssertEqual(key(popover, .returnKey, [.command]), .consumed)
        XCTAssertEqual(spy.commands.map(\.arguments),
                       [["resume", "--cwd", "/Users/example/demo", "--terminal", "apple-terminal", "--fork", "sp"]],
                       "⌘Enter still runs Branch")

        for viaDoubleClick in [false, true] {
            spy.commands = []
            let window = makeModel()
            window.windowColumnsChanged(.two)
            window.windowDidBecomeKey()
            spy.indexCompletions.last?(0)
            spy.searches.last?.completion(ok(resultJSON(["a"])))
            window.agentsUpdated([agent(target, session: "sp")])
            let windowPaneFocus = window.paneFocusRequests[.window] ?? 0
            if viaDoubleClick {
                for count in [1, 2] {
                    window.pointerDown(surface: .window, surfaceWasKey: true, searchFieldFocused: false,
                                       clickCount: count, pressedAt: 100 + Double(count) * 0.1)
                    window.rowClicked(.running(target: target))
                }
            } else {
                window.rowClicked(.running(target: target))
                XCTAssertEqual(key(window, .returnKey, surface: .window), .consumed)
            }
            let name = viaDoubleClick ? "double-click" : "Enter"
            XCTAssertEqual(window.paneFocusRequests[.window], windowPaneFocus + 1,
                           "\(name): two columns move focus to the conversation pane")
            XCTAssertEqual(window.list.selection?.key, .running(target: target), name)
            XCTAssertTrue(spy.commands.isEmpty, "\(name): runs no command")
        }
    }

    // MARK: - Keys (§4.5)

    private func key(
        _ model: MainSurfaceModel, _ key: ListKey, _ modifiers: ListKeyModifiers = [],
        surface: MainSurface = .popover, marked: Bool = false, searchFieldFocused: Bool = false
    ) -> MainSurfaceModel.KeyRouting {
        model.handleKey(key: key, modifiers: modifiers, surface: surface,
                        hasMarkedText: marked, searchFieldFocused: searchFieldFocused)
    }

    func testKeyRouting() {
        let model = makeModel()
        openPopover(model, delivering: ["a", "b"])
        XCTAssertEqual(key(model, .escape, surface: .window), .consumed,
                       "Esc in the window is consumed (it must not clear the search field)")
        XCTAssertEqual(spy.closePopoverCount, 0)
        XCTAssertEqual(key(model, .escape, searchFieldFocused: true), .consumed)
        XCTAssertEqual(spy.closePopoverCount, 1)
        XCTAssertEqual(key(model, .downArrow, marked: true, searchFieldFocused: true), .passThrough,
                       "marked text: the input method gets every key")
        XCTAssertEqual(key(model, .returnKey, marked: true, searchFieldFocused: true), .passThrough)
        XCTAssertNil(model.list.selection)
        XCTAssertTrue(spy.focusListSurfaces.isEmpty)
        XCTAssertEqual(key(model, .rightArrow, searchFieldFocused: true), .passThrough, "→ moves the caret")
        XCTAssertEqual(key(model, .other(charactersIgnoringModifiers: "x"), searchFieldFocused: true), .passThrough)
        XCTAssertEqual(key(model, .other(charactersIgnoringModifiers: "c"), [.command]), .passThrough,
                       "⌘C belongs to the pane")
        XCTAssertEqual(key(model, .returnKey, [.command, .shift]), .passThrough, "⇧⌘Enter is not assigned")
    }

    /// §4.5: ↑ / ↓ and ⌘Enter in the search field do nothing (swallowed:
    /// no selection move, no focus move, no verb); Enter moves focus to the
    /// list, then Enter (list focus) runs the primary button and ⌘Enter runs
    /// Branch.
    func testSearchFieldEditsOnlyThenEnterResumesAndCommandEnterBranches() {
        let model = makeModel()
        openPopover(model, delivering: ["a", "b"])
        XCTAssertEqual(key(model, .downArrow, searchFieldFocused: true), .consumed)
        XCTAssertEqual(key(model, .upArrow, searchFieldFocused: true), .consumed)
        XCTAssertNil(model.list.selection, "↑ / ↓ in the search field: no selection")
        XCTAssertTrue(spy.focusListSurfaces.isEmpty, "↑ / ↓ in the search field: the focus stays")
        XCTAssertTrue(model.list.isSearchFieldFocused)
        XCTAssertEqual(key(model, .returnKey, [.command], searchFieldFocused: true), .consumed)
        XCTAssertTrue(spy.commands.isEmpty, "⌘Enter in the search field: nothing")
        XCTAssertNil(model.list.selection)

        XCTAssertEqual(key(model, .returnKey, searchFieldFocused: true), .consumed)
        XCTAssertEqual(model.list.selection?.key, .conversation(sessionID: "a"))
        XCTAssertEqual(spy.focusListSurfaces, [.popover], "focus moves to the list")
        XCTAssertEqual(key(model, .downArrow), .consumed)
        XCTAssertEqual(model.list.selection?.key, .conversation(sessionID: "b"), "↓ with list focus moves")
        XCTAssertEqual(key(model, .returnKey), .consumed)
        XCTAssertEqual(spy.commands.map(\.arguments),
                       [["resume", "--cwd", "/Users/example/demo", "--terminal", "apple-terminal", "b"]])
        XCTAssertEqual(key(model, .returnKey, [.command]), .consumed)
        XCTAssertEqual(spy.commands.last?.arguments,
                       ["resume", "--cwd", "/Users/example/demo", "--terminal", "apple-terminal", "--fork", "b"])
        // With a selection, ⌘Enter in the search field still does nothing.
        XCTAssertEqual(key(model, .returnKey, [.command], searchFieldFocused: true), .consumed)
        XCTAssertEqual(key(model, .downArrow, searchFieldFocused: true), .consumed)
        XCTAssertEqual(spy.commands.count, 2)
        XCTAssertEqual(model.list.selection?.key, .conversation(sessionID: "b"))
    }

    /// §4.5: Enter in the search field focuses the list, selecting the
    /// first row when nothing is selected — it never runs a verb; with no
    /// rows it does nothing.
    func testEnterInTheSearchField() {
        let model = makeModel()
        openPopover(model, delivering: [])
        XCTAssertEqual(key(model, .returnKey, searchFieldFocused: true), .consumed)
        XCTAssertNil(model.list.selection)
        XCTAssertTrue(spy.focusListSurfaces.isEmpty, "no rows: nothing")

        let withRows = makeModel()
        openPopover(withRows, delivering: ["a", "b"])
        XCTAssertEqual(key(withRows, .returnKey, searchFieldFocused: true), .consumed)
        XCTAssertEqual(withRows.list.selection?.key, .conversation(sessionID: "a"))
        XCTAssertEqual(spy.focusListSurfaces, [.popover])
        XCTAssertTrue(spy.commands.isEmpty, "Enter in the search field never runs Resume")
        // Back in the search field with a selection: focus only.
        withRows.rowClicked(.conversation(sessionID: "b"))
        XCTAssertEqual(key(withRows, .returnKey, searchFieldFocused: true), .consumed)
        XCTAssertEqual(withRows.list.selection?.key, .conversation(sessionID: "b"))
        XCTAssertTrue(spy.commands.isEmpty)
    }

    /// §4.5 "global hotkey" / §8.66: opened by the hotkey, the list takes
    /// focus on the shown surface and the selection stays as it is (none
    /// stays none; a selected row stays selected); with no rows the search
    /// field does; on the detail page the conversation pane does.
    func testOpenedByHotKeyFocusesTheListWithoutSelecting() {
        let empty = makeModel()
        openPopover(empty, delivering: [])
        let searchRequests = empty.searchFocusRequests[.popover] ?? 0
        empty.openedByHotKey()
        XCTAssertEqual(empty.searchFocusRequests[.popover] ?? 0, searchRequests + 1, "no rows: the search field")
        XCTAssertTrue(spy.focusListSurfaces.isEmpty)

        let withRows = makeModel()
        openPopover(withRows, delivering: ["a", "b"])
        withRows.openedByHotKey()
        XCTAssertNil(withRows.list.selection, "no selection stays no selection")
        XCTAssertEqual(spy.focusListSurfaces, [.popover])
        XCTAssertTrue(spy.commands.isEmpty, "never runs a verb")
        withRows.rowClicked(.conversation(sessionID: "b"))
        withRows.openedByHotKey()
        XCTAssertEqual(withRows.list.selection?.key, .conversation(sessionID: "b"), "a selection does not change")

        openDetailPage(withRows, .conversation(sessionID: "b"))
        let paneRequests = withRows.paneFocusRequests[.popover] ?? 0
        withRows.openedByHotKey()
        XCTAssertEqual(withRows.list.page, .detail, "the detail page stays")
        XCTAssertEqual(withRows.paneFocusRequests[.popover] ?? 0, paneRequests + 1)
    }

    /// §4.5 "key operations" / §8.66: with list focus and no selection,
    /// Enter selects the first row (as Enter in the search field does) and
    /// ⌘Enter does nothing; with a selection, Enter / ⌘Enter do nothing
    /// while the button is disabled.
    func testListEnterWithoutSelectionSelectsTheFirstRowAndDisabledButtonsDoNothing() {
        let model = makeModel()
        model.surfaceDidShow(.popover)
        spy.indexCompletions[0](0)
        spy.searches[0].completion(ok(#"{"conversations":[\#(summaryJSON("x", cwd: nil))]}"#))
        XCTAssertEqual(key(model, .returnKey, [.command]), .consumed)
        XCTAssertNil(model.list.selection, "⌘Enter without a selection does nothing")
        let scrolls = model.scrollSelectionRequest
        XCTAssertEqual(key(model, .returnKey), .consumed)
        XCTAssertEqual(model.list.selection?.key, .conversation(sessionID: "x"), "Enter selects the first row")
        XCTAssertEqual(model.scrollSelectionRequest, scrolls + 1)
        XCTAssertEqual(key(model, .returnKey), .consumed)
        XCTAssertEqual(key(model, .returnKey, [.command]), .consumed)
        XCTAssertTrue(spy.commands.isEmpty)

        let empty = makeModel()
        openPopover(empty, delivering: [])
        XCTAssertEqual(key(empty, .returnKey), .consumed)
        XCTAssertNil(empty.list.selection, "no rows: nothing")
    }

    /// §4.5: typing with list focus does nothing — the key is not assigned,
    /// so it passes on to the focused view (the conversation pane scrolls
    /// with Space); it never reaches the search field.
    func testTypingWithListFocusPassesThroughWithoutEffect() {
        let model = makeModel()
        openPopover(model, delivering: ["a", "b"])
        model.rowClicked(.conversation(sessionID: "a"))
        let searchFocus = model.searchFocusRequests[.popover] ?? 0
        for typed in [ListKey.other(charactersIgnoringModifiers: "t"), .other(charactersIgnoringModifiers: " "), .delete] {
            XCTAssertEqual(key(model, typed), .passThrough, "\(typed)")
        }
        XCTAssertEqual(model.searchFocusRequests[.popover] ?? 0, searchFocus, "the search field does not take focus")
        XCTAssertEqual(model.list.selection?.key, .conversation(sessionID: "a"))
        XCTAssertEqual(model.query, "")
        openDetailPage(model, .conversation(sessionID: "a"))
        XCTAssertEqual(key(model, .other(charactersIgnoringModifiers: " ")), .passThrough, "detail page: Space to the pane")
        XCTAssertEqual(model.list.page, .detail)

        let window = makeModel()
        window.windowColumnsChanged(.two)
        window.windowDidBecomeKey()
        let windowSearchFocus = window.searchFocusRequests[.window] ?? 0
        XCTAssertEqual(key(window, .other(charactersIgnoringModifiers: "t"), surface: .window), .passThrough)
        XCTAssertEqual(window.searchFocusRequests[.window] ?? 0, windowSearchFocus)
    }

    /// → / ← with list focus open and close the detail page; the focus
    /// follows (detail page: the pane; back: the list).
    func testArrowsOpenAndCloseTheDetailPage() {
        let model = makeModel()
        openPopover(model, delivering: ["a", "b"])
        XCTAssertEqual(key(model, .rightArrow), .consumed)
        XCTAssertEqual(model.list.page, .list, "no selection: nothing")
        model.rowClicked(.conversation(sessionID: "b"))
        let paneFocus = model.paneFocusRequests[.popover] ?? 0
        XCTAssertEqual(key(model, .rightArrow), .consumed)
        XCTAssertEqual(model.list.page, .detail)
        XCTAssertEqual(spy.shows.map(\.arguments), [["conversations", "show", "b", "--json"]])
        XCTAssertEqual(model.paneFocusRequests[.popover], paneFocus + 1)
        XCTAssertEqual(key(model, .returnKey), .consumed, "Enter on the detail page: Resume")
        XCTAssertEqual(spy.commands.last?.arguments.last, "b")
        XCTAssertEqual(model.list.page, .detail, "Enter no longer toggles the page")
        let focusList = spy.focusListSurfaces.count
        XCTAssertEqual(key(model, .leftArrow), .consumed)
        XCTAssertEqual(model.list.page, .list)
        XCTAssertEqual(spy.focusListSurfaces.count, focusList + 1, "back on the list page, the focus is the list")
    }

    /// §4.5: on the one-column detail page ↑ / ↓ go to the conversation
    /// pane (scrolling) and never switch conversations; ⌥↑ / ⌥↓ and the
    /// header's prev / next buttons switch to the previous / next row's
    /// conversation (nothing at the ends). ⌥↑ / ⌥↓ on the list page do
    /// nothing; in the search field they are text editing.
    func testDetailPageArrowsScrollAndOptionArrowsSwitch() {
        let model = makeModel()
        openPopover(model, delivering: ["a", "b"])
        model.rowClicked(.conversation(sessionID: "a"))
        XCTAssertEqual(key(model, .downArrow, [.option]), .consumed)
        XCTAssertEqual(model.list.selection?.key, .conversation(sessionID: "a"), "list page: ⌥↓ does nothing")
        XCTAssertEqual(key(model, .downArrow, [.option], searchFieldFocused: true), .passThrough,
                       "search field: ⌥↓ is text editing")
        openDetailPage(model, .conversation(sessionID: "a"))
        XCTAssertEqual(model.list.page, .detail)
        for arrow in [ListKey.downArrow, .upArrow] {
            XCTAssertEqual(key(model, arrow), .passToConversationPane, "\(arrow)")
        }
        XCTAssertEqual(model.list.selection?.key, .conversation(sessionID: "a"), "↑ / ↓ do not switch")
        guard case .conversation(let pane) = model.list.paneContent else { return XCTFail("expected the pane") }
        XCTAssertEqual(pane.hints, [.prevNext, .back])

        XCTAssertEqual(key(model, .downArrow, [.option]), .consumed)
        XCTAssertEqual(model.list.selection?.key, .conversation(sessionID: "b"))
        XCTAssertEqual(model.list.page, .detail)
        XCTAssertEqual(spy.shows.last?.arguments, ["conversations", "show", "b", "--json"])
        XCTAssertEqual(key(model, .downArrow, [.option]), .consumed)
        XCTAssertEqual(model.list.selection?.key, .conversation(sessionID: "b"), "last row: nothing")
        XCTAssertEqual(key(model, .upArrow, [.option]), .consumed)
        XCTAssertEqual(model.list.selection?.key, .conversation(sessionID: "a"))

        model.nextConversationClicked()
        XCTAssertEqual(model.list.selection?.key, .conversation(sessionID: "b"))
        model.previousConversationClicked()
        XCTAssertEqual(model.list.selection?.key, .conversation(sessionID: "a"))
        XCTAssertEqual(model.list.page, .detail)
    }

    /// The focus location reported by the AppKit layer drives the key hints
    /// and the bottom panel's buttons; a report from the surface that is not
    /// on screen is ignored.
    func testSearchFieldFocusReportsDriveHintsAndButtons() {
        let model = makeModel()
        openPopover(model, delivering: ["a"])
        model.rowClicked(.conversation(sessionID: "a"))
        XCTAssertEqual(model.list.footerHints, [.move])
        XCTAssertNotNil(model.list.listBottomPanel?.buttons)
        model.searchFieldFocusChanged(surface: .popover, focused: true)
        XCTAssertEqual(model.list.footerHints, [.list])
        XCTAssertNil(model.list.listBottomPanel?.buttons, "no buttons while the search field has focus")
        XCTAssertEqual(model.list.selection?.key, .conversation(sessionID: "a"), "the selection stays")
        model.searchFieldFocusChanged(surface: .window, focused: false)
        XCTAssertEqual(model.list.footerHints, [.list], "the hidden window's report is ignored")
        // A key event carries the live focus location too.
        XCTAssertEqual(key(model, .escape, surface: .window, searchFieldFocused: false), .consumed)
        XCTAssertFalse(model.list.isSearchFieldFocused)
        XCTAssertEqual(model.list.footerHints, [.move])
        XCTAssertNotNil(model.list.listBottomPanel?.buttons)
    }

    /// §4.6 "bottom panel" / §8.55: Enter in the search field moves focus to
    /// the list, and the selected row's buttons come back.
    func testEnterFromTheSearchFieldShowsTheButtonsAgain() {
        let model = makeModel()
        openPopover(model, delivering: ["a"])
        model.rowClicked(.conversation(sessionID: "a"))
        model.searchFieldFocusChanged(surface: .popover, focused: true)
        XCTAssertNil(model.list.listBottomPanel?.buttons)
        XCTAssertEqual(key(model, .returnKey, searchFieldFocused: true), .consumed)
        XCTAssertEqual(spy.focusListSurfaces.last, .popover, "Enter moves focus to the list")
        // The AppKit layer reports the focus change that follows.
        model.searchFieldFocusChanged(surface: .popover, focused: false)
        XCTAssertNotNil(model.list.listBottomPanel?.buttons)
        XCTAssertTrue(spy.commands.isEmpty, "Enter in the search field runs no button")
    }

    /// §4.5 "row click": clicking the selected row deselects it.
    func testClickOnTheSelectedRowDeselects() {
        let model = makeModel()
        openPopover(model, delivering: ["a"])
        model.rowClicked(.conversation(sessionID: "a"))
        XCTAssertNotNil(model.list.listBottomPanel?.buttons)
        model.rowClicked(.conversation(sessionID: "a"))
        XCTAssertNil(model.list.selection)
        XCTAssertEqual(model.list.listBottomPanel, BottomPanelModel(hints: [.move], buttons: nil, showsViewButton: true))
        XCTAssertEqual(spy.focusListSurfaces, [.popover, .popover], "each click moves focus to the list")
    }

    /// §4.5 "row click" through the model: the press snapshot from the
    /// AppKit layer's mouse-down monitor decides, even when the surface
    /// became key and the search field resigned before the row's action.
    func testRowClickOnTheSelectedRowUsesThePressSnapshot() {
        struct Case {
            let name: String
            let surfaceWasKey: Bool
            let searchFieldFocused: Bool
            let expectDeselect: Bool
        }
        let cases = [
            Case(name: "accent at the press", surfaceWasKey: true, searchFieldFocused: false, expectDeselect: true),
            Case(name: "search field focus at the press", surfaceWasKey: true, searchFieldFocused: true, expectDeselect: false),
            Case(name: "not key at the press", surfaceWasKey: false, searchFieldFocused: false, expectDeselect: false),
        ]
        for testCase in cases {
            let model = makeModel()
            openPopover(model, delivering: ["a", "b"])
            model.rowClicked(.conversation(sessionID: "a"))
            model.surfaceKeyChanged(surface: .popover, isKey: testCase.surfaceWasKey)
            model.searchFieldFocusChanged(surface: .popover, focused: testCase.searchFieldFocused)
            XCTAssertEqual(model.list.isSelectionActive, testCase.surfaceWasKey && !testCase.searchFieldFocused, testCase.name)
            model.pointerDown(surface: .popover, surfaceWasKey: testCase.surfaceWasKey,
                              searchFieldFocused: testCase.searchFieldFocused)
            // AppKit: the window becomes key and the search field resigns
            // before the row's click action runs.
            model.surfaceKeyChanged(surface: .popover, isKey: true)
            model.searchFieldFocusChanged(surface: .popover, focused: false)
            XCTAssertTrue(model.list.isSelectionActive, testCase.name)
            spy.focusListSurfaces = []
            model.rowClicked(.conversation(sessionID: "a"))
            // §4.5 "row double-click": the deselect waits for the
            // double-click interval (the injected scheduler).
            XCTAssertEqual(spy.scheduled.count, testCase.expectDeselect ? 1 : 0, testCase.name)
            spy.scheduled.forEach { $0.action() }
            XCTAssertEqual(model.list.selection?.key, testCase.expectDeselect ? nil : .conversation(sessionID: "a"), testCase.name)
            XCTAssertEqual(spy.focusListSurfaces, [.popover], "\(testCase.name): the click moves focus to the list")
        }
    }

    /// §4.5 "row double-click" through the model: a double-click runs Jump
    /// (Running row) or Resume (History row) with the spy, in the popover and
    /// in the window, from any row look; a single click on an accent row
    /// deselects only when the injected scheduler fires, after the system
    /// double-click interval counted from the press.
    func testDoubleClickRunsJumpOrResume() {
        struct Case {
            let name: String
            let surface: MainSurface
            let key: UnifiedRowKey
            let expected: [String]
        }
        let cases = [
            Case(name: "popover, Running", surface: .popover, key: .running(target: "iterm2:T1"),
                 expected: ["focus", "iterm2:T1"]),
            Case(name: "popover, History", surface: .popover, key: .conversation(sessionID: "a"),
                 expected: ["resume", "--cwd", "/Users/example/demo", "--terminal", "apple-terminal", "a"]),
            Case(name: "window, History", surface: .window, key: .conversation(sessionID: "a"),
                 expected: ["resume", "--cwd", "/Users/example/demo", "--terminal", "apple-terminal", "a"]),
        ]
        for testCase in cases {
            for preselect in [false, true] {
                let name = "\(testCase.name), preselected: \(preselect)"
                let model = makeModel()
                model.agentsUpdated([agent("iterm2:T1", session: "s1")])
                if testCase.surface == .popover {
                    openPopover(model, delivering: ["a"])
                } else {
                    model.windowDidBecomeKey()
                    spy.indexCompletions[0](0)
                    spy.searches[0].completion(ok(resultJSON(["a"])))
                }
                if preselect { model.rowClicked(testCase.key) }
                spy.focusListSurfaces = []
                model.pointerDown(surface: testCase.surface, surfaceWasKey: true, searchFieldFocused: false,
                                  clickCount: 1, pressedAt: 100)
                model.rowClicked(testCase.key)
                XCTAssertTrue(spy.commands.isEmpty, "\(name): the first click runs nothing")
                model.pointerDown(surface: testCase.surface, surfaceWasKey: true, searchFieldFocused: false,
                                  clickCount: 2, pressedAt: 100.2)
                model.rowClicked(testCase.key)
                XCTAssertEqual(spy.commands.map(\.arguments), [testCase.expected], name)
                XCTAssertEqual(model.list.selection?.key, testCase.key, name)
                XCTAssertEqual(spy.focusListSurfaces, [testCase.surface, testCase.surface], name)
                // The first click's deselect (preselected = accent) is off.
                spy.scheduled.forEach { $0.action() }
                XCTAssertEqual(model.list.selection?.key, testCase.key, "\(name): never deselected")
                // A third click does not run it again.
                model.pointerDown(surface: testCase.surface, surfaceWasKey: true, searchFieldFocused: false,
                                  clickCount: 3, pressedAt: 100.4)
                model.rowClicked(testCase.key)
                XCTAssertEqual(spy.commands.count, 1, name)
            }
        }
    }

    func testDoubleClickWithTheButtonDisabledRunsNothing() {
        let model = makeModel()
        model.surfaceDidShow(.popover)
        spy.indexCompletions[0](0)
        spy.searches[0].completion(ok(#"{"conversations":[\#(summaryJSON("x", cwd: nil))]}"#))
        for count in [1, 2] {
            model.pointerDown(surface: .popover, surfaceWasKey: true, searchFieldFocused: false, clickCount: count)
            model.rowClicked(.conversation(sessionID: "x"))
        }
        XCTAssertTrue(spy.commands.isEmpty)
        XCTAssertEqual(model.list.selection?.key, .conversation(sessionID: "x"))
        XCTAssertEqual(spy.focusListSurfaces, [.popover, .popover])
    }

    /// §4.5 "row double-click": ⌘ held at the second press runs Branch
    /// (`resume --fork`, `focus` never) instead of Jump / Resume; with Branch
    /// disabled the double-click runs nothing. The AppKit layer passes ⌘
    /// from the press's modifier flags.
    func testCommandDoubleClickRunsBranch() {
        struct Case {
            let name: String
            let surface: MainSurface
            let key: UnifiedRowKey
            let expected: [[String]]
        }
        let cases = [
            Case(name: "popover, Running", surface: .popover, key: .running(target: "iterm2:T1"),
                 expected: [["resume", "--cwd", "/Users/example/demo", "--terminal", "apple-terminal", "--fork", "s1"]]),
            Case(name: "popover, History", surface: .popover, key: .conversation(sessionID: "a"),
                 expected: [["resume", "--cwd", "/Users/example/demo", "--terminal", "apple-terminal", "--fork", "a"]]),
            Case(name: "window, History", surface: .window, key: .conversation(sessionID: "a"),
                 expected: [["resume", "--cwd", "/Users/example/demo", "--terminal", "apple-terminal", "--fork", "a"]]),
            Case(name: "popover, Running without a session_id (Branch disabled)", surface: .popover,
                 key: .running(target: "iterm2:T0"), expected: []),
        ]
        for testCase in cases {
            let model = makeModel()
            model.agentsUpdated([agent("iterm2:T1", session: "s1"), agent("iterm2:T0", session: "")])
            if testCase.surface == .popover {
                openPopover(model, delivering: ["a"])
            } else {
                model.windowDidBecomeKey()
                spy.indexCompletions[0](0)
                spy.searches[0].completion(ok(resultJSON(["a"])))
            }
            model.pointerDown(surface: testCase.surface, surfaceWasKey: true, searchFieldFocused: false,
                              clickCount: 1, pressedAt: 100, commandKey: true)
            model.rowClicked(testCase.key)
            XCTAssertTrue(spy.commands.isEmpty, "\(testCase.name): a single ⌘-click runs nothing")
            model.pointerDown(surface: testCase.surface, surfaceWasKey: true, searchFieldFocused: false,
                              clickCount: 2, pressedAt: 100.2, commandKey: true)
            model.rowClicked(testCase.key)
            XCTAssertEqual(spy.commands.map(\.arguments), testCase.expected, testCase.name)
            XCTAssertEqual(model.list.selection?.key, testCase.key, testCase.name)
            XCTAssertEqual(model.list.page, .list, testCase.name)
        }
    }

    /// The deferred deselect waits for the system double-click interval
    /// from the press: the click action runs on mouse-up, so the time since
    /// the press is subtracted (never below zero).
    func testDeferredDeselectWaitsForTheIntervalFromThePress() {
        struct Case {
            let pressedAt: TimeInterval?
            let now: TimeInterval
            let expectedDelay: Double
        }
        let cases = [
            Case(pressedAt: 100, now: 100.1, expectedDelay: 0.4),
            Case(pressedAt: 100, now: 100, expectedDelay: 0.5),
            Case(pressedAt: 100, now: 101, expectedDelay: 0),
            Case(pressedAt: nil, now: 100.1, expectedDelay: 0.5),
        ]
        for testCase in cases {
            spy = Spy()
            let spy = self.spy
            let model = MainSurfaceModel(
                home: "/Users/example", defaults: defaults, textSize: TextSizeStore(defaults: defaults),
                launchers: ConversationsLaunchers(
                    search: { arguments, _, completion in
                        spy.searches.append(Dispatched(arguments: arguments, completion: completion))
                        return ConversationsProcess(process: Process())
                    },
                    show: { _, _, _ in ConversationsProcess(process: Process()) },
                    index: { _, _, _, completion in
                        spy.indexCompletions.append(completion)
                        return ConversationsProcess(process: Process())
                    }),
                runCommand: { arguments, completion in spy.commands.append((arguments: arguments, completion: completion)) },
                schedule: { seconds, action in spy.scheduled.append((seconds: seconds, action: action)) },
                markReadSchedule: { _, _ in },
                doubleClickInterval: { 0.5 },
                uptime: { testCase.now })
            openPopover(model, delivering: ["a"])
            model.rowClicked(.conversation(sessionID: "a"))
            model.pointerDown(surface: .popover, surfaceWasKey: true, searchFieldFocused: false,
                              clickCount: 1, pressedAt: testCase.pressedAt)
            model.rowClicked(.conversation(sessionID: "a"))
            let name = "pressed \(String(describing: testCase.pressedAt)), now \(testCase.now)"
            XCTAssertEqual(spy.scheduled.count, 1, name)
            XCTAssertEqual(spy.scheduled.first?.seconds ?? -1, testCase.expectedDelay, accuracy: 1e-9, name)
            XCTAssertEqual(model.list.selection?.key, .conversation(sessionID: "a"), "\(name): not yet")
            spy.scheduled[0].action()
            XCTAssertNil(model.list.selection, name)
        }
    }

    /// Closing the surface cancels a pending deselect.
    func testClosingTheSurfaceCancelsThePendingDeselect() {
        let model = makeModel()
        openPopover(model, delivering: ["a"])
        model.rowClicked(.conversation(sessionID: "a"))
        model.pointerDown(surface: .popover, surfaceWasKey: true, searchFieldFocused: false, clickCount: 1)
        model.rowClicked(.conversation(sessionID: "a"))
        XCTAssertEqual(spy.scheduled.count, 1)
        model.surfaceDidHide(.popover)
        spy.scheduled[0].action()
        XCTAssertEqual(model.list.selection?.key, .conversation(sessionID: "a"))
    }

    /// Showing the other surface directly (`Open in window` / `Open in
    /// popover`) ends the old surface first: a pending deselect is
    /// cancelled, and the old surface's later close report changes nothing.
    func testSwitchingSurfacesDirectlyCancelsThePendingDeselect() {
        for (from, to) in [(MainSurface.popover, MainSurface.window), (.window, .popover)] {
            let name = "\(from) -> \(to)"
            let model = makeModel()
            model.surfaceDidShow(from)
            spy.indexCompletions.last?(0)
            spy.searches.last?.completion(ok(resultJSON(["a"])))
            model.rowClicked(.conversation(sessionID: "a"))
            model.pointerDown(surface: from, surfaceWasKey: true, searchFieldFocused: false, clickCount: 1)
            model.rowClicked(.conversation(sessionID: "a"))
            XCTAssertEqual(spy.scheduled.count, 1, name)
            model.surfaceDidShow(to)
            spy.scheduled[0].action()
            XCTAssertEqual(model.list.selection?.key, .conversation(sessionID: "a"), "\(name): the selection stays")
            model.surfaceDidHide(from)
            XCTAssertEqual(model.visibleSurface, to, "\(name): the old surface's close is a no-op")
            XCTAssertEqual(model.list.selection?.key, .conversation(sessionID: "a"), name)
        }
    }

    /// `Open in popover` runs in its order: close the window, save the
    /// form, show the popover.
    func testOpenInPopoverClosesTheWindowThenSavesTheFormThenShowsThePopover() {
        let model = makeModel()
        model.openInWindowClicked()
        var steps: [String] = []
        model.onCloseWindowForPopover = {
            steps.append("close window, form \(model.surfaceForm.rawValue)")
        }
        model.onShowPopoverFromWindow = {
            steps.append("show popover, saved \(self.defaults.string(forKey: MainSurfaceDefaultsKeys.surfaceForm) ?? "-")")
        }
        model.openInPopoverClicked()
        XCTAssertEqual(steps, ["close window, form window", "show popover, saved popover"])
    }

    /// Key-status reports and presses from the surface that is not on
    /// screen are ignored; the key status leaves the key hints and the
    /// bottom panel's buttons alone.
    func testKeyStatusAndPressReportsFollowTheVisibleSurface() {
        let model = makeModel()
        openPopover(model, delivering: ["a"])
        model.rowClicked(.conversation(sessionID: "a"))
        model.surfaceKeyChanged(surface: .window, isKey: false)
        XCTAssertTrue(model.list.isSurfaceKey, "the hidden window's report is ignored")
        model.pointerDown(surface: .window, surfaceWasKey: false, searchFieldFocused: false)
        XCTAssertNil(model.list.selectionActiveAtPointerDown, "the hidden window's press is ignored")
        model.surfaceKeyChanged(surface: .popover, isKey: false)
        XCTAssertFalse(model.list.isSelectionActive)
        XCTAssertEqual(model.list.footerHints, [.move], "hints follow the search field only")
        XCTAssertNotNil(model.list.listBottomPanel?.buttons, "the buttons follow the search field only")
        // A key event comes from the key window only.
        XCTAssertEqual(key(model, .escape, surface: .popover, searchFieldFocused: false), .consumed)
        XCTAssertTrue(model.list.isSurfaceKey)
        XCTAssertTrue(model.list.isSelectionActive)
    }

    func testInitialFocusFollowsThePage() {
        let model = makeModel()
        openPopover(model, delivering: ["a"])
        let search = model.searchFocusRequests[.popover] ?? 0
        model.requestInitialFocus()
        XCTAssertEqual(model.searchFocusRequests[.popover], search + 1)
        XCTAssertNil(model.searchFocusRequests[.window], "a popover request never reaches the window")
        openDetailPage(model, .conversation(sessionID: "a"))
        XCTAssertEqual(model.paneFocusRequests[.popover], 1, "opening the detail page focuses the pane")
        let pane = model.paneFocusRequests[.popover] ?? 0
        model.requestInitialFocus()
        XCTAssertEqual(model.paneFocusRequests[.popover], pane + 1)
        let searchBeforeBack = model.searchFocusRequests[.popover] ?? 0
        let focusListBeforeBack = spy.focusListSurfaces.count
        model.backClicked()
        XCTAssertEqual(model.searchFocusRequests[.popover], searchBeforeBack, "back never focuses the search field")
        XCTAssertEqual(spy.focusListSurfaces.count, focusListBeforeBack + 1, "back to the list focuses the list")
        // ⌘F from the detail page: back to the list page, then the search field.
        openDetailPage(model, .conversation(sessionID: "a"))
        XCTAssertEqual(key(model, .other(charactersIgnoringModifiers: "f"), [.command]), .consumed)
        XCTAssertEqual(model.list.page, .list)
        XCTAssertEqual(model.searchFocusRequests[.popover], searchBeforeBack + 1)
    }

    // MARK: - Stars, pin, message line

    func testStarsPersistToTheInjectedDefaults() {
        let model = makeModel()
        openPopover(model, delivering: ["a", "b", "c"])
        model.starClicked(sessionID: "c")
        model.starClicked(sessionID: "a")
        XCTAssertEqual(defaults.object(forKey: MainSurfaceDefaultsKeys.starredSessionList) as? [String], ["c", "a"],
                       "the ordered list, a new star at the end")
        XCTAssertNil(defaults.object(forKey: MainSurfaceDefaultsKeys.starredSessionIDs), "the unordered key is not written")
        XCTAssertEqual(model.list.starredRows.map(\.sessionID), ["c", "a"])
        XCTAssertEqual(model.list.recentRows.map(\.sessionID), ["b"])
        XCTAssertNil(model.list.selection)
        // A new model reads the stars back, in order.
        let reloaded = makeModel()
        XCTAssertEqual(reloaded.list.stars, ["c", "a"])
    }

    func testUnorderedStarsAreSavedNewestFirstWithoutRemovingTheUnorderedValue() {
        defaults.set(["b", "c"], forKey: MainSurfaceDefaultsKeys.starredSessionIDs)
        let model = makeModel()
        XCTAssertTrue(model.list.stars.isUnordered)
        openPopover(model, delivering: ["a", "b", "c"])
        XCTAssertEqual(defaults.object(forKey: MainSurfaceDefaultsKeys.starredSessionList) as? [String], ["b", "c"])
        XCTAssertEqual(defaults.stringArray(forKey: MainSurfaceDefaultsKeys.starredSessionIDs), ["b", "c"],
                       "the unordered value stays")
        XCTAssertEqual(makeModel().list.stars, ["b", "c"])
    }

    func testCollapsedSectionsPersistToTheInjectedDefaults() {
        let model = makeModel()
        openPopover(model, delivering: ["a", "b"])
        model.starClicked(sessionID: "a")
        model.pointerDown(surface: .popover, surfaceWasKey: true, searchFieldFocused: false, clickCount: 1)
        model.headingClicked(.recent)
        model.pointerDown(surface: .popover, surfaceWasKey: true, searchFieldFocused: false, clickCount: 1)
        model.headingClicked(.history)
        XCTAssertEqual(defaults.object(forKey: MainSurfaceDefaultsKeys.collapsedSections) as? [String],
                       ["history", "recent"])
        XCTAssertEqual(model.list.headings.map(\.isOpen), [false])
        // The popover and the window share the model; a new model (a
        // relaunch) reads the closed headings back.
        let reloaded = makeModel()
        XCTAssertEqual(reloaded.list.collapsedSections, [.history, .recent])
        reloaded.headingClicked(.history)
        reloaded.headingClicked(.recent)
        XCTAssertEqual(reloaded.list.collapsedSections, [])
        XCTAssertEqual(defaults.object(forKey: MainSurfaceDefaultsKeys.collapsedSections) as? [String], [],
                       "reopening is remembered too")
    }

    // MARK: - Sections and the row drag (§4.5 "collapsing sections" / "row drag")

    func testAHeadingClickOnANonKeyWindowMakesItKeyAndToggles() {
        let model = makeModel()
        var madeKey: [MainSurface] = []
        model.onMakeSurfaceKey = { madeKey.append($0) }
        model.surfaceDidShow(.window)
        spy.indexCompletions.last?(0)
        spy.searches.last?.completion(ok(resultJSON(["a", "b"])))
        model.surfaceKeyChanged(surface: .window, isKey: false)
        model.pointerDown(surface: .window, surfaceWasKey: false, searchFieldFocused: true, clickCount: 1)
        model.headingClicked(.history)
        XCTAssertEqual(madeKey, [.window], "the same click makes the window key")
        XCTAssertEqual(model.list.collapsedSections, [.history], "and toggles the section")
        XCTAssertTrue(spy.focusListSurfaces.isEmpty, "the keyboard focus stays where it was")
    }

    /// A press on a row of the popover that moves 4pt.
    private func dragRow(_ model: MainSurfaceModel, _ key: UnifiedRowKey, clickCount: Int = 1) {
        model.pointerDown(surface: .popover, surfaceWasKey: true, searchFieldFocused: false, clickCount: clickCount)
        model.rowPressed(key, clickCount: clickCount, onStar: false, x: 50, y: 50)
        model.rowPressDragged(x: 50, y: 46)
    }

    func testEscDuringARowDragCancelsTheDragAndKeepsThePopoverOpen() {
        let model = makeModel()
        openPopover(model, delivering: ["a", "b"])
        model.starClicked(sessionID: "a")
        dragRow(model, .conversation(sessionID: "a"))
        XCTAssertNotNil(model.list.cardDrag)
        XCTAssertEqual(key(model, .downArrow), .consumed, "other keys do nothing during a drag")
        XCTAssertEqual(model.list.selection?.key, .conversation(sessionID: "a"))
        XCTAssertEqual(key(model, .escape), .consumed)
        XCTAssertNil(model.list.cardDrag)
        XCTAssertEqual(spy.closePopoverCount, 0, "Esc cancels the drag only")
        XCTAssertEqual(key(model, .escape), .consumed)
        XCTAssertEqual(spy.closePopoverCount, 1, "after the drag Esc closes the popover again")
    }

    func testADropPersistsTheOrderAndASearchCancelsADrag() {
        let model = makeModel()
        openPopover(model, delivering: ["a", "b", "c"])
        model.starClicked(sessionID: "a")
        model.starClicked(sessionID: "b")
        dragRow(model, .conversation(sessionID: "c"))
        model.cardDragMoved(.element(.row(.conversation(sessionID: "a")), upperHalf: true))
        model.cardDragEnded()
        XCTAssertEqual(defaults.object(forKey: MainSurfaceDefaultsKeys.starredSessionList) as? [String], ["c", "a", "b"])
        XCTAssertEqual(model.list.starredRows.map(\.sessionID), ["c", "a", "b"])

        dragRow(model, .conversation(sessionID: "b"))
        XCTAssertNotNil(model.list.cardDrag)
        model.query = "x"
        XCTAssertNotNil(model.list.cardDrag, "a query without a valid term starts no search")
        model.query = "xy"
        XCTAssertNil(model.list.cardDrag, "a search starting cancels the drag")
        XCTAssertTrue(model.list.isSearching, "searching from the valid text, before any result")
        model.query = ""
        XCTAssertFalse(model.list.isSearching, "and not after it, before the empty-query result")
    }

    func testTheReasonARowCannotBeDraggedGoesAwayAfterTheScheduledTime() {
        let model = makeModel()
        openPopover(model, delivering: ["a"])
        let before = spy.scheduled.count
        dragRow(model, .conversation(sessionID: "a"))
        XCTAssertNil(model.list.cardDrag)
        XCTAssertEqual(model.list.dragRefusal?.text, "Click the star to add it to Starred")
        XCTAssertEqual(spy.scheduled.count, before + 1)
        XCTAssertEqual(spy.scheduled.last?.seconds, 2, "§9")
        spy.scheduled.last?.action()
        XCTAssertNil(model.list.dragRefusal)
    }

    func testKeepOnTopPersistsAndNotifies() {
        let model = makeModel()
        XCTAssertFalse(model.keepOnTop, "default OFF")
        model.keepOnTopClicked()
        XCTAssertTrue(model.keepOnTop)
        XCTAssertEqual(defaults.object(forKey: MainSurfaceDefaultsKeys.windowKeepOnTop) as? Bool, true)
        XCTAssertEqual(spy.keepOnTopChanges, [true])
        XCTAssertTrue(makeModel().keepOnTop)
    }

    func testFullScreenStateIsTheWindowsOnly() {
        let model = makeModel()
        XCTAssertFalse(model.windowFullScreen, "default: not full screen")
        XCTAssertEqual(model.windowFullScreenTopInset, 0)
        model.windowTopInsetChanged(28)
        XCTAssertEqual(model.topInset(for: .window), 0, "no inset outside full screen")

        model.windowFullScreenChanged(true)
        model.windowTopInsetChanged(28)
        XCTAssertTrue(model.isFullScreen(.window))
        XCTAssertFalse(model.isFullScreen(.popover), "the popover is never full screen")
        XCTAssertEqual(model.topInset(for: .window), 28)
        XCTAssertEqual(model.topInset(for: .popover), 0)
        model.windowTopInsetChanged(-4)
        XCTAssertEqual(model.topInset(for: .window), 0, "never negative")

        model.windowTopInsetChanged(28)
        model.windowFullScreenChanged(false)
        XCTAssertFalse(model.isFullScreen(.window))
        XCTAssertEqual(model.topInset(for: .window), 0, "leaving full screen drops the inset")
    }

    /// A window closed while in full screen reports no exit: the state
    /// resets with the close.
    func testClosingTheWindowResetsTheFullScreenState() {
        let model = makeModel()
        model.surfaceDidShow(.window)
        model.windowFullScreenChanged(true)
        model.windowTopInsetChanged(28)
        model.surfaceDidHide(.window)
        XCTAssertFalse(model.windowFullScreen)
        XCTAssertEqual(model.windowFullScreenTopInset, 0)
    }

    func testWarningsAreStoredForTheFooter() {
        let model = makeModel()
        model.setWarnings([.disconnected, .automationPermission])
        XCTAssertEqual(model.warnings.map(\.text), [
            "Disconnected from daemon \u{2014} reconnecting\u{2026}",
            "Automation permission needed (run \"shiibar-cc doctor\")",
        ])
    }

    // MARK: - Text size (§4.5 "text size")

    private func storedTextSize() -> Any? {
        defaults.object(forKey: TextSizeStore.defaultsKey)
    }

    func testTextSizeKeysSaveTheValueAndSendItToThePane() {
        let model = makeModel()
        openPopover(model, delivering: ["a"])
        XCTAssertEqual(model.webPane.textSizePoints, 13, "the pane starts at the stored value")
        let cmd: ListKeyModifiers = [.command]
        XCTAssertEqual(key(model, .other(charactersIgnoringModifiers: "="), cmd), .consumed)
        XCTAssertEqual(model.textSize.size.points, 14)
        XCTAssertEqual(storedTextSize() as? Int, 14, "saved as a whole number")
        XCTAssertEqual(model.webPane.textSizePoints, 14)
        XCTAssertEqual(key(model, .other(charactersIgnoringModifiers: "+"), [.command, .shift]), .consumed)
        XCTAssertEqual(model.textSize.size.points, 15)
        XCTAssertEqual(key(model, .other(charactersIgnoringModifiers: "-"), cmd, surface: .popover, searchFieldFocused: true), .consumed,
                       "the keys work while the search field has focus")
        XCTAssertEqual(model.textSize.size.points, 14)
        XCTAssertEqual(model.webPane.textSizePoints, 14)
        XCTAssertEqual(key(model, .other(charactersIgnoringModifiers: "0"), cmd), .consumed)
        XCTAssertEqual(model.textSize.size.points, 13)
        XCTAssertEqual(storedTextSize() as? Int, 13)
        XCTAssertEqual(model.webPane.textSizePoints, 13)
    }

    func testTextSizeKeysAtTheEndsChangeNothingButAreConsumed() {
        let cmd: ListKeyModifiers = [.command]
        let cases: [(String, Double, String, Int)] = [
            ("⌘= at 18 (stored 20 reads as 18)", 20, "=", 18),
            ("⌘− at 9", 9, "-", 9),
            ("⌘0 at 13", 13, "0", 13),
        ]
        for (name, stored, character, points) in cases {
            defaults = InMemoryDefaults()
            defaults.set(stored, forKey: TextSizeStore.defaultsKey)
            let model = makeModel()
            openPopover(model, delivering: ["a"])
            XCTAssertEqual(model.webPane.textSizePoints, Double(points), name)
            var emissions = 0
            let subscription = model.textSize.$size.dropFirst().sink { _ in emissions += 1 }
            XCTAssertEqual(key(model, .other(charactersIgnoringModifiers: character), cmd), .consumed, name)
            subscription.cancel()
            XCTAssertEqual(model.textSize.size.points, points, name)
            XCTAssertEqual(emissions, 0, "\(name): nothing is published, so nothing reaches the pane")
            XCTAssertEqual(model.webPane.textSizePoints, Double(points), name)
            XCTAssertEqual(storedTextSize() as? Double, stored, "\(name): the stored entry is not rewritten")
        }
    }

    /// §9: the two-column threshold is fixed at 600pt, so a text size
    /// change never changes the column count; the width alone does, with
    /// the switching rules unchanged.
    func testTextSizeChangeKeepsTheColumnsAndTheWidthFlipsThem() {
        let model = makeModel()
        model.windowWidthChanged(600)
        model.windowDidBecomeKey()
        XCTAssertEqual(model.list.columns, .two, "600 is two columns")
        spy.indexCompletions.last?(0)
        spy.searches.last?.completion(ok(resultJSON(["a", "b"])))
        model.rowClicked(.conversation(sessionID: "b"))

        for _ in 0..<5 { model.textSize.increase() }
        XCTAssertEqual(model.list.columns, .two, "18: still two columns")
        for _ in 0..<9 { model.textSize.decrease() }
        XCTAssertEqual(model.list.columns, .two, "9: still two columns")
        model.textSize.reset()

        model.windowWidthChanged(599)
        XCTAssertEqual(model.list.columns, .one)
        XCTAssertEqual(model.list.page, .list, "two -> one column shows the list page")
        XCTAssertEqual(model.list.selection?.key, .conversation(sessionID: "b"), "the selection is kept")

        // From the detail page, widening into two columns keeps the same
        // conversation selected.
        openDetailPage(model, .conversation(sessionID: "a"))
        XCTAssertEqual(model.list.page, .detail)
        model.windowWidthChanged(600)
        XCTAssertEqual(model.list.columns, .two)
        XCTAssertEqual(model.list.selection?.key, .conversation(sessionID: "a"))
    }

    // MARK: - Settings > Terminal (§4.5 "Settings window" > Terminal, §4.6 "Resume and Branch")

    /// The installed apps the Terminal setting's lookup sees, by bundle id,
    /// and how many lookups ran (no real app is looked up).
    private final class InstalledApps {
        var apps: [String: InstalledTerminalApp] = [:]
        var lookups = 0
    }

    private func attachTerminalSetting(
        _ model: MainSurfaceModel, stored: ResumeTerminal, installed: InstalledApps, center: NotificationCenter
    ) -> ResumeTerminalSetting {
        ResumeTerminal.save(stored, to: defaults)
        let setting = ResumeTerminalSetting(defaults: defaults, lookup: { id in
            installed.lookups += 1
            return installed.apps[id]
        }, center: center)
        setting.attach(to: model)
        return setting
    }

    /// Resume and Branch pass the Settings value as `--terminal`; the
    /// terminals of the sessions in the agent list play no part, and a new
    /// pick applies to the next click.
    func testResumeAndBranchPassTheTerminalSettingWhateverTheAgentListShows() {
        let model = makeModel()
        let installed = InstalledApps()
        installed.apps["com.mitchellh.ghostty"] = InstalledTerminalApp(shortVersion: "1.4.0")
        let setting = attachTerminalSetting(model, stored: .ghostty, installed: installed, center: NotificationCenter())
        model.agentsUpdated([
            agent("apple-terminal:/dev/ttys001", session: "s1"),
            agent("iterm2:w0t0p0:U2", session: "s2"),
            agent("process:4242", session: "s3"),
        ])
        openPopover(model, delivering: ["a"])
        guard let history = panelButtons(model, selecting: .conversation(sessionID: "a")) else { return }
        model.buttonClicked(history.primary)
        XCTAssertEqual(spy.commands.last?.arguments,
                       ["resume", "--cwd", "/Users/example/demo", "--terminal", "ghostty", "a"])
        guard let undrivable = panelButtons(model, selecting: .running(target: "process:4242")) else { return }
        model.buttonClicked(undrivable.branch)
        XCTAssertEqual(spy.commands.last?.arguments,
                       ["resume", "--cwd", "/Users/example/demo", "--terminal", "ghostty", "--fork", "s3"])

        setting.select(.appleTerminal)
        guard let running = panelButtons(model, selecting: .running(target: "iterm2:w0t0p0:U2")) else { return }
        model.buttonClicked(running.branch)
        XCTAssertEqual(spy.commands.last?.arguments,
                       ["resume", "--cwd", "/Users/example/demo", "--terminal", "apple-terminal", "--fork", "s2"])
    }

    /// While the chosen terminal cannot be used, Resume and Branch are
    /// disabled with the reason (also over a missing cwd's disabled Resume),
    /// and neither a click, Enter nor ⌘Enter runs them. Jump stays.
    func testUnusableTerminalDisablesResumeAndBranchWithTheReason() {
        let model = makeModel()
        let installed = InstalledApps()
        let setting = attachTerminalSetting(model, stored: .iterm2, installed: installed, center: NotificationCenter())
        let tooltip = "iTerm2 is not installed \u{2014} choose a terminal in Settings"
        model.agentsUpdated([agent("iterm2:w0t0p0:U1", session: "s1")])
        model.surfaceDidShow(.popover)
        spy.indexCompletions.last?(0)
        spy.searches[0].completion(ok(
            #"{"conversations":[\#(summaryJSON("a")),\#(summaryJSON("b", cwd: nil))]}"#))

        guard let history = panelButtons(model, selecting: .conversation(sessionID: "a")) else { return }
        XCTAssertEqual(history.primary, RowButton(kind: .resume, invocation: nil, tooltip: tooltip))
        XCTAssertEqual(history.branch, RowButton(kind: .branch, invocation: nil, tooltip: tooltip))
        model.buttonClicked(history.primary)
        model.buttonClicked(history.branch)
        _ = key(model, .returnKey)
        _ = key(model, .returnKey, .command)
        XCTAssertEqual(spy.commands.count, 0, "nothing runs while the terminal cannot be used")

        guard let noCwd = panelButtons(model, selecting: .conversation(sessionID: "b")) else { return }
        XCTAssertEqual(noCwd.primary.tooltip, tooltip, "the terminal's reason wins over the missing cwd")
        XCTAssertEqual(noCwd.branch.tooltip, tooltip)

        guard let running = panelButtons(model, selecting: .running(target: "iterm2:w0t0p0:U1")) else { return }
        XCTAssertEqual(running.primary.invocation, .jump(target: "iterm2:w0t0p0:U1"), "Jump is not affected")
        XCTAssertFalse(running.branch.isEnabled)

        // Installed meanwhile: the next show decides again and enables them.
        installed.apps["com.googlecode.iterm2"] = InstalledTerminalApp(shortVersion: "3.7.6")
        model.surfaceDidHide(.popover)
        model.surfaceDidShow(.popover)
        guard let enabled = panelButtons(model, selecting: .conversation(sessionID: "b")) else { return }
        XCTAssertEqual(enabled.primary, RowButton(kind: .resume, invocation: nil, tooltip: "Resume"),
                       "back to the missing cwd's disabled Resume")
        guard let again = panelButtons(model, selecting: .conversation(sessionID: "a")) else { return }
        XCTAssertTrue(again.primary.isEnabled)
        XCTAssertTrue(again.branch.isEnabled)
        XCTAssertEqual(setting.availability, .available)
    }

    /// Availability is decided again when a surface shows (after the
    /// show's own work) and when the app becomes active (§4.5).
    func testAvailabilityIsDecidedAgainOnSurfaceShowAndAppActivation() {
        let model = makeModel()
        let installed = InstalledApps()
        let center = NotificationCenter()
        let setting = attachTerminalSetting(model, stored: .ghostty, installed: installed, center: center)
        XCTAssertEqual(setting.availability, .notInstalled(.ghostty))
        XCTAssertEqual(model.list.resumeTerminalAvailability, .notInstalled(.ghostty))

        installed.apps["com.mitchellh.ghostty"] = InstalledTerminalApp(shortVersion: "1.3.1")
        let before = installed.lookups
        model.surfaceDidShow(.popover)
        XCTAssertEqual(spy.surfaceShownCount, 1, "the show's existing work still runs")
        XCTAssertGreaterThan(installed.lookups, before)
        XCTAssertEqual(setting.availability, .ghosttyTooOld)
        XCTAssertEqual(model.list.resumeTerminalAvailability, .ghosttyTooOld)

        installed.apps["com.mitchellh.ghostty"] = InstalledTerminalApp(shortVersion: "1.4.0")
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(setting.availability, .available)
        XCTAssertEqual(model.list.resumeTerminalAvailability, .available)
    }
}

/// Opens a row's detail page the way the user does in one column: a click
/// selects the row (skipped when it is already selected, where a click would
/// deselect it), then the bottom panel's View button opens the page (§4.5
/// "opening the detail page").
@MainActor
private func openDetailPage(_ model: MainSurfaceModel, _ key: UnifiedRowKey) {
    if model.list.selection?.key != key {
        model.rowClicked(key)
    }
    model.viewClicked()
}
