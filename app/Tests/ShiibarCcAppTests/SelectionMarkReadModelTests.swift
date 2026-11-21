import ShiibarCcCore
import XCTest
@testable import ShiibarCcApp

/// Lowering the unreviewed flag through the shared model (DESIGN.md §4.5
/// "operations that lower the unreviewed flag", "notification click",
/// §8.66, §9): the mark-read timer is the injected scheduler (fired by the
/// test, never by the clock), `seen` is the injected command runner, and
/// every other subprocess is a spy that never runs.
@MainActor
final class SelectionMarkReadModelTests: XCTestCase {
    private struct Command {
        let arguments: [String]
        let completion: @MainActor (Int32) -> Void
    }

    private final class Spy {
        var commands: [Command] = []
        var searches: [(arguments: [String], completion: @MainActor (CLIRunResult) -> Void)] = []
        var openIndexCompletions: [@MainActor (Int32) -> Void] = []
        /// The mark-read timer's scheduled answers.
        var markReadTimers: [(seconds: Double, action: @MainActor () -> Void)] = []
        var focusListSurfaces: [MainSurface] = []
    }

    private var spy = Spy()
    private var defaults = InMemoryDefaults()
    private let undrivable = "process:4242"
    private let jumpable = "iterm2:A"

    override func setUp() {
        super.setUp()
        defaults = InMemoryDefaults()
    }

    private func makeModel() -> MainSurfaceModel {
        spy = Spy()
        let spy = self.spy
        let launchers = ConversationsLaunchers(
            search: { arguments, _, completion in
                spy.searches.append((arguments: arguments, completion: completion))
                return ConversationsProcess(process: Process())
            },
            show: { _, _, _ in ConversationsProcess(process: Process()) },
            index: { arguments, _, _, completion in
                if arguments.contains("--json") { spy.openIndexCompletions.append(completion) }
                return ConversationsProcess(process: Process())
            }
        )
        let model = MainSurfaceModel(
            home: "/Users/example",
            defaults: defaults,
            textSize: TextSizeStore(defaults: defaults),
            launchers: launchers,
            runCommand: { arguments, completion in spy.commands.append(Command(arguments: arguments, completion: completion)) },
            schedule: { _, _ in },
            markReadSchedule: { seconds, action in spy.markReadTimers.append((seconds: seconds, action: action)) }
        )
        model.onFocusList = { spy.focusListSurfaces.append($0) }
        return model
    }

    private func agent(_ target: String, session: String, unreviewed: Bool, createdAt: Int64) -> Agent {
        Agent(target: target, status: .idle, unreviewed: unreviewed, sessionId: session,
              cwd: "/Users/example/demo", task: nil, message: nil, createdAt: createdAt, since: 0, lastSeen: 0)
    }

    private func agents(unreviewed: Bool = true) -> [Agent] {
        [agent(jumpable, session: "sa", unreviewed: unreviewed, createdAt: 20),
         agent(undrivable, session: "sp", unreviewed: unreviewed, createdAt: 10)]
    }

    private func resultJSON(_ ids: [String]) -> String {
        let items = ids.map {
            #"{"session_id":"\#($0)","cwd":"/Users/example/demo","title":"t","updated_at":1,"live":false,"last_prompt":null}"#
        }
        return #"{"conversations":[\#(items.joined(separator: ","))]}"#
    }

    private func open(_ model: MainSurfaceModel, agents: [Agent]) {
        model.agentsUpdated(agents)
        model.surfaceDidShow(.popover)
        spy.openIndexCompletions.last?(0)
        spy.searches.last?.completion(CLIRunResult(exitCode: 0, stdout: resultJSON(["h1"]), stderr: ""))
    }

    private var seenCommands: [[String]] {
        spy.commands.map(\.arguments).filter { $0.first == "seen" }
    }

    private func key(_ model: MainSurfaceModel, _ key: ListKey, _ modifiers: ListKeyModifiers = [],
                     searchFieldFocused: Bool = false) -> MainSurfaceModel.KeyRouting {
        model.handleKey(key: key, modifiers: modifiers, surface: .popover, hasMarkedText: false,
                        searchFieldFocused: searchFieldFocused)
    }

    // MARK: - The timer

