import XCTest
@testable import ShiibarCCCore

final class NotificationLogicTests: XCTestCase {
    private func agent(target: String, status: AgentStatus, unreviewed: Bool) -> Agent {
        Agent(
            target: target,
            status: status,
            unreviewed: unreviewed,
            sessionId: "s-\(target)",
            cwd: "/c",
            task: nil,
            message: nil,
            since: 0,
            lastSeen: 0
        )
    }

    // ---- UnreviewedEdgeTracker: rising-edge detection + de-dup ----

    func testFirstObservationOfAnUnreviewedAgentIsARisingEdge() {
        let tracker = UnreviewedEdgeTracker()
        let edges = tracker.observe(agents: [agent(target: "t", status: .waiting, unreviewed: true)])
        XCTAssertEqual(edges, [UnreviewedEdge(target: "t", status: .waiting)])
    }

    func testRepeatedObservationOfTheSameStillUnreviewedAgentDoesNotFireAgain() {
        // This is the DESIGN.md §4.5 "de-dupe via fired record" requirement:
        // a snapshot and a later reconcile both reporting the same
        // still-unreviewed agent must only notify once.
        let tracker = UnreviewedEdgeTracker()
        _ = tracker.observe(agents: [agent(target: "t", status: .waiting, unreviewed: true)])
        let secondEdges = tracker.observe(agents: [agent(target: "t", status: .waiting, unreviewed: true)])
        XCTAssertTrue(secondEdges.isEmpty)
    }

    func testUnreviewedGoingFalseThenTrueAgainIsANewRisingEdge() {
        let tracker = UnreviewedEdgeTracker()
        _ = tracker.observe(agents: [agent(target: "t", status: .waiting, unreviewed: true)])
        _ = tracker.observe(agents: [agent(target: "t", status: .working, unreviewed: false)])
        let edges = tracker.observe(agents: [agent(target: "t", status: .idle, unreviewed: true)])
        XCTAssertEqual(edges, [UnreviewedEdge(target: "t", status: .idle)])
    }

    func testWaitingEdgePlaysSoundAndIdleCompletionEdgeDoesNot() {
        XCTAssertTrue(UnreviewedEdge(target: "t", status: .waiting).playsSound)
        XCTAssertFalse(UnreviewedEdge(target: "t", status: .idle).playsSound)
    }

    func testForgetAllowsTheSameTargetToRiseAgainAsANewEdge() {
        let tracker = UnreviewedEdgeTracker()
        _ = tracker.observe(agents: [agent(target: "t", status: .waiting, unreviewed: true)])
        tracker.forget(target: "t")
        let edges = tracker.observe(agents: [agent(target: "t", status: .waiting, unreviewed: true)])
        XCTAssertEqual(edges, [UnreviewedEdge(target: "t", status: .waiting)])
    }

    // ---- Delayed re-check ----

    func testDelayedNotificationFiresOnlyWhenStillUnreviewedAndNotForeground() {
        XCTAssertTrue(DelayedNotificationDecision.shouldNotify(currentlyUnreviewed: true, targetIsForeground: false))
        XCTAssertFalse(DelayedNotificationDecision.shouldNotify(currentlyUnreviewed: true, targetIsForeground: true))
        XCTAssertFalse(DelayedNotificationDecision.shouldNotify(currentlyUnreviewed: false, targetIsForeground: false))
        XCTAssertFalse(DelayedNotificationDecision.shouldNotify(currentlyUnreviewed: false, targetIsForeground: true))
    }

    // ---- Cleanup rule ----

    func testCleanupSweepsForEveryReasonExceptSessionEnd() {
        XCTAssertFalse(NotificationCleanupRule.shouldSweep(onRemovalReason: .sessionEnd))
        XCTAssertTrue(NotificationCleanupRule.shouldSweep(onRemovalReason: .stale))
        XCTAssertTrue(NotificationCleanupRule.shouldSweep(onRemovalReason: .remove))
        XCTAssertTrue(NotificationCleanupRule.shouldSweep(onRemovalReason: .prune))
        XCTAssertTrue(NotificationCleanupRule.shouldSweep(onRemovalReason: .unknown))
    }
}
