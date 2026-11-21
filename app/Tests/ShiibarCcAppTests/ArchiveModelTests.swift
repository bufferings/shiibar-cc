import AppKit
import ShiibarCcCore
import XCTest
@testable import ShiibarCcApp

/// Archive through the shared model (DESIGN.md §4.6 "Archive" / "Archive
/// view" / "conversation pane", §4.5 "⌄ menu"): the more button's menu
/// (never shown — a spy stands for it), the saved archived list, the
/// Archive view's search field and scroll requests, and the pane's `No
/// conversation to show`. Every outward action is a spy; defaults are in
/// memory.
@MainActor
final class ArchiveModelTests: XCTestCase {
    private final class Spy {
        var searches: [(arguments: [String], completion: @MainActor (CLIRunResult) -> Void)] = []
        var shows: [(arguments: [String], completion: @MainActor (CLIRunResult) -> Void)] = []
        /// The index on open (`--json`).
        var indexCompletions: [@MainActor (Int32) -> Void] = []
        /// The conversation pane's own index runs (no `--json`).
        var paneIndexCompletions: [@MainActor (Int32) -> Void] = []
        var commands: [(arguments: [String], completion: @MainActor (Int32) -> Void)] = []
        var rowMenus: [(items: [RowMenuItem], completion: @MainActor (RowMenuCommand?) -> Void)] = []
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
                spy.searches.append((arguments, completion))
                return ConversationsProcess(process: Process())
            },
            show: { arguments, _, completion in
                spy.shows.append((arguments, completion))
                return ConversationsProcess(process: Process())
            },
            index: { arguments, _, _, completion in
                if arguments.contains("--json") {
                    spy.indexCompletions.append(completion)
                } else {
                    spy.paneIndexCompletions.append(completion)
                }
                return ConversationsProcess(process: Process())
            }
        )
        let model = MainSurfaceModel(
            home: "/Users/example",
            defaults: defaults,
            textSize: TextSizeStore(defaults: defaults),
            launchers: launchers,
            runCommand: { arguments, completion in spy.commands.append((arguments, completion)) },
            schedule: { _, _ in }
        )
        model.onPresentRowMenu = { items, _, _, completion in spy.rowMenus.append((items, completion)) }
        return model
    }

    private func resultJSON(_ ids: [String], live: Set<String> = []) -> String {
        let items = ids.map {
            #"{"session_id":"\#($0)","cwd":"/Users/example/demo","title":"t","updated_at":1,"live":\#(live.contains($0)),"last_prompt":null}"#
        }
        return #"{"conversations":[\#(items.joined(separator: ","))]}"#
    }

    private func ok(_ stdout: String) -> CLIRunResult { CLIRunResult(exitCode: 0, stdout: stdout, stderr: "") }

    private func openPopover(_ model: MainSurfaceModel, delivering ids: [String]) {
        model.surfaceDidShow(.popover)
        spy.indexCompletions.last?(0)
        spy.searches.last?.completion(ok(resultJSON(ids)))
    }

    private func key(_ id: String) -> UnifiedRowKey { .conversation(sessionID: id) }

    private func storedArchive() -> [String]? {
        defaults.object(forKey: MainSurfaceDefaultsKeys.archivedSessionList) as? [String]
    }

    // MARK: - The more button's menu

    func testTheMoreButtonOpensTheMenuAndArchiveIsSavedWithoutANewSearch() {
        let model = makeModel()
        openPopover(model, delivering: ["a", "b"])
        let searches = spy.searches.count
        model.moreButtonClicked(key("a"), anchor: NSView())
        XCTAssertEqual(spy.rowMenus.map(\.items), [[RowMenuItem(command: .archive, title: "Archive", isEnabled: true)]])
        XCTAssertEqual(model.openRowMenuKey, key("a"), "the box shows its open-menu ground")
        XCTAssertNil(model.list.selection, "the click selects nothing")
        spy.rowMenus[0].completion(.archive)
        XCTAssertNil(model.openRowMenuKey)
        XCTAssertEqual(storedArchive(), ["a"])
        XCTAssertEqual(model.list.recentRows.map(\.sessionID), ["b"])
        XCTAssertEqual(spy.searches.count, searches, "shown at once, without a new search")
    }

    func testClosingTheMenuWithoutAChoiceChangesNothing() {
        let model = makeModel()
        openPopover(model, delivering: ["a"])
        model.moreButtonClicked(key("a"), anchor: NSView())
        spy.rowMenus[0].completion(nil)
        XCTAssertNil(model.openRowMenuKey)
        XCTAssertNil(storedArchive())
        XCTAssertEqual(model.list.recentRows.map(\.sessionID), ["a"])
    }

    func testALiveRowsMenuHasADisabledArchive() {
        let model = makeModel()
        model.surfaceDidShow(.popover)
        spy.indexCompletions.last?(0)
        spy.searches.last?.completion(ok(resultJSON(["a"], live: ["a"])))
        model.moreButtonClicked(key("a"), anchor: NSView())
        XCTAssertEqual(spy.rowMenus.first?.items, [RowMenuItem(command: .archive, title: "Archive", isEnabled: false)])
    }

    func testWithoutAnAnchorNoMenuOpens() {
        let model = makeModel()
        openPopover(model, delivering: ["a"])
        model.moreButtonClicked(key("a"), anchor: nil)
        XCTAssertTrue(spy.rowMenus.isEmpty)
        XCTAssertNil(model.openRowMenuKey)
    }

    // MARK: - The Archive view through the model

    func testTheArchiveViewKeepsTheQueryAndSwitchesThePlaceholder() {
        defaults.set(["b"], forKey: MainSurfaceDefaultsKeys.archivedSessionList)
        let model = makeModel()
        openPopover(model, delivering: ["a", "b"])
        model.query = "x"
        XCTAssertEqual(model.list.searchPlaceholder, "Search (2+ characters)")
        model.archivedMenuItemChosen()
        XCTAssertTrue(model.list.isArchiveView)
        XCTAssertEqual(model.query, "x", "switching keeps the search text")
        XCTAssertEqual(model.list.searchPlaceholder, "Search archived")
        XCTAssertEqual(model.list.archivedRows.map(\.sessionID), ["b"])
        model.archiveHeadingClicked()
        XCTAssertFalse(model.list.isArchiveView)
        XCTAssertEqual(model.query, "x")
    }

    func testUnarchiveFromTheArchiveViewMenu() {
        defaults.set(["b", "a"], forKey: MainSurfaceDefaultsKeys.archivedSessionList)
        let model = makeModel()
        openPopover(model, delivering: ["a", "b", "c"])
        model.archivedMenuItemChosen()
        model.moreButtonClicked(key("a"), anchor: NSView())
        XCTAssertEqual(spy.rowMenus.first?.items, [RowMenuItem(command: .unarchive, title: "Unarchive", isEnabled: true)])
        spy.rowMenus[0].completion(.unarchive)
        XCTAssertEqual(storedArchive(), ["b"])
        XCTAssertEqual(model.list.archivedRows.map(\.sessionID), ["b"])
    }

    /// §4.6: the archived list survives a relaunch (a new model on the same
    /// defaults).
    func testArchivedConversationsSurviveARelaunch() {
        let first = makeModel()
        openPopover(first, delivering: ["a", "b"])
        first.moreButtonClicked(key("a"), anchor: NSView())
        spy.rowMenus[0].completion(.archive)
        let relaunched = makeModel()
        openPopover(relaunched, delivering: ["a", "b"])
        XCTAssertEqual(relaunched.list.archived.sessionIDs, ["a"])
        XCTAssertEqual(relaunched.list.recentRows.map(\.sessionID), ["b"])
    }

    /// §4.6 "Archive view": not remembered — closing the popover, and a
    /// switch to the window, show the normal list next time.
    func testClosingTheSurfaceReturnsToTheNormalList() {
        defaults.set(["a"], forKey: MainSurfaceDefaultsKeys.archivedSessionList)
        let model = makeModel()
        openPopover(model, delivering: ["a", "b"])
        model.archivedMenuItemChosen()
        model.surfaceDidHide(.popover)
        XCTAssertFalse(model.list.isArchiveView)
        model.surfaceDidShow(.popover)
        model.archivedMenuItemChosen()
        model.surfaceDidShow(.window)
        XCTAssertFalse(model.list.isArchiveView, "the form switch closes the popover first")
    }

    /// §4.6 "Archive view": shown from its top; back on the normal list, its
    /// scroll position returns. Until the list has scrolled for the switch,
    /// no scroll position is recorded over the one just set.
    func testScrollRequestsAroundTheArchiveView() {
        defaults.set(["a"], forKey: MainSurfaceDefaultsKeys.archivedSessionList)
        let model = makeModel()
        openPopover(model, delivering: ["a", "b", "c"])
        let normal = ListScrollAnchor(key: key("c"), offset: 12)
        model.listScrollAnchor = normal
        model.archivedMenuItemChosen()
        XCTAssertEqual(model.scrollToTopRequest, 1)
        XCTAssertNil(model.listScrollAnchor)
        XCTAssertTrue(model.isListScrollRestorePending)
        model.listScrollRestoreDone()
        model.listScrollAnchor = ListScrollAnchor(key: key("a"), offset: 3)
        model.archivedMenuItemChosen()
        XCTAssertEqual(model.scrollRestoreRequest, 1)
        XCTAssertEqual(model.scrollToTopRequest, 1)
        XCTAssertEqual(model.listScrollAnchor, normal)
        XCTAssertTrue(model.isListScrollRestorePending)
        model.listScrollRestoreDone()
        XCTAssertFalse(model.isListScrollRestorePending)
    }

    /// Back from the Archive view when the normal list never recorded a
    /// position, or its row left the normal list: the top, not the Archive
    /// view's offset.
    func testReturningWithoutAUsableAnchorScrollsToTheTop() {
        defaults.set(["a"], forKey: MainSurfaceDefaultsKeys.archivedSessionList)
        let model = makeModel()
        openPopover(model, delivering: ["a", "b", "c"])
        model.archivedMenuItemChosen()
        model.listScrollAnchor = ListScrollAnchor(key: key("a"), offset: 3)
        model.archivedMenuItemChosen()
        XCTAssertEqual(model.scrollToTopRequest, 2, "never scrolled: the top")
        XCTAssertEqual(model.scrollRestoreRequest, 0)
        XCTAssertNil(model.listScrollAnchor)

        model.listScrollAnchor = ListScrollAnchor(key: key("c"), offset: 5)
        model.archivedMenuItemChosen()
        // While the Archive view is shown, a new browse result no longer
        // holds the anchor's conversation.
        model.refresh()
        spy.searches.last?.completion(ok(resultJSON(["a", "b"])))
        model.archivedMenuItemChosen()
        XCTAssertFalse(model.list.isArchiveView)
        XCTAssertEqual(model.scrollToTopRequest, 4, "its row left the normal list: the top")
        XCTAssertEqual(model.scrollRestoreRequest, 0)
        XCTAssertNil(model.listScrollAnchor)
    }

    // MARK: - The search field's placeholder

    func testSearchFieldPlaceholder() {
        XCTAssertEqual(ConversationsSearchField.placeholder, "Search (2+ characters)")
        let view = SearchFieldView()
        XCTAssertEqual(view.textField.placeholderString, "Search (2+ characters)")
        view.placeholder = "Search archived"
        XCTAssertEqual(view.textField.placeholderString, "Search archived")
        XCTAssertEqual(view.placeholder, "Search archived")
    }

    // MARK: - The row menu as built (never shown)

    func testRowMenuAsBuilt() {
        let handler = RowMenuHandler()
        let menu = handler.menu(for: [.archive(isEnabled: false)])
        XCTAssertFalse(menu.autoenablesItems, "the flag keeps the value of the moment the menu opened")
        XCTAssertEqual(menu.items.map(\.title), ["Archive"])
        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertTrue(menu.items[0].target === handler)
        XCTAssertEqual(menu.items[0].keyEquivalent, "")
        XCTAssertNil(handler.chosen)
        let unarchive = handler.menu(for: [.unarchive])
        XCTAssertEqual(unarchive.items.map(\.title), ["Unarchive"])
        XCTAssertTrue(unarchive.items[0].isEnabled)
        handler.choose(unarchive.items[0])
        XCTAssertEqual(handler.chosen, .unarchive)
    }

    /// The menu's right edge is the button's right edge; its top is 4pt
    /// below the button (screen coordinates, y up).
    func testRowMenuPlacement() {
        let origin = RowMenuPlacement.origin(anchorScreenRect: NSRect(x: 300, y: 500, width: 20, height: 20),
                                             menuWidth: 120)
        XCTAssertEqual(origin, NSPoint(x: 200, y: 496))
    }

    // MARK: - The pane's `No conversation to show` (§4.6)

    private func agent(_ target: String, session: String) -> Agent {
        Agent(target: target, status: .idle, unreviewed: false, sessionId: session,
              cwd: "/Users/example/demo", task: nil, message: nil, createdAt: 1, since: 0, lastSeen: 0)
    }

    func testARunningRowsShowExitTwoShowsNoConversationAndReruns() {
        let model = makeModel()
        model.agentsUpdated([agent("iterm2:T1", session: "s1")])
        openPopover(model, delivering: ["a"])
        model.rowClicked(.running(target: "iterm2:T1"))
        model.viewClicked()
        // A Running row's conversation: index first, then show (§4.6).
        XCTAssertTrue(spy.shows.isEmpty)
        XCTAssertEqual(spy.paneIndexCompletions.count, 1)
        spy.paneIndexCompletions[0](0)
        XCTAssertEqual(spy.shows.map(\.arguments), [["conversations", "show", "s1", "--json"]])
        spy.shows[0].completion(CLIRunResult(exitCode: 2, stdout: "", stderr: ""))
        XCTAssertTrue(model.paneShowsNoConversation)
        XCTAssertNil(model.paneLoadError, "not the one-line error")
        XCTAssertEqual(ConversationPaneModel.noMessagesText, "No conversation to show")

        // Refresh runs show again, once its search has landed (the search
        // catches the index up; show reads it as it is). The line stays
        // while reloading and after a reload that fails.
        let searches = spy.searches.count
        model.refresh()
        XCTAssertEqual(spy.searches.count, searches + 1)
        XCTAssertEqual(spy.shows.count, 1, "not before the search result")
        spy.searches.last?.completion(ok(resultJSON(["a", "s1"])))
        XCTAssertEqual(spy.shows.count, 2, "after the search result")
        XCTAssertEqual(spy.shows[1].arguments, ["conversations", "show", "s1", "--json"])
        XCTAssertTrue(model.paneShowsNoConversation, "kept while reloading")
        spy.shows[1].completion(CLIRunResult(exitCode: 2, stdout: "", stderr: ""))
        XCTAssertTrue(model.paneShowsNoConversation)
        XCTAssertNil(model.paneLoadError)

        // Choosing the row again runs index and show again.
        model.backClicked()
        model.viewClicked()
        XCTAssertEqual(spy.paneIndexCompletions.count, 2)
        spy.paneIndexCompletions[1](0)
        XCTAssertEqual(spy.shows.count, 3)
        spy.shows[2].completion(ok(#"{"session_id":"s1","cwd":"/Users/example/demo","title":"t","messages":[]}"#))
        XCTAssertFalse(model.paneShowsNoConversation)
        XCTAssertNil(model.paneLoadError)
    }

    /// The Running row ends and its selection moves to the History row with
    /// the same session_id: the pane loads it again instead of keeping
    /// `No conversation to show`.
    func testNoConversationDoesNotSurviveTheMoveToTheHistoryRow() {
        let model = makeModel()
        model.agentsUpdated([agent("iterm2:T1", session: "s1")])
        openPopover(model, delivering: ["a"])
        model.rowClicked(.running(target: "iterm2:T1"))
        model.viewClicked()
        spy.paneIndexCompletions.last?(0)
        spy.shows[0].completion(CLIRunResult(exitCode: 2, stdout: "", stderr: ""))
        XCTAssertTrue(model.paneShowsNoConversation)
        model.agentsUpdated([])
        XCTAssertEqual(spy.shows.count, 1, "awaiting the refetch: still the Running row")
        spy.searches.last?.completion(ok(resultJSON(["s1", "a"])))
        XCTAssertEqual(model.list.selection?.key, key("s1"))
        XCTAssertEqual(spy.shows.count, 2)
        XCTAssertEqual(spy.shows[1].arguments, ["conversations", "show", "s1", "--json"])
        XCTAssertFalse(model.paneShowsNoConversation)
    }

    func testAHistoryRowsShowExitTwoKeepsTheErrorLine() {
        let model = makeModel()
        openPopover(model, delivering: ["a"])
        model.rowClicked(key("a"))
        model.viewClicked()
        spy.shows[0].completion(CLIRunResult(exitCode: 2, stdout: "", stderr: ""))
        XCTAssertEqual(model.paneLoadError, MainSurfaceModel.unavailableText)
        XCTAssertFalse(model.paneShowsNoConversation)
        // Refresh reloads a History row's conversation too (§4.6 trigger 3);
        // a reload that fails keeps the error line.
        model.refresh()
        XCTAssertEqual(spy.shows.count, 1, "not before the search result")
        spy.searches.last?.completion(ok(resultJSON(["a"])))
        XCTAssertEqual(spy.shows.count, 2)
        XCTAssertEqual(model.paneLoadError, MainSurfaceModel.unavailableText, "kept while reloading")
        spy.shows[1].completion(CLIRunResult(exitCode: 2, stdout: "", stderr: ""))
        XCTAssertEqual(model.paneLoadError, MainSurfaceModel.unavailableText)
        XCTAssertFalse(model.paneShowsNoConversation)
    }

    func testAnArchiveViewRowsShowExitTwoKeepsTheErrorLine() {
        defaults.set(["a"], forKey: MainSurfaceDefaultsKeys.archivedSessionList)
        let model = makeModel()
        openPopover(model, delivering: ["a"])
        model.archivedMenuItemChosen()
        model.rowClicked(key("a"))
        model.viewClicked()
        spy.shows[0].completion(CLIRunResult(exitCode: 2, stdout: "", stderr: ""))
        XCTAssertEqual(model.paneLoadError, MainSurfaceModel.unavailableText)
        XCTAssertFalse(model.paneShowsNoConversation)
    }
}