    /// Selecting runs nothing; the timer is scheduled for §9's time, and its
    /// answer runs `seen` once for the unreviewed row.
    func testSelectingSchedulesTheTimerAndItsAnswerRunsSeenOnce() {
        let model = makeModel()
        open(model, agents: agents())
        model.rowClicked(.running(target: undrivable))
        XCTAssertTrue(seenCommands.isEmpty, "selecting does not mark read")
        XCTAssertEqual(spy.markReadTimers.map(\.seconds), [1], "§9: one second")
        spy.markReadTimers[0].action()
        XCTAssertEqual(seenCommands, [["seen", undrivable]])
        spy.markReadTimers[0].action()
        XCTAssertEqual(seenCommands.count, 1, "a spent timer runs nothing again")
    }

    func testKeySelectionsScheduleTheTimer() {
        // ↑ / ↓.
        let arrows = makeModel()
        open(arrows, agents: agents())
        XCTAssertEqual(key(arrows, .downArrow), .consumed)
        XCTAssertEqual(key(arrows, .downArrow), .consumed)
        XCTAssertEqual(spy.markReadTimers.count, 2)
        spy.markReadTimers[0].action()
        XCTAssertTrue(seenCommands.isEmpty, "the row ↓ passed over stays unreviewed")
        spy.markReadTimers[1].action()
        XCTAssertEqual(seenCommands, [["seen", undrivable]])

        // Enter with list focus and no selection.
        let enter = makeModel()
        open(enter, agents: agents())
        XCTAssertEqual(key(enter, .returnKey), .consumed)
        XCTAssertEqual(enter.list.selection?.key, .running(target: jumpable))
        XCTAssertEqual(spy.markReadTimers.count, 1)
        spy.markReadTimers[0].action()
        XCTAssertEqual(seenCommands, [["seen", jumpable]])

        // Enter in the search field.
        let field = makeModel()
        open(field, agents: agents())
        XCTAssertEqual(key(field, .returnKey, searchFieldFocused: true), .consumed)
        XCTAssertEqual(spy.markReadTimers.count, 1)
    }

    /// Closing the surface cancels; reopening carries no elapsed time over.
    func testClosingCancelsAndReopeningStartsNothing() {
        let model = makeModel()
        open(model, agents: agents())
        model.rowClicked(.running(target: undrivable))
        model.surfaceDidHide(.popover)
        spy.markReadTimers[0].action()
        XCTAssertTrue(seenCommands.isEmpty)
        model.surfaceDidShow(.popover)
        XCTAssertEqual(spy.markReadTimers.count, 1, "a kept selection starts nothing")
        XCTAssertEqual(model.list.selection?.key, .running(target: undrivable))
    }

    func testTheSurfaceStoppingBeingKeyKeepsTheTimer() {
        let model = makeModel()
        open(model, agents: agents())
        model.rowClicked(.running(target: undrivable))
        model.surfaceKeyChanged(surface: .popover, isKey: false)
        spy.markReadTimers[0].action()
        XCTAssertEqual(seenCommands, [["seen", undrivable]])
    }

    /// §4.5: keys and focus changes on the conversation pane (detail page)
    /// never mark read.
    func testConversationPaneKeysDoNotMarkRead() {
        let model = makeModel()
        open(model, agents: agents())
        model.rowClicked(.running(target: jumpable))
        spy.markReadTimers[0].action()
        model.viewClicked()
        XCTAssertEqual(model.list.page, .detail)
        model.agentsUpdated(agents())
        let before = spy.markReadTimers.count
        XCTAssertEqual(key(model, .downArrow), .passToConversationPane)
        XCTAssertEqual(key(model, .other(charactersIgnoringModifiers: " ")), .passThrough)
        model.searchFieldFocusChanged(surface: .popover, focused: false)
        XCTAssertEqual(spy.markReadTimers.count, before)
        XCTAssertEqual(seenCommands.count, 1, "only the first selection's seen")
    }

