import ShiibarCcCore
import UserNotifications
import XCTest
@testable import ShiibarCcApp

/// `rekey` and the notification click in the notification manager (DESIGN.md
/// §4.5 "desktop notifications", "notification click", §8.66). Delivery,
/// removal of delivered notifications and the delayed re-check's timer are
/// injected spies: nothing reaches the notification center, and no test
/// waits on the clock. Defaults are in memory.
@MainActor
final class NotificationManagerRekeyTests: XCTestCase {
    private final class Spy {
        var posted: [UNNotificationRequest] = []
        var removed: [String] = []
        var delayed: [(seconds: TimeInterval, action: @MainActor () -> Void)] = []
        var focused: [String] = []
        var selected: [String] = []
        var agents: [Agent] = []
    }

    private var spy = Spy()

    private func makeManager() -> NotificationManager {
        spy = Spy()
        let spy = self.spy
        let manager = NotificationManager(
            defaults: InMemoryDefaults(),
            scheduleAfter: { seconds, action in spy.delayed.append((seconds: seconds, action: action)) },
            delivery: NotificationManager.Delivery(
                post: { spy.posted.append($0) },
                removeDelivered: { spy.removed.append($0) }))
        manager.currentAgentsProvider = { spy.agents }
        manager.homeProvider = { "/Users/example" }
        manager.onFocusRequested = { spy.focused.append($0) }
        manager.onSelectRowRequested = { spy.selected.append($0) }
        return manager
    }

    private func agent(_ target: String, unreviewed: Bool, status: AgentStatus = .idle) -> Agent {
        Agent(target: target, status: status, unreviewed: unreviewed, sessionId: "s1",
              cwd: "/Users/example/demo", task: "task", message: nil, createdAt: 1, since: 0, lastSeen: 0)
    }

    // MARK: - rekey

    /// After a rekey, the entry under its new target is not a new rise, and
    /// delivered notifications are not removed.
    func testRekeyRaisesNoNewNotificationAndKeepsDeliveredOnes() {
        let manager = makeManager()
        manager.observeSnapshot(agents: [])
        spy.agents = [agent("process:4242", unreviewed: true)]
        manager.observe(agents: spy.agents)
        XCTAssertEqual(spy.delayed.count, 1)
        XCTAssertEqual(spy.delayed[0].seconds, 3, "§9")
        spy.delayed[0].action()
        XCTAssertEqual(spy.posted.map(\.content.threadIdentifier), ["process:4242"])

        manager.rekey(from: "process:4242", to: "ghostty:/dev/ttys004")
        spy.agents = [agent("ghostty:/dev/ttys004", unreviewed: true)]
        manager.observe(agents: spy.agents)
        XCTAssertEqual(spy.delayed.count, 1, "no new rise for the moved entry")
        XCTAssertEqual(spy.posted.count, 1)
        XCTAssertTrue(spy.removed.isEmpty, "delivered notifications stay")
    }

    /// A delayed notification waiting when the rekey arrives re-checks, and
    /// is delivered for, the new target.
    func testAPendingDelayedNotificationRechecksTheNewTarget() {
        let manager = makeManager()
        manager.observeSnapshot(agents: [])
        manager.observe(agents: [agent("process:4242", unreviewed: true, status: .waiting)])
        manager.rekey(from: "process:4242", to: "ghostty:/dev/ttys004")
        spy.agents = [agent("ghostty:/dev/ttys004", unreviewed: true, status: .waiting)]
        spy.delayed[0].action()
        XCTAssertEqual(spy.posted.map(\.content.threadIdentifier), ["ghostty:/dev/ttys004"])

        // The new target is no longer unreviewed when the timer fires.
        let quiet = makeManager()
        quiet.observeSnapshot(agents: [])
        quiet.observe(agents: [agent("process:4242", unreviewed: true)])
        quiet.rekey(from: "process:4242", to: "ghostty:/dev/ttys004")
        spy.agents = [agent("ghostty:/dev/ttys004", unreviewed: false)]
        spy.delayed[0].action()
        XCTAssertTrue(spy.posted.isEmpty)
    }

    // MARK: - Notification click

    func testClickFocusesAJumpableTargetAndSelectsTheRowOfAnyOther() {
        let manager = makeManager()
        manager.notificationClicked(threadIdentifier: "iterm2:ABC")
        XCTAssertEqual(spy.focused, ["iterm2:ABC"])
        XCTAssertTrue(spy.selected.isEmpty)
        manager.notificationClicked(threadIdentifier: "process:4242")
        XCTAssertEqual(spy.selected, ["process:4242"])
        XCTAssertEqual(spy.focused, ["iterm2:ABC"], "no focus for a session the app cannot jump to")
    }

