import XCTest
@testable import ShiibarCcCore

final class SortingTests: XCTestCase {
    private func agent(
        target: String,
        status: AgentStatus = .idle,
        createdAt: Int64 = 0,
        lastReportAt: Int64 = 0
    ) -> Agent {
        Agent(
            target: target,
            status: status,
            unreviewed: false,
            sessionId: "s-\(target)",
            cwd: "/proj/\(target)",
            task: nil,
            message: nil,
            createdAt: createdAt,
            lastReportAt: lastReportAt,
            since: 0,
            lastSeen: 0
        )
    }

    func testNewestSessionOrdersByCreatedAtDescending() {
        let agents = [
            agent(target: "old", createdAt: 100),
            agent(target: "newest", createdAt: 300),
            agent(target: "mid", createdAt: 200),
        ]
        let ordered = Sorting.flatOrder(agents: agents, mode: .newestSession)
        XCTAssertEqual(ordered.map(\.target), ["newest", "mid", "old"])
    }

    func testRecentActivityOrdersByLastReportAtDescending() {
        let agents = [
            agent(target: "stale", lastReportAt: 10),
            agent(target: "fresh", lastReportAt: 30),
            agent(target: "middling", lastReportAt: 20),
        ]
        let ordered = Sorting.flatOrder(agents: agents, mode: .recentActivity)
        XCTAssertEqual(ordered.map(\.target), ["fresh", "middling", "stale"])
    }

    func testTiesKeepRelativeOrderBecauseSortIsStable() {
        let agents = [
            agent(target: "a", createdAt: 100),
            agent(target: "b", createdAt: 100),
            agent(target: "c", createdAt: 100),
        ]
        let ordered = Sorting.flatOrder(agents: agents, mode: .newestSession)
        XCTAssertEqual(ordered.map(\.target), ["a", "b", "c"], "equal keys must not reorder")
    }

    func testUnknownStatusAgentsAreExcludedFromFlatOrder() {
        let agents = [
            agent(target: "known", status: .idle, createdAt: 200),
            agent(target: "future", status: .unknown, createdAt: 300),
        ]
        let ordered = Sorting.flatOrder(agents: agents, mode: .newestSession)
        XCTAssertEqual(ordered.map(\.target), ["known"], "unknown-status agents must not appear in the flat list")
    }

    func testGroupedModeReturnsKnownAgentsUnsorted() {
        // `.grouped` isn't meant to be consumed via `flatOrder` (it uses
        // `Grouping.groupedRows` instead) — this just documents that it
        // doesn't crash and still filters unknown statuses out.
        let agents = [
            agent(target: "a", status: .working),
            agent(target: "b", status: .unknown),
        ]
        let ordered = Sorting.flatOrder(agents: agents, mode: .grouped)
        XCTAssertEqual(ordered.map(\.target), ["a"])
    }

    func testAllCasesListsTheThreeModesInMenuOrder() {
        // §4.5/§8.25's "Sort by" radio order (default first): Grouped /
        // Newest session / Recent activity. `DropdownView`'s menu iterates
        // `SortMode.allCases`.
        XCTAssertEqual(SortMode.allCases, [.grouped, .newestSession, .recentActivity])
    }

    func testMenuTitlesAreEnglishUIText() {
        XCTAssertEqual(SortMode.grouped.menuTitle, "Grouped")
        XCTAssertEqual(SortMode.newestSession.menuTitle, "Newest session")
        XCTAssertEqual(SortMode.recentActivity.menuTitle, "Recent activity")
    }

    func testDefaultModeIsGrouped() {
        // §8.25 (2026-07-08): the fallback `AppState.init` uses when no sort
        // mode is stored yet changed from `.newestSession` to `.grouped`.
        XCTAssertEqual(SortMode.defaultMode, .grouped)
    }
}