    /// §4.5: Enter on a row that cannot be jumped to starts the timer over,
    /// on the one-column detail page too.
    func testEnterOnARowThatCannotJumpStartsOver() {
        let model = makeModel()
        open(model, agents: agents())
        model.rowClicked(.running(target: undrivable))
        model.viewClicked()
        XCTAssertEqual(key(model, .returnKey), .consumed)
        XCTAssertEqual(spy.markReadTimers.count, 2)
        spy.markReadTimers[0].action()
        XCTAssertTrue(seenCommands.isEmpty, "the replaced timer runs nothing")
        spy.markReadTimers[1].action()
        XCTAssertEqual(seenCommands, [["seen", undrivable]])
    }

    // MARK: - rekey

    func testRekeyDuringTheTimerMarksTheNewTarget() {
        let model = makeModel()
        open(model, agents: agents())
        model.rowClicked(.running(target: undrivable))
        let renamed = "ghostty:/dev/ttys004"
        model.targetRekeyed(from: undrivable, to: renamed)
        model.agentsUpdated([agents()[0], agent(renamed, session: "sp", unreviewed: true, createdAt: 10)])
        XCTAssertEqual(model.list.selection?.key, .running(target: renamed), "the selection carries over")
        XCTAssertEqual(spy.markReadTimers.count, 1, "the carried selection starts nothing new")
        spy.markReadTimers[0].action()
        XCTAssertEqual(seenCommands, [["seen", renamed]])
    }

    /// §4.5: a `rekey` between the start and the end of `seen` sends it once
    /// more to the new target when that entry is unreviewed; not after the
    /// end, and not to an entry that is not unreviewed.
    func testSeenIsResentOnceForARekeyWhileItRuns() {
        let renamed = "ghostty:/dev/ttys004"
        let model = makeModel()
        open(model, agents: agents())
        model.markRead(target: undrivable)
        model.targetRekeyed(from: undrivable, to: renamed)
        model.agentsUpdated([agents()[0], agent(renamed, session: "sp", unreviewed: true, createdAt: 10)])
        spy.commands[0].completion(0)
        XCTAssertEqual(seenCommands, [["seen", undrivable], ["seen", renamed]])
        spy.commands[1].completion(0)
        XCTAssertEqual(seenCommands.count, 2, "once only")

        // The rekey after the end.
        let after = makeModel()
        open(after, agents: agents())
        after.markRead(target: undrivable)
        spy.commands[0].completion(0)
        after.targetRekeyed(from: undrivable, to: renamed)
        after.agentsUpdated([agents()[0], agent(renamed, session: "sp", unreviewed: true, createdAt: 10)])
        XCTAssertEqual(seenCommands, [["seen", undrivable]])

        // The new entry is not unreviewed when the seen ends.
        let reviewed = makeModel()
        open(reviewed, agents: agents())
        reviewed.markRead(target: undrivable)
        reviewed.targetRekeyed(from: undrivable, to: renamed)
        reviewed.agentsUpdated([agents()[0], agent(renamed, session: "sp", unreviewed: false, createdAt: 10)])
        spy.commands[0].completion(0)
        XCTAssertEqual(seenCommands, [["seen", undrivable]])
    }

    // MARK: - Notification click

    func testNotificationClickSelectsTheRowClearsTheSearchAndStartsOver() {
        let model = makeModel()
        open(model, agents: agents())
        model.rowClicked(.running(target: undrivable))
        model.query = "needle"
        XCTAssertTrue(model.list.isSearching)
        spy.focusListSurfaces = []
        model.notificationClicked(target: undrivable)
        XCTAssertEqual(model.query, "", "the search text is cleared")
        XCTAssertFalse(model.list.isSearching)
        XCTAssertEqual(model.list.selection?.key, .running(target: undrivable), "a selected row stays selected")
        XCTAssertEqual(spy.focusListSurfaces, [.popover])
        XCTAssertEqual(spy.markReadTimers.count, 2, "started over")
        spy.markReadTimers[0].action()
        XCTAssertTrue(seenCommands.isEmpty)
        spy.markReadTimers[1].action()
        XCTAssertEqual(seenCommands, [["seen", undrivable]])
    }

    func testNotificationClickForAGoneEntryOnlyOpens() {
        let model = makeModel()
        open(model, agents: agents())
        model.query = "needle"
        model.notificationClicked(target: "process:999")
        XCTAssertEqual(model.query, "needle")
        XCTAssertNil(model.list.selection)
        XCTAssertTrue(spy.markReadTimers.isEmpty)
    }
}
