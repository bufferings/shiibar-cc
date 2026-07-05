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

    func testUnreviewedRowsSortFirstWithinAGroupAndOrderIsStableOtherwise() {
        let agents = [
            agent(target: "a", status: .idle, unreviewed: false),
            agent(target: "b", status: .idle, unreviewed: true),
            agent(target: "c", status: .idle, unreviewed: false),
            agent(target: "d", status: .idle, unreviewed: true),
        ]
        let groups = Grouping.groupedRows(agents: agents, now: 0, home: nil)
        XCTAssertEqual(groups[0].rows.map(\.target), ["b", "d", "a", "c"])
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