    /// A notification delivered before a rekey branches on the new target;
    /// chains are followed and a chain back to the start still ends.
    func testClickReadsTheTargetThroughTheRekeys() {
        let manager = makeManager()
        manager.rekey(from: "process:4242", to: "ghostty:/dev/ttys004")
        manager.notificationClicked(threadIdentifier: "process:4242")
        XCTAssertEqual(spy.focused, ["ghostty:/dev/ttys004"])

        manager.rekey(from: "iterm2:A", to: "process:7")
        manager.rekey(from: "process:7", to: "process:8")
        manager.notificationClicked(threadIdentifier: "iterm2:A")
        XCTAssertEqual(spy.selected, ["process:8"], "A -> B, B -> C")

        // A -> B, then B -> A: the click still ends, on a target of the
        // chain.
        let cycle = makeManager()
        cycle.rekey(from: "iterm2:A", to: "process:7")
        cycle.rekey(from: "process:7", to: "iterm2:A")
        cycle.notificationClicked(threadIdentifier: "iterm2:A")
        XCTAssertEqual(spy.focused, ["iterm2:A"], "a chain back to the start ends")
    }

    /// A re-key back to an earlier target, with an unrelated mapping in the
    /// map: a click on a notification delivered under either former target
    /// reaches the entry's current target.
    func testClickAfterARekeyBackReachesTheCurrentTarget() {
        let manager = makeManager()
        manager.rekey(from: "iterm2:Z", to: "process:9")
        manager.rekey(from: "ghostty:/dev/ttys004", to: "process:7")
        manager.rekey(from: "process:7", to: "ghostty:/dev/ttys004")
        manager.notificationClicked(threadIdentifier: "ghostty:/dev/ttys004")
        manager.notificationClicked(threadIdentifier: "process:7")
        XCTAssertEqual(spy.focused, ["ghostty:/dev/ttys004", "ghostty:/dev/ttys004"])
        XCTAssertTrue(spy.selected.isEmpty)
    }

    /// A delayed notification scheduled before a move and a move back is
    /// re-checked and delivered for the entry's current target.
    func testDelayedNotificationAfterARekeyBackUsesTheCurrentTarget() {
        let manager = makeManager()
        manager.observeSnapshot(agents: [])
        manager.rekey(from: "iterm2:Z", to: "process:9")
        manager.observe(agents: [agent("process:7", unreviewed: true, status: .waiting)])
        manager.rekey(from: "process:7", to: "ghostty:/dev/ttys004")
        manager.rekey(from: "ghostty:/dev/ttys004", to: "process:7")
        spy.agents = [agent("process:7", unreviewed: true, status: .waiting)]
        spy.delayed[0].action()
        XCTAssertEqual(spy.posted.map(\.content.threadIdentifier), ["process:7"])
    }

    /// A new session that reuses an old `process:<pid>` target is not
    /// redirected to the entry that moved away from it.
    func testANewEntryUnderAFormerTargetIsNotRedirected() {
        let manager = makeManager()
        manager.observeSnapshot(agents: [])
        manager.rekey(from: "process:7", to: "ghostty:/dev/ttys004")
        spy.agents = [agent("ghostty:/dev/ttys004", unreviewed: false), agent("process:7", unreviewed: true)]
        manager.observe(agents: spy.agents)
        manager.notificationClicked(threadIdentifier: "process:7")
        XCTAssertEqual(spy.selected, ["process:7"])
        XCTAssertTrue(spy.focused.isEmpty)
        spy.delayed[0].action()
        XCTAssertEqual(spy.posted.map(\.content.threadIdentifier), ["process:7"])
    }

    // MARK: - The order in AppState

    /// §4.5: notifications, then the list, then the agent table.
    func testAppStateAppliesARekeyToNotificationsThenTheListThenTheTable() {
        var calls: [String] = []
        var table: [Agent] = []
        AppState.applyRekey(
            from: "process:4242", to: "ghostty:/dev/ttys004",
            agents: [agent("process:4242", unreviewed: true)],
            notifications: { calls.append("notifications \($0) -> \($1)") },
            list: { calls.append("list \($0) -> \($1)") },
            setAgents: { calls.append("table"); table = $0 })
        XCTAssertEqual(calls, [
            "notifications process:4242 -> ghostty:/dev/ttys004",
            "list process:4242 -> ghostty:/dev/ttys004",
            "table",
        ])
        XCTAssertEqual(table.map(\.target), ["ghostty:/dev/ttys004"])
    }

    // MARK: - Sweeping delivered notifications

    /// Reading or focusing the entry removes its notifications delivered
    /// under every earlier target too.
    func testSweepRemovesNotificationsDeliveredUnderEarlierTargets() {
        let manager = makeManager()
        manager.rekey(from: "process:7", to: "process:8")
        manager.rekey(from: "process:8", to: "ghostty:/dev/ttys004")
        manager.rekey(from: "iterm2:Z", to: "process:9")
        manager.sweepDelivered(target: "ghostty:/dev/ttys004")
        XCTAssertEqual(spy.removed, ["ghostty:/dev/ttys004", "process:7", "process:8"])

        spy.removed = []
        manager.sweepDelivered(target: "process:9", reason: .remove)
        XCTAssertEqual(spy.removed, ["process:9", "iterm2:Z"])

        spy.removed = []
        manager.sweepDelivered(target: "process:9", reason: .sessionEnd)
        XCTAssertTrue(spy.removed.isEmpty, "session_end keeps delivered notifications")
    }
}
