import XCTest
@testable import ShiibarCcCore

final class GroupingTests: XCTestCase {
    private func agent(
        target: String,
        status: AgentStatus,
        unreviewed: Bool = false,
        cwd: String = "/Users/example/proj",
        task: String? = nil,
        message: String? = nil,
        createdAt: Int64 = 0,
        since: Int64 = 0
    ) -> Agent {
        Agent(
            target: target,
            status: status,
            unreviewed: unreviewed,
            sessionId: "s-\(target)",
            cwd: cwd,
            task: task,
            message: message,
            createdAt: createdAt,
            since: since,
            lastSeen: since
        )
    }

    func testGroupOrderIsWaitingThenWorkingThenIdleAndEmptyGroupsAreHidden() {
        let agents = [
            agent(target: "i", status: .idle),
            agent(target: "wo", status: .working),
            agent(target: "wa", status: .waiting),
        ]
        let groups = Grouping.groupedRows(agents: agents, now: 0, home: nil)
        XCTAssertEqual(groups.map(\.status), [.waiting, .working, .idle])
    }

    func testEmptyGroupsAreOmittedEntirely() {
        let groups = Grouping.groupedRows(agents: [agent(target: "wo", status: .working)], now: 0, home: nil)
        XCTAssertEqual(groups.map(\.status), [.working])
    }

    func testWithinGroupOrderIsCreatedAtDescending() {
        // §4.5/§8.31: within a group, newest session first — the same
        // immutable `created_at` key as the flat mode.
        let agents = [
            agent(target: "old", status: .idle, createdAt: 100),
            agent(target: "newest", status: .idle, createdAt: 300),
            agent(target: "mid", status: .idle, createdAt: 200),
        ]
        let groups = Grouping.groupedRows(agents: agents, now: 0, home: nil)
        XCTAssertEqual(groups[0].rows.map(\.target), ["newest", "mid", "old"])
    }

    func testUnreviewedDoesNotAffectPositionWithinAGroup() {
        // §8.31: unreviewed pinning is REMOVED — clearing a badge must not
        // move the row (the badge and bold text carry the signal, not the
        // position). Unreviewed rows deliberately sit below newer reviewed
        // ones here; the order must follow `created_at` alone.
        let agents = [
            agent(target: "new-reviewed", status: .idle, unreviewed: false, createdAt: 300),
            agent(target: "old-unreviewed", status: .idle, unreviewed: true, createdAt: 100),
            agent(target: "mid-unreviewed", status: .idle, unreviewed: true, createdAt: 200),
        ]
        let groups = Grouping.groupedRows(agents: agents, now: 0, home: nil)
        XCTAssertEqual(
            groups[0].rows.map(\.target),
            ["new-reviewed", "mid-unreviewed", "old-unreviewed"]
        )
    }

    func testWithinGroupTiesKeepRelativeOrderBecauseSortIsStable() {
        let agents = [
            agent(target: "a", status: .idle, createdAt: 100),
            agent(target: "b", status: .idle, createdAt: 100),
            agent(target: "c", status: .idle, createdAt: 100),
        ]
        let groups = Grouping.groupedRows(agents: agents, now: 0, home: nil)
        XCTAssertEqual(groups[0].rows.map(\.target), ["a", "b", "c"], "equal keys must not reorder")
    }

    func testWaitingRowUsesMessageAsPrimaryLine() {
        let a = agent(target: "t", status: .waiting, task: "task text", message: "permission prompt")
        let row = Grouping.makeRow(agent: a, now: 0, home: nil)
        XCTAssertEqual(row.primaryLine, "permission prompt")
    }

    func testNonWaitingRowUsesTaskAsPrimaryLine() {
        let a = agent(target: "t", status: .working, task: "task text", message: "should be ignored")
        let row = Grouping.makeRow(agent: a, now: 0, home: nil)
        XCTAssertEqual(row.primaryLine, "task text")
    }

    func testPrimaryLinePromotesToLabelWhenNeitherMessageNorTaskPresent() {
        let a = agent(target: "t", status: .idle, cwd: "/Users/example/proj/foo", task: nil, message: nil)
        let row = Grouping.makeRow(agent: a, now: 0, home: "/Users/example")
        XCTAssertEqual(row.primaryLine, row.label)
        XCTAssertEqual(row.label, "proj/foo")
    }

    func testElapsedSecondsIsNowMinusSinceAndNeverNegative() {
        let a = agent(target: "t", status: .idle, since: 100)
        XCTAssertEqual(Grouping.makeRow(agent: a, now: 150, home: nil).elapsedSeconds, 50)
        XCTAssertEqual(Grouping.makeRow(agent: a, now: 50, home: nil).elapsedSeconds, 0, "must clamp, not go negative")
    }
}
