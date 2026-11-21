import XCTest
@testable import ShiibarCcCore

/// DESIGN.md §4.5 "⌄ menu": `Mark all as read` is disabled while nothing
/// is unreviewed and runs `seen` for every unreviewed target — a waiting
/// session that is already reviewed is not a target.
final class MarkAllAsReadTests: XCTestCase {
    private func agent(_ target: String, status: AgentStatus, unreviewed: Bool) -> Agent {
        UL.agent(target, status: status, session: "s-\(target)", unreviewed: unreviewed)
    }

    func testEnabledOnlyWithAnUnreviewedAgent() {
        XCTAssertFalse(MarkAllAsRead.isEnabled(agents: []))
        XCTAssertFalse(MarkAllAsRead.isEnabled(agents: [agent("a", status: .waiting, unreviewed: false)]))
        XCTAssertTrue(MarkAllAsRead.isEnabled(agents: [agent("a", status: .idle, unreviewed: true)]))
    }

    func testTargetsAreTheUnreviewedAgentsInOrder() {
        let agents = [
            agent("iterm2:a", status: .idle, unreviewed: true),
            agent("iterm2:b", status: .waiting, unreviewed: false),
            agent("iterm2:c", status: .waiting, unreviewed: true),
        ]
        XCTAssertEqual(MarkAllAsRead.targets(agents: agents), ["iterm2:a", "iterm2:c"])
    }
}
