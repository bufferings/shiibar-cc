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

    func testNewestFirstOrdersByCreatedAtDescending() {
        let agents = [
            agent(target: "old", createdAt: 100),
            agent(target: "newest", createdAt: 300),
            agent(target: "mid", createdAt: 200),
        ]
        let ordered = Sorting.newestFirst(agents: agents)
        XCTAssertEqual(ordered.map(\.target), ["newest", "mid", "old"])
    }

    func testTiesKeepRelativeOrderBecauseSortIsStable() {
        let agents = [
            agent(target: "a", createdAt: 100),
            agent(target: "b", createdAt: 100),
            agent(target: "c", createdAt: 100),
        ]
        let ordered = Sorting.newestFirst(agents: agents)
        XCTAssertEqual(ordered.map(\.target), ["a", "b", "c"], "equal keys must not reorder")
    }

    func testUnknownStatusAgentsAreExcluded() {
        let agents = [
            agent(target: "known", status: .idle, createdAt: 200),
            agent(target: "future", status: .unknown, createdAt: 300),
        ]
        let ordered = Sorting.newestFirst(agents: agents)
        XCTAssertEqual(ordered.map(\.target), ["known"], "unknown-status agents must not appear in the flat list")
    }

    func testLastReportAtNeverAffectsTheOrder() {
        // §8.31: Recent activity (keyed on the ever-moving `last_report_at`)
        // is removed; the field stays in the protocol but no UI consumes it.
        // `created_at` must win even when `last_report_at` says otherwise,
        // and equal `created_at` rows must not be reordered by it.
        let agents = [
            agent(target: "older-but-active", createdAt: 100, lastReportAt: 999),
            agent(target: "newer-but-quiet", createdAt: 200, lastReportAt: 1),
            agent(target: "tie-1", createdAt: 50, lastReportAt: 1),
            agent(target: "tie-2", createdAt: 50, lastReportAt: 999),
        ]
        let ordered = Sorting.newestFirst(agents: agents)
        XCTAssertEqual(
            ordered.map(\.target),
            ["newer-but-quiet", "older-but-active", "tie-1", "tie-2"]
        )
    }

    func testAllCasesListsTheTwoModesInMenuOrder() {
        // §4.5/§8.25/§8.31's "Sort by" radio order (default first):
        // Grouped / Newest session. Both the ⌄ menu and the app menu
        // iterate `SortMode.allCases`.
        XCTAssertEqual(SortMode.allCases, [.grouped, .newestSession])
    }

    func testMenuTitlesAreEnglishUIText() {
        XCTAssertEqual(SortMode.grouped.menuTitle, "Grouped")
        XCTAssertEqual(SortMode.newestSession.menuTitle, "Newest session")
    }

    func testDefaultModeIsGrouped() {
        // §8.25 (2026-07-08): the fallback `AppState.init` uses when no sort
        // mode is stored yet changed from `.newestSession` to `.grouped`.
        XCTAssertEqual(SortMode.defaultMode, .grouped)
    }

    func testUnknownStoredValuesFallBackToTheDefault() {
        // §4.5/§8.31: a stored value this build doesn't know — including
        // "recentActivity" persisted by a build that still had that mode —
        // must fall back to the default, via the same `rawValue` + `??`
        // pattern `AppState.init` uses.
        for stored in ["recentActivity", "sepia", ""] {
            XCTAssertNil(SortMode(rawValue: stored), "'\(stored)' must not decode")
            XCTAssertEqual(SortMode(rawValue: stored) ?? SortMode.defaultMode, .grouped)
        }
        // The two live values still round-trip.
        for mode in SortMode.allCases {
            XCTAssertEqual(SortMode(rawValue: mode.rawValue), mode)
        }
    }
}
